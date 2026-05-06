package sessionauthority

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"cloudsec_remote_browser/services/internal/contracts"
	"cloudsec_remote_browser/services/internal/httpx"
)

const serviceName = "session-authority"

const (
	relayModeGatewayMediaRelay         = "gateway-media-relay"
	mediaPlaneModeGatewayWebRTCRelay   = "gateway-webrtc-relay"
	mediaTerminationProtocolWebRTCSRTP = "webrtc-srtp"
)

type Config struct {
	DefaultRegion              string
	Regions                    []string
	TenantRegions              map[string]string
	GatewaysPerRegion          int
	WorkersPerRegion           int
	ZoneSuffixes               []string
	HandoffBaseURL             string
	GatewayPublicBaseURL       string
	GatewayPublicWsURL         string
	ViewerEntryMode            string
	RelayMode                  string
	RuntimeClass               string
	NodePool                   string
	InternalSharedSecret       string
	RuntimeBaseURL             string
	RuntimeSharedSecret        string
	RuntimeRequestTimeout      time.Duration
	MediaGatewayBaseURL        string
	MediaGatewayRequestTimeout time.Duration
}

type RuntimeClient interface {
	CreateSession(ctx context.Context, req contracts.RuntimeSessionRequest) (contracts.RuntimeSessionResponse, error)
	UpdateSession(ctx context.Context, sessionID string, req contracts.RuntimeSessionUpdateRequest) (contracts.RuntimeSessionResponse, error)
}

type GatewayClient interface {
	CreateSession(ctx context.Context, req contracts.MediaGatewaySessionRequest) (contracts.MediaGatewaySessionResponse, error)
}

type Service struct {
	cfg           Config
	runtimeClient RuntimeClient
	gatewayClient GatewayClient
	mu            sync.RWMutex
	sessions      map[string]SessionRecord
	transactions  map[string]string
	gatewayIndex  map[string]int
	workerIndex   map[string]int
}

type SessionRecord struct {
	Request   contracts.EdgeBootstrapRequest  `json:"request"`
	Response  contracts.EdgeBootstrapResponse `json:"response"`
	CreatedAt time.Time                       `json:"createdAt"`
	Source    string                          `json:"source"`
}

type apiError struct {
	status  int
	message string
}

func (e *apiError) Error() string {
	return e.message
}

func LoadConfigFromEnv() Config {
	defaultRegion := getenvDefault("SESSION_AUTHORITY_DEFAULT_REGION", "us-east-1")
	regions := parseCSV(os.Getenv("SESSION_AUTHORITY_REGIONS"))
	if len(regions) == 0 {
		regions = []string{defaultRegion}
	}

	handoffBaseURL := getenvDefault("SESSION_AUTHORITY_HANDOFF_BASE_URL", "https://remote-browser.example.com")
	gatewayBaseURL := getenvDefault("SESSION_AUTHORITY_GATEWAY_PUBLIC_BASE_URL", handoffBaseURL)

	cfg := Config{
		DefaultRegion:              defaultRegion,
		Regions:                    regions,
		TenantRegions:              parseAssignments(os.Getenv("SESSION_AUTHORITY_TENANT_REGIONS")),
		GatewaysPerRegion:          parsePositiveInt(os.Getenv("SESSION_AUTHORITY_GATEWAYS_PER_REGION"), 2),
		WorkersPerRegion:           parsePositiveInt(os.Getenv("SESSION_AUTHORITY_WORKERS_PER_REGION"), 8),
		ZoneSuffixes:               parseCSVOrDefault(os.Getenv("SESSION_AUTHORITY_ZONE_SUFFIXES"), []string{"a", "b", "c"}),
		HandoffBaseURL:             handoffBaseURL,
		GatewayPublicBaseURL:       gatewayBaseURL,
		GatewayPublicWsURL:         getenvDefault("SESSION_AUTHORITY_GATEWAY_PUBLIC_WS_URL", deriveWSURL(gatewayBaseURL)),
		ViewerEntryMode:            getenvDefault("SESSION_AUTHORITY_VIEWER_ENTRY_MODE", "swg-handoff"),
		RelayMode:                  getenvDefault("SESSION_AUTHORITY_RELAY_MODE", "gateway-media-relay"),
		RuntimeClass:               getenvDefault("SESSION_AUTHORITY_DEFAULT_RUNTIME_CLASS", "kata-clh"),
		NodePool:                   getenvDefault("SESSION_AUTHORITY_DEFAULT_NODE_POOL", "rbi-workers"),
		InternalSharedSecret:       os.Getenv("RBI_INTERNAL_SHARED_SECRET"),
		RuntimeBaseURL:             strings.TrimRight(os.Getenv("SESSION_AUTHORITY_RUNTIME_BASE_URL"), "/"),
		RuntimeSharedSecret:        os.Getenv("RBI_INTERNAL_SHARED_SECRET"),
		RuntimeRequestTimeout:      time.Duration(parsePositiveInt(os.Getenv("SESSION_AUTHORITY_RUNTIME_TIMEOUT_SECONDS"), 5)) * time.Second,
		MediaGatewayBaseURL:        strings.TrimRight(os.Getenv("SESSION_AUTHORITY_MEDIA_GATEWAY_BASE_URL"), "/"),
		MediaGatewayRequestTimeout: time.Duration(parsePositiveInt(os.Getenv("SESSION_AUTHORITY_MEDIA_GATEWAY_TIMEOUT_SECONDS"), 5)) * time.Second,
	}

	return cfg
}

func NewService(cfg Config) *Service {
	return NewServiceWithClients(cfg, newRuntimeClient(cfg), newMediaGatewayClient(cfg))
}

func NewServiceWithClient(cfg Config, client RuntimeClient) *Service {
	return NewServiceWithClients(cfg, client, nil)
}

func NewServiceWithClients(cfg Config, runtimeClient RuntimeClient, gatewayClient GatewayClient) *Service {
	if len(cfg.Regions) == 0 {
		cfg.Regions = []string{cfg.DefaultRegion}
	}
	if cfg.DefaultRegion == "" {
		cfg.DefaultRegion = cfg.Regions[0]
	}
	if cfg.GatewaysPerRegion <= 0 {
		cfg.GatewaysPerRegion = 2
	}
	if cfg.WorkersPerRegion <= 0 {
		cfg.WorkersPerRegion = 8
	}
	if len(cfg.ZoneSuffixes) == 0 {
		cfg.ZoneSuffixes = []string{"a", "b", "c"}
	}
	if cfg.HandoffBaseURL == "" {
		cfg.HandoffBaseURL = "https://remote-browser.example.com"
	}
	if cfg.GatewayPublicBaseURL == "" {
		cfg.GatewayPublicBaseURL = cfg.HandoffBaseURL
	}
	if cfg.GatewayPublicWsURL == "" {
		cfg.GatewayPublicWsURL = deriveWSURL(cfg.GatewayPublicBaseURL)
	}
	if cfg.ViewerEntryMode == "" {
		cfg.ViewerEntryMode = "swg-handoff"
	}
	if cfg.RelayMode == "" {
		cfg.RelayMode = "gateway-media-relay"
	}
	if cfg.RuntimeClass == "" {
		cfg.RuntimeClass = "kata-clh"
	}
	if cfg.NodePool == "" {
		cfg.NodePool = "rbi-workers"
	}

	return &Service{
		cfg:           cfg,
		runtimeClient: runtimeClient,
		gatewayClient: gatewayClient,
		sessions:      make(map[string]SessionRecord),
		transactions:  make(map[string]string),
		gatewayIndex:  make(map[string]int),
		workerIndex:   make(map[string]int),
	}
}

func (s *Service) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/v1/bootstrap", s.handleBootstrap)
	mux.HandleFunc("/v1/sessions/", s.handleSession)
	return mux
}

func (s *Service) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		httpx.MethodNotAllowed(w, serviceName, http.MethodGet)
		return
	}

	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"service": serviceName,
	})
}

func (s *Service) handleBootstrap(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpx.MethodNotAllowed(w, serviceName, http.MethodPost)
		return
	}
	if err := s.requireInternalSecret(r); err != nil {
		var apiErr *apiError
		if errors.As(err, &apiErr) {
			httpx.WriteError(w, apiErr.status, serviceName, apiErr.message)
			return
		}
	}

	defer r.Body.Close()

	var req contracts.EdgeBootstrapRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, serviceName, "invalid bootstrap request")
		return
	}

	resp, status, err := s.Bootstrap(r.Context(), req)
	if err != nil {
		var apiErr *apiError
		if errors.As(err, &apiErr) {
			httpx.WriteError(w, apiErr.status, serviceName, apiErr.message)
			return
		}
		httpx.WriteError(w, http.StatusInternalServerError, serviceName, "bootstrap failed")
		return
	}

	httpx.WriteJSON(w, status, resp)
}

func (s *Service) handleSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		httpx.MethodNotAllowed(w, serviceName, http.MethodGet)
		return
	}
	if err := s.requireInternalSecret(r); err != nil {
		var apiErr *apiError
		if errors.As(err, &apiErr) {
			httpx.WriteError(w, apiErr.status, serviceName, apiErr.message)
			return
		}
	}

	sessionID := strings.TrimPrefix(r.URL.Path, "/v1/sessions/")
	if sessionID == "" || strings.Contains(sessionID, "/") {
		httpx.WriteError(w, http.StatusNotFound, serviceName, "session not found")
		return
	}

	record, ok := s.GetSession(sessionID)
	if !ok {
		httpx.WriteError(w, http.StatusNotFound, serviceName, "session not found")
		return
	}

	httpx.WriteJSON(w, http.StatusOK, record)
}

func (s *Service) GetSession(sessionID string) (SessionRecord, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	record, ok := s.sessions[sessionID]
	return record, ok
}

func (s *Service) Bootstrap(ctx context.Context, req contracts.EdgeBootstrapRequest) (contracts.EdgeBootstrapResponse, int, error) {
	normalizedReq, err := s.validateRequest(req)
	if err != nil {
		return contracts.EdgeBootstrapResponse{}, 0, err
	}

	s.mu.RLock()
	if sessionID, ok := s.transactions[normalizedReq.TransactionID]; ok {
		record := s.sessions[sessionID]
		s.mu.RUnlock()
		return record.Response, http.StatusOK, nil
	}
	s.mu.RUnlock()

	resp, source, err := s.createBootstrap(ctx, normalizedReq)
	if err != nil {
		return contracts.EdgeBootstrapResponse{}, 0, err
	}

	s.mu.Lock()
	if sessionID, ok := s.transactions[normalizedReq.TransactionID]; ok {
		record := s.sessions[sessionID]
		s.mu.Unlock()
		return record.Response, http.StatusOK, nil
	}

	s.sessions[resp.SessionID] = SessionRecord{
		Request:   normalizedReq,
		Response:  resp,
		CreatedAt: time.Now().UTC(),
		Source:    source,
	}
	s.transactions[normalizedReq.TransactionID] = resp.SessionID
	s.mu.Unlock()

	return resp, http.StatusCreated, nil
}

func (s *Service) createBootstrap(ctx context.Context, req contracts.EdgeBootstrapRequest) (contracts.EdgeBootstrapResponse, string, error) {
	region := s.resolveRegion(req)
	workerAssignment := s.assignWorker("", region)
	gatewayAssignment := s.assignGateway("", region, workerAssignment.WorkerID, req)
	var (
		err         error
		runtimeResp contracts.RuntimeSessionResponse
	)

	resp := contracts.EdgeBootstrapResponse{
		HandoffURL:        s.buildHandoffURL(req),
		ViewerEntry:       s.cfg.ViewerEntryMode,
		GatewayRegion:     region,
		GatewayAssignment: &gatewayAssignment,
		WorkerAssignment:  &workerAssignment,
	}
	source := "local"

	if s.runtimeClient != nil {
		runtimeReq := buildRuntimeSessionRequest(req, gatewayAssignment, workerAssignment)
		runtimeResp, err = s.runtimeClient.CreateSession(ctx, runtimeReq)
		if err != nil {
			return contracts.EdgeBootstrapResponse{}, "", &apiError{
				status:  http.StatusBadGateway,
				message: fmt.Sprintf("runtime session bootstrap failed: %v", err),
			}
		}

		if runtimeResp.SessionID != "" {
			resp.SessionID = runtimeResp.SessionID
			workerAssignment.SessionID = runtimeResp.SessionID
			gatewayAssignment.SessionID = runtimeResp.SessionID
		}
		if runtimeResp.GatewayAssignment != nil {
			gatewayAssignment = mergeGatewayAssignment(gatewayAssignment, runtimeResp.GatewayAssignment)
		}
		if runtimeResp.WorkerAssignment != nil {
			workerAssignment = mergeWorkerAssignment(workerAssignment, runtimeResp.WorkerAssignment)
		}
		if runtimeResp.HandoffURL != "" {
			resp.HandoffURL = runtimeResp.HandoffURL
		}
		if runtimeResp.ViewerEntry != "" {
			resp.ViewerEntry = runtimeResp.ViewerEntry
		}
		source = "runtime"
	}

	if resp.SessionID == "" {
		resp.SessionID = newOpaqueID("sess_")
	}

	gatewayAssignment.SessionID = resp.SessionID
	workerAssignment.SessionID = resp.SessionID
	if workerAssignment.WorkerID != "" {
		gatewayAssignment.WorkerID = workerAssignment.WorkerID
	}

	if s.gatewayClient != nil && runtimeResp.SessionID != "" {
		gatewayReq := buildMediaGatewaySessionRequest(
			req,
			resp,
			runtimeResp,
			gatewayAssignment,
			workerAssignment,
		)
		gatewayResp, err := s.gatewayClient.CreateSession(ctx, gatewayReq)
		if err != nil {
			return contracts.EdgeBootstrapResponse{}, "", &apiError{
				status:  http.StatusBadGateway,
				message: fmt.Sprintf("media gateway session registration failed: %v", err),
			}
		}
		if err := validateMediaGatewaySessionResponse(gatewayReq, gatewayResp); err != nil {
			return contracts.EdgeBootstrapResponse{}, "", err
		}
		gatewayAssignment = gatewayResp.GatewayAssignment
		workerAssignment = gatewayResp.WorkerAssignment
		if gatewayResp.ViewerEntryMode != "" {
			resp.ViewerEntry = gatewayResp.ViewerEntryMode
		}
		updateResp, err := s.runtimeClient.UpdateSession(
			ctx,
			resp.SessionID,
			buildRuntimeSessionUpdateRequest(gatewayResp),
		)
		if err != nil {
			return contracts.EdgeBootstrapResponse{}, "", &apiError{
				status:  http.StatusBadGateway,
				message: fmt.Sprintf("runtime session update failed: %v", err),
			}
		}
		gatewayAssignment = mergeGatewayAssignment(gatewayResp.GatewayAssignment, updateResp.GatewayAssignment)
		workerAssignment = mergeWorkerAssignment(gatewayResp.WorkerAssignment, updateResp.WorkerAssignment)
		resp.Transport = mergeGatewayTransport(gatewayResp.Transport, updateResp.Transport)
		resp.WorkerBridge = mergeWorkerBridge(gatewayResp.WorkerBridge, updateResp.WorkerBridge)
		source = source + "+gateway"
	}

	resp.GatewayRegion = firstNonEmpty(gatewayAssignment.Region, region)
	resp.GatewayAssignment = &gatewayAssignment
	resp.WorkerAssignment = &workerAssignment

	return resp, source, nil
}

func (s *Service) validateRequest(req contracts.EdgeBootstrapRequest) (contracts.EdgeBootstrapRequest, error) {
	req.TransactionID = strings.TrimSpace(req.TransactionID)
	req.TargetURL = strings.TrimSpace(req.TargetURL)
	req.TenantID = strings.TrimSpace(req.TenantID)
	req.ProfileID = strings.TrimSpace(req.ProfileID)
	req.Policy = strings.TrimSpace(req.Policy)
	req.UpstreamHost = strings.TrimSpace(req.UpstreamHost)
	req.UpstreamScheme = strings.TrimSpace(req.UpstreamScheme)
	req.UpstreamPort = strings.TrimSpace(req.UpstreamPort)
	req.PublicBaseURL = strings.TrimSpace(req.PublicBaseURL)
	req.PublicWsURL = strings.TrimSpace(req.PublicWsURL)

	switch {
	case req.TransactionID == "":
		return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "transactionId is required"}
	case req.TargetURL == "":
		return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "targetUrl is required"}
	case req.TenantID == "":
		return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "tenantId is required"}
	case req.ProfileID == "":
		return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "profileId is required"}
	case req.Policy == "":
		return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "policy is required"}
	case req.UpstreamHost == "":
		return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "upstreamHost is required"}
	case req.UpstreamScheme == "":
		return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "upstreamScheme is required"}
	case req.UpstreamPort == "":
		return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "upstreamPort is required"}
	}

	targetURL, err := url.Parse(req.TargetURL)
	if err != nil || !targetURL.IsAbs() || (targetURL.Scheme != "http" && targetURL.Scheme != "https") {
		return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "targetUrl must be an absolute http or https URL"}
	}

	if req.Viewport != nil {
		if req.Viewport.Width < 0 || req.Viewport.Height < 0 {
			return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "viewport dimensions must be positive"}
		}
		if req.Viewport.DeviceScaleFactor < 0 {
			return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "viewport.deviceScaleFactor must be positive"}
		}
	}

	if req.PublicBaseURL != "" {
		if _, err := url.ParseRequestURI(req.PublicBaseURL); err != nil {
			return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "publicBaseUrl must be an absolute URL"}
		}
	}
	if req.PublicWsURL != "" {
		wsURL, err := url.ParseRequestURI(req.PublicWsURL)
		if err != nil || (wsURL.Scheme != "ws" && wsURL.Scheme != "wss") {
			return contracts.EdgeBootstrapRequest{}, &apiError{status: http.StatusBadRequest, message: "publicWsUrl must be an absolute ws or wss URL"}
		}
	}

	return req, nil
}

func (s *Service) resolveRegion(req contracts.EdgeBootstrapRequest) string {
	if region, ok := s.cfg.TenantRegions[req.TenantID]; ok && region != "" {
		return region
	}

	regions := s.cfg.Regions
	if len(regions) == 0 {
		return s.cfg.DefaultRegion
	}

	seed := req.TenantID + "|" + req.ProfileID + "|" + req.UpstreamHost
	return regions[hashString(seed)%uint32(len(regions))]
}

func (s *Service) assignGateway(sessionID, region, workerID string, req contracts.EdgeBootstrapRequest) contracts.GatewayAssignment {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.gatewayIndex[region]++
	index := s.gatewayIndex[region]

	return contracts.GatewayAssignment{
		SessionID:     sessionID,
		GatewayID:     fmt.Sprintf("gateway-%s-%02d", region, ((index-1)%s.cfg.GatewaysPerRegion)+1),
		Region:        region,
		WorkerID:      workerID,
		RelayMode:     s.cfg.RelayMode,
		PublicBaseURL: firstNonEmpty(req.PublicBaseURL, s.cfg.GatewayPublicBaseURL),
		PublicWsURL:   firstNonEmpty(req.PublicWsURL, s.cfg.GatewayPublicWsURL),
	}
}

func (s *Service) assignWorker(sessionID, region string) contracts.WorkerAssignment {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.workerIndex[region]++
	index := s.workerIndex[region]
	suffix := s.cfg.ZoneSuffixes[(index-1)%len(s.cfg.ZoneSuffixes)]

	return contracts.WorkerAssignment{
		SessionID:        sessionID,
		WorkerID:         fmt.Sprintf("worker-%s-%03d", region, ((index-1)%s.cfg.WorkersPerRegion)+1),
		Region:           region,
		RuntimeClass:     s.cfg.RuntimeClass,
		NodePool:         s.cfg.NodePool,
		AvailabilityZone: region + suffix,
	}
}

func (s *Service) buildHandoffURL(req contracts.EdgeBootstrapRequest) string {
	baseURL := firstNonEmpty(req.PublicBaseURL, s.cfg.HandoffBaseURL)
	token := newOpaqueID("hnd_")

	parsed, err := url.Parse(baseURL)
	if err != nil {
		return baseURL
	}

	parsed.Path = joinURLPath(parsed.Path, "/swg/handoff")
	query := parsed.Query()
	query.Set("token", token)
	parsed.RawQuery = query.Encode()
	return parsed.String()
}

func (s *Service) requireInternalSecret(r *http.Request) error {
	if s.cfg.InternalSharedSecret == "" {
		return nil
	}
	if r.Header.Get("X-RBI-Internal-Secret") != s.cfg.InternalSharedSecret {
		return &apiError{status: http.StatusUnauthorized, message: "invalid internal secret"}
	}
	return nil
}

type runtimeClient struct {
	baseURL string
	secret  string
	client  *http.Client
}

type mediaGatewayClient struct {
	baseURL string
	secret  string
	client  *http.Client
}

func newRuntimeClient(cfg Config) RuntimeClient {
	if cfg.RuntimeBaseURL == "" {
		return nil
	}

	timeout := cfg.RuntimeRequestTimeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}

	return &runtimeClient{
		baseURL: cfg.RuntimeBaseURL,
		secret:  cfg.RuntimeSharedSecret,
		client: &http.Client{
			Timeout: timeout,
		},
	}
}

func newMediaGatewayClient(cfg Config) GatewayClient {
	if cfg.MediaGatewayBaseURL == "" {
		return nil
	}

	timeout := cfg.MediaGatewayRequestTimeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}

	return &mediaGatewayClient{
		baseURL: cfg.MediaGatewayBaseURL,
		secret:  cfg.InternalSharedSecret,
		client: &http.Client{
			Timeout: timeout,
		},
	}
}

func (c *runtimeClient) CreateSession(ctx context.Context, req contracts.RuntimeSessionRequest) (contracts.RuntimeSessionResponse, error) {
	endpoint := c.baseURL + "/api/internal/sessions"
	body, err := json.Marshal(req)
	if err != nil {
		return contracts.RuntimeSessionResponse{}, err
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return contracts.RuntimeSessionResponse{}, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if c.secret != "" {
		httpReq.Header.Set("X-RBI-Internal-Secret", c.secret)
	}

	resp, err := c.client.Do(httpReq)
	if err != nil {
		return contracts.RuntimeSessionResponse{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return contracts.RuntimeSessionResponse{}, fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(message)))
	}

	var payload contracts.RuntimeSessionResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&payload); err != nil {
		return contracts.RuntimeSessionResponse{}, err
	}

	return payload, nil
}

func (c *runtimeClient) UpdateSession(ctx context.Context, sessionID string, req contracts.RuntimeSessionUpdateRequest) (contracts.RuntimeSessionResponse, error) {
	endpoint := c.baseURL + "/api/internal/sessions/" + url.PathEscape(sessionID)
	body, err := json.Marshal(req)
	if err != nil {
		return contracts.RuntimeSessionResponse{}, err
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPatch, endpoint, bytes.NewReader(body))
	if err != nil {
		return contracts.RuntimeSessionResponse{}, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if c.secret != "" {
		httpReq.Header.Set("X-RBI-Internal-Secret", c.secret)
	}

	resp, err := c.client.Do(httpReq)
	if err != nil {
		return contracts.RuntimeSessionResponse{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return contracts.RuntimeSessionResponse{}, fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(message)))
	}

	var payload contracts.RuntimeSessionResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&payload); err != nil {
		return contracts.RuntimeSessionResponse{}, err
	}

	return payload, nil
}

func (c *mediaGatewayClient) CreateSession(ctx context.Context, req contracts.MediaGatewaySessionRequest) (contracts.MediaGatewaySessionResponse, error) {
	endpoint := c.baseURL + "/v1/sessions"
	body, err := json.Marshal(req)
	if err != nil {
		return contracts.MediaGatewaySessionResponse{}, err
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return contracts.MediaGatewaySessionResponse{}, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if c.secret != "" {
		httpReq.Header.Set("X-RBI-Internal-Secret", c.secret)
	}

	resp, err := c.client.Do(httpReq)
	if err != nil {
		return contracts.MediaGatewaySessionResponse{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return contracts.MediaGatewaySessionResponse{}, fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(message)))
	}

	var payload contracts.MediaGatewaySessionResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&payload); err != nil {
		return contracts.MediaGatewaySessionResponse{}, err
	}

	return payload, nil
}

func newOpaqueID(prefix string) string {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return prefix + strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	return prefix + hex.EncodeToString(buf)
}

func buildRuntimeSessionRequest(
	req contracts.EdgeBootstrapRequest,
	gatewayAssignment contracts.GatewayAssignment,
	workerAssignment contracts.WorkerAssignment,
) contracts.RuntimeSessionRequest {
	client := cloneMap(req.Client)
	swg := cloneMap(asMap(client["swg"]))
	swg["transactionId"] = req.TransactionID
	swg["tenantId"] = req.TenantID
	swg["profileId"] = req.ProfileID
	swg["policy"] = req.Policy
	swg["upstreamHost"] = req.UpstreamHost
	swg["upstreamScheme"] = req.UpstreamScheme
	swg["upstreamPort"] = req.UpstreamPort
	client["swg"] = swg
	client["authMode"] = firstNonEmpty(asString(client["authMode"]), "swg")

	requestContext := map[string]any{
		"mode":           "swg",
		"transactionId":  req.TransactionID,
		"tenantId":       req.TenantID,
		"profileId":      req.ProfileID,
		"policy":         req.Policy,
		"upstreamHost":   req.UpstreamHost,
		"upstreamScheme": req.UpstreamScheme,
		"upstreamPort":   req.UpstreamPort,
		"swg":            swg,
	}
	if identity, ok := client["identity"]; ok {
		requestContext["identity"] = identity
	}

	gatewayPlacement := gatewayAssignment
	workerPlacement := workerAssignment
	gatewayPlacement.SessionID = ""
	workerPlacement.SessionID = ""

	return contracts.RuntimeSessionRequest{
		TargetURL:      req.TargetURL,
		Viewport:       req.Viewport,
		Experiments:    cloneMap(req.Experiments),
		Client:         client,
		PublicBaseURL:  req.PublicBaseURL,
		PublicWsURL:    req.PublicWsURL,
		RequestContext: requestContext,
		SessionPlacement: &contracts.SessionPlacement{
			GatewayAssignment: &gatewayPlacement,
			WorkerAssignment:  &workerPlacement,
		},
	}
}

func buildMediaGatewaySessionRequest(
	req contracts.EdgeBootstrapRequest,
	resp contracts.EdgeBootstrapResponse,
	runtimeResp contracts.RuntimeSessionResponse,
	gatewayAssignment contracts.GatewayAssignment,
	workerAssignment contracts.WorkerAssignment,
) contracts.MediaGatewaySessionRequest {
	viewerToken := firstNonEmpty(runtimeResp.ViewerSignalingToken, runtimeResp.ViewerToken)
	return contracts.MediaGatewaySessionRequest{
		SessionID:         resp.SessionID,
		TenantID:          req.TenantID,
		ProfileID:         req.ProfileID,
		TargetURL:         req.TargetURL,
		ViewerEntryMode:   firstNonEmpty(resp.ViewerEntry, runtimeResp.ViewerEntry),
		Generation:        maxInt(runtimeResp.Generation, 1),
		ViewerToken:       viewerToken,
		WorkerToken:       runtimeResp.WorkerToken,
		Client:            cloneMap(req.Client),
		Experiments:       cloneMap(req.Experiments),
		PublicBaseURL:     firstNonEmpty(req.PublicBaseURL, gatewayAssignment.PublicBaseURL),
		PublicWsURL:       firstNonEmpty(req.PublicWsURL, gatewayAssignment.PublicWsURL),
		GatewayAssignment: gatewayAssignment,
		WorkerAssignment:  workerAssignment,
	}
}

func buildRuntimeSessionUpdateRequest(
	resp contracts.MediaGatewaySessionResponse,
) contracts.RuntimeSessionUpdateRequest {
	gatewayAssignment := resp.GatewayAssignment
	workerAssignment := resp.WorkerAssignment
	return contracts.RuntimeSessionUpdateRequest{
		SessionPlacement: &contracts.SessionPlacement{
			GatewayAssignment: &gatewayAssignment,
			WorkerAssignment:  &workerAssignment,
		},
		Transport:    &resp.Transport,
		WorkerBridge: &resp.WorkerBridge,
	}
}

func validateMediaGatewaySessionResponse(req contracts.MediaGatewaySessionRequest, resp contracts.MediaGatewaySessionResponse) error {
	switch {
	case resp.SessionID == "":
		return &apiError{status: http.StatusBadGateway, message: "media gateway response missing sessionId"}
	case resp.SessionID != req.SessionID:
		return &apiError{status: http.StatusBadGateway, message: "media gateway response sessionId does not match request"}
	case strings.TrimSpace(resp.GatewayAssignment.GatewayID) == "":
		return &apiError{status: http.StatusBadGateway, message: "media gateway response missing gatewayAssignment.gatewayId"}
	case strings.TrimSpace(resp.WorkerAssignment.WorkerID) == "":
		return &apiError{status: http.StatusBadGateway, message: "media gateway response missing workerAssignment.workerId"}
	case strings.TrimSpace(resp.Transport.ViewerURL) == "":
		return &apiError{status: http.StatusBadGateway, message: "media gateway response missing transport.viewerUrl"}
	case !isAbsoluteURLWithScheme(resp.Transport.ViewerURL, "http", "https"):
		return &apiError{status: http.StatusBadGateway, message: "media gateway response transport.viewerUrl is invalid"}
	case strings.TrimSpace(resp.Transport.SignalingURL) == "":
		return &apiError{status: http.StatusBadGateway, message: "media gateway response missing transport.signalingUrl"}
	case !isAbsoluteURLWithScheme(resp.Transport.SignalingURL, "ws", "wss"):
		return &apiError{status: http.StatusBadGateway, message: "media gateway response transport.signalingUrl is invalid"}
	case strings.TrimSpace(resp.WorkerBridge.BridgeID) == "":
		return &apiError{status: http.StatusBadGateway, message: "media gateway response missing workerBridge.bridgeId"}
	}

	relayMode := firstNonEmpty(resp.WorkerBridge.RelayMode, resp.GatewayAssignment.RelayMode, req.GatewayAssignment.RelayMode)
	if relayMode != relayModeGatewayMediaRelay {
		return nil
	}
	switch {
	case strings.TrimSpace(req.ViewerToken) == "":
		return &apiError{status: http.StatusBadGateway, message: "media gateway request missing viewerToken for gateway-media-relay"}
	case strings.TrimSpace(req.WorkerToken) == "":
		return &apiError{status: http.StatusBadGateway, message: "media gateway request missing workerToken for gateway-media-relay"}
	case strings.TrimSpace(req.ViewerToken) == strings.TrimSpace(req.WorkerToken):
		return &apiError{status: http.StatusBadGateway, message: "media gateway request viewerToken and workerToken must be role-bound"}
	case strings.TrimSpace(resp.Transport.MediaRelayURL) == "":
		return &apiError{status: http.StatusBadGateway, message: "media gateway response missing transport.mediaRelayUrl"}
	case !isAbsoluteURLWithScheme(resp.Transport.MediaRelayURL, "ws", "wss"):
		return &apiError{status: http.StatusBadGateway, message: "media gateway response transport.mediaRelayUrl is invalid"}
	case strings.TrimSpace(resp.WorkerBridge.MediaRelayURL) == "":
		return &apiError{status: http.StatusBadGateway, message: "media gateway response missing workerBridge.mediaRelayUrl"}
	case !isAbsoluteURLWithScheme(resp.WorkerBridge.MediaRelayURL, "ws", "wss"):
		return &apiError{status: http.StatusBadGateway, message: "media gateway response workerBridge.mediaRelayUrl is invalid"}
	case resp.Transport.MediaTermination == nil:
		return &apiError{status: http.StatusBadGateway, message: "media gateway response missing transport.mediaTermination"}
	case strings.TrimSpace(resp.Transport.MediaGatewayURL) == "":
		return &apiError{status: http.StatusBadGateway, message: "media gateway response missing transport.mediaGatewayUrl"}
	case !isAbsoluteURLWithScheme(resp.Transport.MediaGatewayURL, "http", "https"):
		return &apiError{status: http.StatusBadGateway, message: "media gateway response transport.mediaGatewayUrl is invalid"}
	case !isRoleBoundGatewayWebRTCEndpoint(resp.Transport.MediaGatewayURL, resp.SessionID, "viewer"):
		return &apiError{status: http.StatusBadGateway, message: "media gateway response transport.mediaGatewayUrl is not viewer role-bound"}
	case strings.TrimSpace(resp.WorkerBridge.MediaGatewayURL) == "":
		return &apiError{status: http.StatusBadGateway, message: "media gateway response missing workerBridge.mediaGatewayUrl"}
	case !isAbsoluteURLWithScheme(resp.WorkerBridge.MediaGatewayURL, "http", "https"):
		return &apiError{status: http.StatusBadGateway, message: "media gateway response workerBridge.mediaGatewayUrl is invalid"}
	case !isRoleBoundGatewayWebRTCEndpoint(resp.WorkerBridge.MediaGatewayURL, resp.SessionID, "worker"):
		return &apiError{status: http.StatusBadGateway, message: "media gateway response workerBridge.mediaGatewayUrl is not worker role-bound"}
	case strings.TrimSpace(resp.Transport.MediaPlaneMode) != mediaPlaneModeGatewayWebRTCRelay:
		return &apiError{status: http.StatusBadGateway, message: "media gateway response requires gateway-webrtc-relay mediaPlaneMode"}
	case strings.TrimSpace(resp.Transport.Protocol) != mediaTerminationProtocolWebRTCSRTP:
		return &apiError{status: http.StatusBadGateway, message: "media gateway response requires webrtc-srtp transport protocol"}
	case strings.TrimSpace(resp.WorkerBridge.Protocol) != mediaTerminationProtocolWebRTCSRTP:
		return &apiError{status: http.StatusBadGateway, message: "media gateway response requires webrtc-srtp workerBridge protocol"}
	case resp.Transport.MediaTermination.RelayMode != relayModeGatewayMediaRelay || !resp.Transport.MediaTermination.GatewayTerminatesMedia:
		return &apiError{status: http.StatusBadGateway, message: "media gateway response missing gateway-media-relay capability"}
	case strings.TrimSpace(resp.Transport.MediaTermination.MediaPlaneMode) != mediaPlaneModeGatewayWebRTCRelay:
		return &apiError{status: http.StatusBadGateway, message: "media gateway response mediaTermination requires gateway-webrtc-relay mediaPlaneMode"}
	case strings.TrimSpace(resp.Transport.MediaTermination.Protocol) != mediaTerminationProtocolWebRTCSRTP:
		return &apiError{status: http.StatusBadGateway, message: "media gateway response mediaTermination requires webrtc-srtp protocol"}
	default:
		return nil
	}
}

func isRoleBoundGatewayWebRTCEndpoint(raw string, sessionID string, role string) bool {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return false
	}
	path := strings.TrimRight(parsed.Path, "/")
	expectedSuffix := "/gateway/webrtc/" + sessionID + "/" + role
	return strings.HasSuffix(path, expectedSuffix)
}

func mergeGatewayAssignment(gateway contracts.GatewayAssignment, runtime *contracts.GatewayAssignment) contracts.GatewayAssignment {
	if runtime == nil {
		return gateway
	}
	result := gateway
	if result.SessionID == "" {
		result.SessionID = runtime.SessionID
	}
	if result.GatewayID == "" {
		result.GatewayID = runtime.GatewayID
	}
	if result.Region == "" {
		result.Region = runtime.Region
	}
	if result.WorkerID == "" {
		result.WorkerID = runtime.WorkerID
	}
	if result.RelayMode == "" {
		result.RelayMode = runtime.RelayMode
	}
	if result.PublicBaseURL == "" {
		result.PublicBaseURL = runtime.PublicBaseURL
	}
	if result.PublicWsURL == "" {
		result.PublicWsURL = runtime.PublicWsURL
	}
	return result
}

func mergeWorkerAssignment(gateway contracts.WorkerAssignment, runtime *contracts.WorkerAssignment) contracts.WorkerAssignment {
	if runtime == nil {
		return gateway
	}
	result := gateway
	if result.SessionID == "" {
		result.SessionID = runtime.SessionID
	}
	if result.WorkerID == "" {
		result.WorkerID = runtime.WorkerID
	}
	if result.Region == "" {
		result.Region = runtime.Region
	}
	if result.RuntimeClass == "" {
		result.RuntimeClass = runtime.RuntimeClass
	}
	if result.NodePool == "" {
		result.NodePool = runtime.NodePool
	}
	if result.AvailabilityZone == "" {
		result.AvailabilityZone = runtime.AvailabilityZone
	}
	return result
}

func mergeGatewayTransport(gateway contracts.GatewayTransport, runtime *contracts.GatewayTransport) *contracts.GatewayTransport {
	result := gateway
	if runtime != nil {
		if result.Preferred == "" {
			result.Preferred = runtime.Preferred
		}
		if len(result.Supported) == 0 {
			result.Supported = append([]string(nil), runtime.Supported...)
		}
		if result.ViewerURL == "" {
			result.ViewerURL = runtime.ViewerURL
		}
		if result.SignalingURL == "" {
			result.SignalingURL = runtime.SignalingURL
		}
		if result.MediaRelayURL == "" {
			result.MediaRelayURL = runtime.MediaRelayURL
		}
		if result.MediaTermination == nil && runtime.MediaTermination != nil {
			mediaTermination := *runtime.MediaTermination
			result.MediaTermination = &mediaTermination
		}
	}
	if result.Supported != nil {
		result.Supported = append([]string(nil), result.Supported...)
	}
	if result.MediaTermination != nil {
		mediaTermination := *result.MediaTermination
		result.MediaTermination = &mediaTermination
	}
	return &result
}

func mergeWorkerBridge(gateway contracts.WorkerBridge, runtime *contracts.WorkerBridge) *contracts.WorkerBridge {
	result := gateway
	if runtime != nil {
		if result.BridgeID == "" {
			result.BridgeID = runtime.BridgeID
		}
		if result.RelayMode == "" {
			result.RelayMode = runtime.RelayMode
		}
		if result.MediaRelayURL == "" {
			result.MediaRelayURL = runtime.MediaRelayURL
		}
	}
	return &result
}

func isAbsoluteURLWithScheme(raw string, allowedSchemes ...string) bool {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return false
	}
	for _, scheme := range allowedSchemes {
		if parsed.Scheme == scheme {
			return true
		}
	}
	return false
}

func hashString(value string) uint32 {
	hasher := fnv.New32a()
	_, _ = hasher.Write([]byte(value))
	return hasher.Sum32()
}

func deriveWSURL(baseURL string) string {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return ""
	}

	switch parsed.Scheme {
	case "https":
		parsed.Scheme = "wss"
	case "http":
		parsed.Scheme = "ws"
	}
	parsed.Path = joinURLPath(parsed.Path, "/ws")
	parsed.RawQuery = ""
	return parsed.String()
}

func joinURLPath(basePath, next string) string {
	basePath = strings.TrimRight(basePath, "/")
	next = "/" + strings.TrimLeft(next, "/")
	if basePath == "" {
		return next
	}
	return basePath + next
}

func parseCSV(raw string) []string {
	if raw == "" {
		return nil
	}

	var items []string
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part != "" {
			items = append(items, part)
		}
	}
	return items
}

func parseCSVOrDefault(raw string, fallback []string) []string {
	items := parseCSV(raw)
	if len(items) == 0 {
		return fallback
	}
	return items
}

func parseAssignments(raw string) map[string]string {
	assignments := make(map[string]string)
	for _, item := range parseCSV(raw) {
		parts := strings.SplitN(item, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])
		if key != "" && value != "" {
			assignments[key] = value
		}
	}
	return assignments
}

func parsePositiveInt(raw string, fallback int) int {
	if raw == "" {
		return fallback
	}

	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return fallback
	}
	return value
}

func getenvDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func maxInt(value, fallback int) int {
	if value > 0 {
		return value
	}
	return fallback
}

func cloneMap(input map[string]any) map[string]any {
	if len(input) == 0 {
		return map[string]any{}
	}

	cloned := make(map[string]any, len(input))
	for key, value := range input {
		cloned[key] = value
	}
	return cloned
}

func asMap(value any) map[string]any {
	if existing, ok := value.(map[string]any); ok {
		return existing
	}
	return nil
}

func asString(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	return ""
}
