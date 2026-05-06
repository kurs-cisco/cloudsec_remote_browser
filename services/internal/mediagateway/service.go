package mediagateway

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"cloudsec_remote_browser/services/internal/contracts"
	"cloudsec_remote_browser/services/internal/httpx"
)

const serviceName = "media-gateway"

const (
	relayModeGatewayRelay              = "gateway-relay"
	relayModeGatewayMediaRelay         = "gateway-media-relay"
	relayModeAcceptanceStateAccepted   = "accepted"
	relayModeAcceptanceStateNoSessions = "no-sessions"
	relayModeAcceptanceStatePartial    = "partial"
	relayModeAcceptanceStateRejected   = "rejected"
	mediaTerminationModeSignalingRelay = "signaling-relay-only"
	mediaTerminationModeGatewayRelay   = "gateway-media-relay"
	mediaPlaneModeGatewayWebRTCRelay   = "gateway-webrtc-relay"
	mediaTerminationProtocolWebRTCSRTP = "webrtc-srtp"
	mediaTerminationStatusIncomplete   = "incomplete"
	mediaTerminationStatusImplemented  = "implemented"
	workerAddressExposureGatewayOnly   = "gateway-only"
	inputPointerChannelName            = "input-pointer"
	inputControlChannelName            = "input-control"
	defaultPendingSessionActiveTTL     = 2 * time.Minute
	defaultGatewaySessionStoreTTL      = 3 * time.Hour
	defaultGatewayForwardTimeout       = 5 * time.Second
)

type Config struct {
	Region                     string
	GatewayID                  string
	PublicBaseURL              string
	PublicWsURL                string
	WorkerBaseURL              string
	WorkerWsURL                string
	ICEURLs                    []string
	TURNUsername               string
	TURNPassword               string
	TURNSharedSecret           string
	TURNCredentialTTL          time.Duration
	SupportedTransports        []string
	PreferredTransport         string
	RelayMode                  string
	EnableMediaRelay           bool
	MaxActiveSessions          int
	MaxActiveSessionsPerTenant int
	MaxActiveSessionsPerWorker int
	InternalSharedSecret       string
	RuntimeNotifyBaseURL       string
	RuntimeRequestTimeout      time.Duration
	PendingSessionActiveTTL    time.Duration
	StateBackend               string
	RedisURL                   string
	RedisTLS                   bool
	RedisKeyPrefix             string
	InstanceID                 string
	InstanceBaseURL            string
	SessionStoreTTL            time.Duration
	ForwardRequestTimeout      time.Duration
}

type Service struct {
	cfg             Config
	runtimeNotifier runtimeSessionNotifier
	sessionStore    gatewaySessionStore
	instance        gatewayInstance
	mu              sync.RWMutex
	sessions        map[string]SessionRecord
	signals         map[string]*signalSessionState
	mediaRelays     map[string]*mediaSessionState
	webrtcRelays    map[string]*pionRelaySession
	codecRejects    WebRTCCodecRejectSummary
	admission       admissionState
}

type SignalStateSnapshot struct {
	ViewerConnected        bool       `json:"viewerConnected"`
	WorkerConnected        bool       `json:"workerConnected"`
	PendingViewerSignals   int        `json:"pendingViewerSignals"`
	PendingWorkerSignals   int        `json:"pendingWorkerSignals"`
	ViewerConnectEvents    int        `json:"viewerConnectEvents"`
	WorkerConnectEvents    int        `json:"workerConnectEvents"`
	ViewerDisconnectEvents int        `json:"viewerDisconnectEvents"`
	WorkerDisconnectEvents int        `json:"workerDisconnectEvents"`
	ViewerHeartbeats       int        `json:"viewerHeartbeats"`
	ViewerSignalMessages   int        `json:"viewerSignalMessages"`
	WorkerStateUpdates     int        `json:"workerStateUpdates"`
	SignalsToViewer        int        `json:"signalsToViewer"`
	SignalsToWorker        int        `json:"signalsToWorker"`
	LastViewerSeenAt       *time.Time `json:"lastViewerSeenAt,omitempty"`
	LastWorkerState        string     `json:"lastWorkerState,omitempty"`
	LastWorkerStateAt      *time.Time `json:"lastWorkerStateAt,omitempty"`
	LastSignalForwardedAt  *time.Time `json:"lastSignalForwardedAt,omitempty"`
	Terminated             bool       `json:"terminated"`
	TerminatedAt           *time.Time `json:"terminatedAt,omitempty"`
	TerminationReason      string     `json:"terminationReason,omitempty"`
}

type SessionRecord struct {
	Request          contracts.MediaGatewaySessionRequest  `json:"request"`
	Response         contracts.MediaGatewaySessionResponse `json:"response"`
	Admission        *AdmissionDecision                    `json:"admission,omitempty"`
	ViewerEntryToken string                                `json:"viewerEntryToken,omitempty"`
	SignalState      *SignalStateSnapshot                  `json:"signalState,omitempty"`
	MediaRelayState  *MediaRelayStateSnapshot              `json:"mediaRelayState,omitempty"`
	WebRTCRelayState *WebRTCRelayStateSnapshot             `json:"webRtcRelayState,omitempty"`
	CreatedAt        time.Time                             `json:"createdAt"`
}

type SummaryResponse struct {
	Region                      string                   `json:"region"`
	GatewayID                   string                   `json:"gatewayId"`
	SessionsTotal               int                      `json:"sessionsTotal"`
	ActiveSessions              int                      `json:"activeSessions"`
	ActiveSessionsByTenant      map[string]int           `json:"activeSessionsByTenant"`
	ActiveSessionsByWorker      map[string]int           `json:"activeSessionsByWorker"`
	SignalSessions              int                      `json:"signalSessions"`
	ViewerConnected             int                      `json:"viewerConnected"`
	WorkerConnected             int                      `json:"workerConnected"`
	TerminatedSignals           int                      `json:"terminatedSignals"`
	PendingViewerSignals        int                      `json:"pendingViewerSignals"`
	PendingWorkerSignals        int                      `json:"pendingWorkerSignals"`
	ViewerConnectEvents         int                      `json:"viewerConnectEvents"`
	WorkerConnectEvents         int                      `json:"workerConnectEvents"`
	ViewerDisconnectEvents      int                      `json:"viewerDisconnectEvents"`
	WorkerDisconnectEvents      int                      `json:"workerDisconnectEvents"`
	ViewerHeartbeats            int                      `json:"viewerHeartbeats"`
	ViewerSignalMessages        int                      `json:"viewerSignalMessages"`
	WorkerStateUpdates          int                      `json:"workerStateUpdates"`
	SignalsToViewer             int                      `json:"signalsToViewer"`
	SignalsToWorker             int                      `json:"signalsToWorker"`
	MediaRelaySessions          int                      `json:"mediaRelaySessions"`
	MediaViewerConnected        int                      `json:"mediaViewerConnected"`
	MediaWorkerConnected        int                      `json:"mediaWorkerConnected"`
	MediaPendingViewerFrames    int                      `json:"mediaPendingViewerFrames"`
	MediaPendingWorkerFrames    int                      `json:"mediaPendingWorkerFrames"`
	MediaMaxPendingViewerFrames int                      `json:"mediaMaxPendingViewerFrames"`
	MediaMaxPendingWorkerFrames int                      `json:"mediaMaxPendingWorkerFrames"`
	MediaDroppedViewerFrames    int                      `json:"mediaDroppedViewerFrames"`
	MediaDroppedWorkerFrames    int                      `json:"mediaDroppedWorkerFrames"`
	MediaFramesToViewer         int                      `json:"mediaFramesToViewer"`
	MediaFramesToWorker         int                      `json:"mediaFramesToWorker"`
	MediaBytesToViewer          int                      `json:"mediaBytesToViewer"`
	MediaBytesToWorker          int                      `json:"mediaBytesToWorker"`
	WebRTCRelaySessions         int                      `json:"webRtcRelaySessions"`
	WebRTCActiveRelaySessions   int                      `json:"webRtcActiveRelaySessions"`
	WebRTCTerminatedRelays      int                      `json:"webRtcTerminatedRelays"`
	WebRTCWorkerConnected       int                      `json:"webRtcWorkerConnected"`
	WebRTCViewerConnected       int                      `json:"webRtcViewerConnected"`
	WebRTCRTPPacketsToViewer    int64                    `json:"webRtcRtpPacketsToViewer"`
	WebRTCRTPBytesToViewer      int64                    `json:"webRtcRtpBytesToViewer"`
	WebRTCRTCPPacketsToWorker   int64                    `json:"webRtcRtcpPacketsToWorker"`
	WebRTCRTCPFeedbackByType    map[string]int64         `json:"webRtcRtcpFeedbackByType"`
	WebRTCDataMessagesToWorker  int64                    `json:"webRtcDataMessagesToWorker"`
	WebRTCDataMessagesToViewer  int64                    `json:"webRtcDataMessagesToViewer"`
	WebRTCPointerDrops          int64                    `json:"webRtcPointerDrops"`
	WebRTCControlDrops          int64                    `json:"webRtcControlDrops"`
	WebRTCPendingPointer        int                      `json:"webRtcPendingPointerMessages"`
	WebRTCPendingControl        int                      `json:"webRtcPendingControlMessages"`
	WebRTCTerminationReasons    map[string]int           `json:"webRtcTerminationReasons"`
	WebRTCLastTerminationReason string                   `json:"webRtcLastTerminationReason,omitempty"`
	WebRTCCodecRejects          WebRTCCodecRejectSummary `json:"webRtcCodecRejects"`
	Transports                  map[string]int           `json:"transports"`
	MediaTermination            MediaTerminationSummary  `json:"mediaTermination"`
	Admission                   AdmissionSummary         `json:"admission"`
}

type WebRTCRelayStateSnapshot struct {
	WorkerPeerState        string           `json:"workerPeerState,omitempty"`
	ViewerPeerState        string           `json:"viewerPeerState,omitempty"`
	WorkerICEState         string           `json:"workerIceState,omitempty"`
	ViewerICEState         string           `json:"viewerIceState,omitempty"`
	WorkerTracks           int              `json:"workerTracks"`
	ViewerTracks           int              `json:"viewerTracks"`
	RTPPacketsToViewer     int64            `json:"rtpPacketsToViewer"`
	RTPBytesToViewer       int64            `json:"rtpBytesToViewer"`
	RTCPPacketsToWorker    int64            `json:"rtcpPacketsToWorker"`
	RTCPFeedbackByType     map[string]int64 `json:"rtcpFeedbackByType,omitempty"`
	DataMessagesToWorker   int64            `json:"dataMessagesToWorker"`
	DataMessagesToViewer   int64            `json:"dataMessagesToViewer"`
	PointerDroppedMessages int64            `json:"pointerDroppedMessages"`
	ControlDroppedMessages int64            `json:"controlDroppedMessages"`
	PendingPointerMessages int              `json:"pendingPointerMessages"`
	PendingControlMessages int              `json:"pendingControlMessages"`
	WorkerDataChannels     []string         `json:"workerDataChannels,omitempty"`
	ViewerDataChannels     []string         `json:"viewerDataChannels,omitempty"`
	LastRTPRelayedAt       *time.Time       `json:"lastRtpRelayedAt,omitempty"`
	LastRTCPForwardedAt    *time.Time       `json:"lastRtcpForwardedAt,omitempty"`
	LastDataForwardedAt    *time.Time       `json:"lastDataForwardedAt,omitempty"`
	Terminated             bool             `json:"terminated"`
	TerminationReason      string           `json:"terminationReason,omitempty"`
}

type WebRTCCodecRejectSummary struct {
	Total    int            `json:"total"`
	ByRole   map[string]int `json:"byRole"`
	ByReason map[string]int `json:"byReason"`
}

type MediaTerminationSummary struct {
	DefaultCapability                     contracts.MediaTerminationCapability `json:"defaultCapability"`
	SessionsByMode                        map[string]int                       `json:"sessionsByMode"`
	SessionsWithGatewayTerminatedMedia    int                                  `json:"sessionsWithGatewayTerminatedMedia"`
	SessionsWithoutGatewayTerminatedMedia int                                  `json:"sessionsWithoutGatewayTerminatedMedia"`
	RelayModeAcceptance                   RelayModeAcceptanceSummary           `json:"relayModeAcceptance"`
	Wave2AcceptanceComplete               bool                                 `json:"wave2AcceptanceComplete"`
}

type RelayModeAcceptanceSummary struct {
	AcceptedMode                   string `json:"acceptedMode"`
	AcceptanceState                string `json:"acceptanceState"`
	AcceptedSessions               int    `json:"acceptedSessions"`
	RejectedUnsupportedRelayMode   int    `json:"rejectedUnsupportedRelayMode"`
	RejectedDirectWorkerExposure   int    `json:"rejectedDirectWorkerExposure"`
	DirectWorkerExposureAllowed    bool   `json:"directWorkerExposureAllowed"`
	Wave2MediaTerminationState     string `json:"wave2MediaTerminationState"`
	Wave2MediaTerminationStateNote string `json:"wave2MediaTerminationStateNote,omitempty"`
}

type apiError struct {
	status  int
	message string
}

func (e *apiError) Error() string {
	return e.message
}

func LoadConfigFromEnv() Config {
	region := getenvDefault("MEDIA_GATEWAY_REGION", "us-east-1")
	baseURL := getenvDefault("MEDIA_GATEWAY_PUBLIC_BASE_URL", "https://gateway.example.com")
	transports := parseCSVOrDefault(os.Getenv("MEDIA_GATEWAY_SUPPORTED_TRANSPORTS"), []string{"webtransport", "webrtc", "websocket"})

	cfg := Config{
		Region:                     region,
		GatewayID:                  getenvDefault("MEDIA_GATEWAY_ID", "gateway-"+region+"-01"),
		PublicBaseURL:              baseURL,
		PublicWsURL:                getenvDefault("MEDIA_GATEWAY_PUBLIC_WS_URL", deriveWSURL(baseURL)),
		WorkerBaseURL:              strings.TrimRight(os.Getenv("MEDIA_GATEWAY_WORKER_BASE_URL"), "/"),
		WorkerWsURL:                strings.TrimRight(os.Getenv("MEDIA_GATEWAY_WORKER_WS_URL"), "/"),
		ICEURLs:                    parseCSV(os.Getenv("MEDIA_GATEWAY_ICE_URLS")),
		TURNUsername:               firstNonEmpty(os.Getenv("MEDIA_GATEWAY_TURN_USERNAME"), os.Getenv("TURN_USERNAME")),
		TURNPassword:               firstNonEmpty(os.Getenv("MEDIA_GATEWAY_TURN_PASSWORD"), os.Getenv("TURN_PASSWORD")),
		TURNSharedSecret:           firstNonEmpty(os.Getenv("MEDIA_GATEWAY_TURN_SHARED_SECRET"), os.Getenv("TURN_SHARED_SECRET")),
		TURNCredentialTTL:          time.Duration(parsePositiveInt(firstNonEmpty(os.Getenv("MEDIA_GATEWAY_TURN_CREDENTIAL_TTL_SECONDS"), os.Getenv("TURN_CREDENTIAL_TTL_SECONDS")), 300)) * time.Second,
		SupportedTransports:        transports,
		PreferredTransport:         getenvDefault("MEDIA_GATEWAY_PREFERRED_TRANSPORT", transports[0]),
		RelayMode:                  getenvDefault("MEDIA_GATEWAY_DEFAULT_RELAY_MODE", relayModeGatewayMediaRelay),
		EnableMediaRelay:           parseBool(os.Getenv("MEDIA_GATEWAY_ENABLE_MEDIA_RELAY"), true),
		MaxActiveSessions:          parseNonNegativeInt(os.Getenv("MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS"), 0),
		MaxActiveSessionsPerTenant: parseNonNegativeInt(os.Getenv("MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS_PER_TENANT"), 0),
		MaxActiveSessionsPerWorker: parseNonNegativeInt(os.Getenv("MEDIA_GATEWAY_MAX_ACTIVE_SESSIONS_PER_WORKER"), 1),
		InternalSharedSecret:       os.Getenv("RBI_INTERNAL_SHARED_SECRET"),
		RuntimeNotifyBaseURL:       strings.TrimRight(os.Getenv("MEDIA_GATEWAY_RUNTIME_NOTIFY_BASE_URL"), "/"),
		RuntimeRequestTimeout:      time.Duration(parsePositiveInt(os.Getenv("MEDIA_GATEWAY_RUNTIME_TIMEOUT_SECONDS"), 5)) * time.Second,
		PendingSessionActiveTTL:    time.Duration(parsePositiveInt(os.Getenv("MEDIA_GATEWAY_PENDING_SESSION_ACTIVE_TTL_SECONDS"), int(defaultPendingSessionActiveTTL/time.Second))) * time.Second,
		StateBackend:               strings.TrimSpace(os.Getenv("MEDIA_GATEWAY_STATE_BACKEND")),
		RedisURL:                   strings.TrimSpace(firstNonEmpty(os.Getenv("MEDIA_GATEWAY_REDIS_URL"), os.Getenv("REDIS_URL"))),
		RedisTLS:                   parseBool(firstNonEmpty(os.Getenv("MEDIA_GATEWAY_REDIS_TLS"), os.Getenv("REDIS_TLS")), false),
		RedisKeyPrefix:             strings.TrimSpace(firstNonEmpty(os.Getenv("MEDIA_GATEWAY_REDIS_KEY_PREFIX"), os.Getenv("REDIS_KEY_PREFIX"))),
		InstanceID:                 strings.TrimSpace(firstNonEmpty(os.Getenv("MEDIA_GATEWAY_INSTANCE_ID"), os.Getenv("HOSTNAME"))),
		InstanceBaseURL:            strings.TrimRight(strings.TrimSpace(os.Getenv("MEDIA_GATEWAY_INSTANCE_BASE_URL")), "/"),
		SessionStoreTTL:            time.Duration(parsePositiveInt(os.Getenv("MEDIA_GATEWAY_SESSION_STORE_TTL_SECONDS"), int(defaultGatewaySessionStoreTTL/time.Second))) * time.Second,
		ForwardRequestTimeout:      time.Duration(parsePositiveInt(os.Getenv("MEDIA_GATEWAY_FORWARD_TIMEOUT_SECONDS"), int(defaultGatewayForwardTimeout/time.Second))) * time.Second,
	}

	return cfg
}

func NewService(cfg Config) *Service {
	if cfg.Region == "" {
		cfg.Region = "us-east-1"
	}
	if cfg.GatewayID == "" {
		cfg.GatewayID = "gateway-" + cfg.Region + "-01"
	}
	if cfg.PublicBaseURL == "" {
		cfg.PublicBaseURL = "https://gateway.example.com"
	}
	if len(cfg.SupportedTransports) == 0 {
		cfg.SupportedTransports = []string{"webtransport", "webrtc", "websocket"}
	}
	if cfg.PreferredTransport == "" {
		cfg.PreferredTransport = cfg.SupportedTransports[0]
	}
	if cfg.PublicWsURL == "" {
		cfg.PublicWsURL = deriveWSURL(cfg.PublicBaseURL)
	}
	if cfg.WorkerBaseURL == "" {
		cfg.WorkerBaseURL = cfg.PublicBaseURL
	}
	if cfg.WorkerWsURL == "" {
		cfg.WorkerWsURL = cfg.PublicWsURL
	}
	if cfg.RelayMode == "" {
		cfg.RelayMode = relayModeGatewayMediaRelay
	}
	if cfg.RelayMode == relayModeGatewayMediaRelay {
		cfg.EnableMediaRelay = true
	}
	if cfg.PendingSessionActiveTTL <= 0 {
		cfg.PendingSessionActiveTTL = defaultPendingSessionActiveTTL
	}
	if cfg.SessionStoreTTL <= 0 {
		cfg.SessionStoreTTL = defaultGatewaySessionStoreTTL
	}
	if cfg.ForwardRequestTimeout <= 0 {
		cfg.ForwardRequestTimeout = defaultGatewayForwardTimeout
	}
	if cfg.RedisKeyPrefix == "" {
		cfg.RedisKeyPrefix = "cloudsec-rbi"
	}
	if cfg.StateBackend == "" {
		if cfg.RedisURL != "" {
			cfg.StateBackend = "redis"
		} else {
			cfg.StateBackend = "memory"
		}
	}
	if cfg.InstanceID == "" {
		cfg.InstanceID = "media-gateway-" + newOpaqueID("")
	}
	if cfg.InstanceBaseURL == "" {
		cfg.InstanceBaseURL = defaultGatewayInstanceBaseURL()
	}

	instance := gatewayInstance{
		ID:      cfg.InstanceID,
		BaseURL: strings.TrimRight(cfg.InstanceBaseURL, "/"),
	}
	var sessionStore gatewaySessionStore
	if strings.EqualFold(cfg.StateBackend, "redis") && cfg.RedisURL != "" {
		sessionStore = newRedisGatewaySessionStore(cfg.RedisURL, cfg.RedisTLS, cfg.RedisKeyPrefix, cfg.SessionStoreTTL)
	}

	return &Service{
		cfg:             cfg,
		runtimeNotifier: newRuntimeSessionNotifier(cfg),
		sessionStore:    sessionStore,
		instance:        instance,
		sessions:        make(map[string]SessionRecord),
		signals:         make(map[string]*signalSessionState),
		mediaRelays:     make(map[string]*mediaSessionState),
		webrtcRelays:    make(map[string]*pionRelaySession),
		codecRejects:    newWebRTCCodecRejectSummary(),
		admission:       newAdmissionState(),
	}
}

func (s *Service) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/v1/summary", s.handleSummary)
	mux.HandleFunc("/v1/sessions", s.handleCreateSession)
	mux.HandleFunc("/v1/sessions/", s.handleSessionRoute)
	mux.HandleFunc("/gateway/viewer/", s.handleGatewayViewer)
	mux.HandleFunc("/gateway/signaling/", s.handleSignaling)
	mux.HandleFunc("/ws/gateway/signaling/", s.handleSignaling)
	mux.HandleFunc("/gateway/media/", s.handleMediaRelay)
	mux.HandleFunc("/gateway/webrtc/", s.handleWebRTCRelay)
	mux.HandleFunc("/viewer", s.handleViewerProxy)
	mux.HandleFunc("/viewer/", s.handleViewerProxy)
	mux.HandleFunc("/viewer.html", s.handleViewerProxy)
	mux.HandleFunc("/viewer.js", s.handleViewerProxy)
	mux.HandleFunc("/viewer.css", s.handleViewerProxy)
	mux.HandleFunc("/shared/", s.handleViewerProxy)
	mux.HandleFunc("/api/sessions/", s.handleViewerProxy)
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
		"region":  s.cfg.Region,
		"id":      s.cfg.GatewayID,
	})
}

func (s *Service) handleCreateSession(w http.ResponseWriter, r *http.Request) {
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

	var req contracts.MediaGatewaySessionRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, serviceName, "invalid gateway session request")
		return
	}

	resp, status, err := s.CreateSession(req)
	if err != nil {
		var apiErr *apiError
		if errors.As(err, &apiErr) {
			httpx.WriteError(w, apiErr.status, serviceName, apiErr.message)
			return
		}
		httpx.WriteError(w, http.StatusInternalServerError, serviceName, "gateway session creation failed")
		return
	}

	httpx.WriteJSON(w, status, resp)
}

func (s *Service) handleSummary(w http.ResponseWriter, r *http.Request) {
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

	httpx.WriteJSON(w, http.StatusOK, s.buildSummary())
}

func (s *Service) handleSessionRoute(w http.ResponseWriter, r *http.Request) {
	sessionPath := strings.TrimPrefix(r.URL.Path, "/v1/sessions/")
	if sessionPath == "" {
		httpx.WriteError(w, http.StatusNotFound, serviceName, "session not found")
		return
	}
	if strings.HasSuffix(sessionPath, "/terminate") {
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
		sessionID := strings.TrimSuffix(strings.TrimSuffix(sessionPath, "/terminate"), "/")
		if sessionID == "" || strings.Contains(sessionID, "/") {
			httpx.WriteError(w, http.StatusNotFound, serviceName, "session not found")
			return
		}
		s.handleTerminateSession(w, r, sessionID)
		return
	}
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
	if strings.Contains(sessionPath, "/") {
		httpx.WriteError(w, http.StatusNotFound, serviceName, "session not found")
		return
	}

	record, ok := s.GetSession(sessionPath)
	if !ok {
		httpx.WriteError(w, http.StatusNotFound, serviceName, "session not found")
		return
	}

	httpx.WriteJSON(w, http.StatusOK, record)
}

func (s *Service) handleGatewayViewer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		httpx.MethodNotAllowed(w, serviceName, http.MethodGet)
		return
	}

	sessionID := strings.TrimPrefix(r.URL.Path, "/gateway/viewer/")
	if sessionID == "" || strings.Contains(sessionID, "/") {
		httpx.WriteError(w, http.StatusNotFound, serviceName, "session not found")
		return
	}

	record, ok := s.GetSession(sessionID)
	if !ok {
		httpx.WriteError(w, http.StatusNotFound, serviceName, "session not found")
		return
	}

	entryToken := strings.TrimSpace(r.URL.Query().Get("entryToken"))
	if entryToken == "" || entryToken != record.ViewerEntryToken {
		httpx.WriteError(w, http.StatusUnauthorized, serviceName, "invalid viewer entry token")
		return
	}

	for key, values := range buildViewerCookieHeaders(record) {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.Header().Set("Location", "/viewer?sessionId="+url.QueryEscape(sessionID))
	w.WriteHeader(http.StatusSeeOther)
}

func (s *Service) handleViewerProxy(w http.ResponseWriter, r *http.Request) {
	proxy, err := s.runtimeViewerProxy()
	if err != nil {
		var apiErr *apiError
		if errors.As(err, &apiErr) {
			httpx.WriteError(w, apiErr.status, serviceName, apiErr.message)
			return
		}
		httpx.WriteError(w, http.StatusBadGateway, serviceName, "viewer proxy unavailable")
		return
	}
	proxy.ServeHTTP(w, r)
}

func (s *Service) GetSession(sessionID string) (SessionRecord, bool) {
	s.mu.RLock()
	record, ok := s.sessions[sessionID]
	if ok {
		record.SignalState = s.snapshotSignalStateLocked(sessionID)
		record.MediaRelayState = s.snapshotMediaRelayStateLocked(sessionID)
		record.WebRTCRelayState = s.snapshotWebRTCRelayStateLocked(sessionID)
	}
	s.mu.RUnlock()
	if ok {
		return record, true
	}
	record, _, ok = s.getStoredSession(context.Background(), sessionID)
	return record, ok
}

func (s *Service) buildSummary() SummaryResponse {
	s.mu.RLock()
	defer s.mu.RUnlock()

	_, activeByTenant, activeByWorker := s.activeSessionUsageLocked()
	summary := SummaryResponse{
		Region:                   s.cfg.Region,
		GatewayID:                s.cfg.GatewayID,
		SessionsTotal:            len(s.sessions),
		ActiveSessionsByTenant:   activeByTenant,
		ActiveSessionsByWorker:   activeByWorker,
		SignalSessions:           len(s.signals),
		MediaRelaySessions:       len(s.mediaRelays),
		WebRTCRTCPFeedbackByType: map[string]int64{},
		WebRTCTerminationReasons: map[string]int{},
		WebRTCCodecRejects:       cloneWebRTCCodecRejectSummary(s.codecRejects),
		Transports:               map[string]int{},
		MediaTermination: MediaTerminationSummary{
			DefaultCapability: s.mediaTerminationCapabilityForRelayMode(s.cfg.RelayMode),
			SessionsByMode:    map[string]int{},
			RelayModeAcceptance: RelayModeAcceptanceSummary{
				AcceptedMode:                   s.cfg.RelayMode,
				AcceptanceState:                relayModeAcceptanceStateNoSessions,
				RejectedUnsupportedRelayMode:   s.admission.RejectionsByReason["unsupported-relay-mode"],
				RejectedDirectWorkerExposure:   s.admission.RejectionsByReason["direct-worker-public-endpoint"],
				DirectWorkerExposureAllowed:    false,
				Wave2MediaTerminationState:     s.mediaTerminationCapabilityForRelayMode(s.cfg.RelayMode).ImplementationStatus,
				Wave2MediaTerminationStateNote: s.mediaTerminationCapabilityForRelayMode(s.cfg.RelayMode).ImplementationStatusDetail,
			},
		},
		Admission: s.buildAdmissionSummaryLocked(),
	}
	for sessionID, record := range s.sessions {
		transport := strings.TrimSpace(record.Response.Transport.Preferred)
		if transport == "" {
			transport = "unknown"
		}
		summary.Transports[transport]++
		if s.isSessionActiveLocked(sessionID) {
			summary.ActiveSessions++
		}

		mediaTermination := defaultMediaTerminationCapability()
		if record.Response.Transport.MediaTermination != nil {
			mediaTermination = *record.Response.Transport.MediaTermination
		}
		mode := strings.TrimSpace(mediaTermination.Mode)
		if mode == "" {
			mode = "unknown"
		}
		summary.MediaTermination.SessionsByMode[mode]++
		if mediaTermination.GatewayTerminatesMedia {
			summary.MediaTermination.SessionsWithGatewayTerminatedMedia++
		} else {
			summary.MediaTermination.SessionsWithoutGatewayTerminatedMedia++
		}
		if record.Response.WorkerBridge.RelayMode == relayModeGatewayRelay {
			summary.MediaTermination.RelayModeAcceptance.AcceptedSessions++
		}
		if record.Response.WorkerBridge.RelayMode == relayModeGatewayMediaRelay {
			summary.MediaTermination.RelayModeAcceptance.AcceptedSessions++
		}

		signalState := s.snapshotSignalStateLocked(sessionID)
		if signalState != nil {
			if signalState.ViewerConnected {
				summary.ViewerConnected++
			}
			if signalState.WorkerConnected {
				summary.WorkerConnected++
			}
			if signalState.Terminated {
				summary.TerminatedSignals++
			}
			summary.PendingViewerSignals += signalState.PendingViewerSignals
			summary.PendingWorkerSignals += signalState.PendingWorkerSignals
			summary.ViewerConnectEvents += signalState.ViewerConnectEvents
			summary.WorkerConnectEvents += signalState.WorkerConnectEvents
			summary.ViewerDisconnectEvents += signalState.ViewerDisconnectEvents
			summary.WorkerDisconnectEvents += signalState.WorkerDisconnectEvents
			summary.ViewerHeartbeats += signalState.ViewerHeartbeats
			summary.ViewerSignalMessages += signalState.ViewerSignalMessages
			summary.WorkerStateUpdates += signalState.WorkerStateUpdates
			summary.SignalsToViewer += signalState.SignalsToViewer
			summary.SignalsToWorker += signalState.SignalsToWorker
		}

		mediaState := s.snapshotMediaRelayStateLocked(sessionID)
		if mediaState != nil {
			if mediaState.ViewerConnected {
				summary.MediaViewerConnected++
			}
			if mediaState.WorkerConnected {
				summary.MediaWorkerConnected++
			}
			summary.MediaPendingViewerFrames += mediaState.PendingViewerFrames
			summary.MediaPendingWorkerFrames += mediaState.PendingWorkerFrames
			if mediaState.MaxPendingViewerFrames > summary.MediaMaxPendingViewerFrames {
				summary.MediaMaxPendingViewerFrames = mediaState.MaxPendingViewerFrames
			}
			if mediaState.MaxPendingWorkerFrames > summary.MediaMaxPendingWorkerFrames {
				summary.MediaMaxPendingWorkerFrames = mediaState.MaxPendingWorkerFrames
			}
			summary.MediaDroppedViewerFrames += mediaState.DroppedViewerFrames
			summary.MediaDroppedWorkerFrames += mediaState.DroppedWorkerFrames
			summary.MediaFramesToViewer += mediaState.FramesToViewer
			summary.MediaFramesToWorker += mediaState.FramesToWorker
			summary.MediaBytesToViewer += mediaState.BytesToViewer
			summary.MediaBytesToWorker += mediaState.BytesToWorker
		}

		webrtcState := s.snapshotWebRTCRelayStateLocked(sessionID)
		if webrtcState != nil {
			summary.WebRTCRelaySessions++
			if webrtcState.Terminated {
				summary.WebRTCTerminatedRelays++
				reason := strings.TrimSpace(webrtcState.TerminationReason)
				if reason == "" {
					reason = "unspecified"
				}
				summary.WebRTCTerminationReasons[reason]++
				summary.WebRTCLastTerminationReason = reason
			} else {
				summary.WebRTCActiveRelaySessions++
			}
			if strings.EqualFold(webrtcState.WorkerPeerState, "connected") {
				summary.WebRTCWorkerConnected++
			}
			if strings.EqualFold(webrtcState.ViewerPeerState, "connected") {
				summary.WebRTCViewerConnected++
			}
			summary.WebRTCRTPPacketsToViewer += webrtcState.RTPPacketsToViewer
			summary.WebRTCRTPBytesToViewer += webrtcState.RTPBytesToViewer
			summary.WebRTCRTCPPacketsToWorker += webrtcState.RTCPPacketsToWorker
			for feedbackType, count := range webrtcState.RTCPFeedbackByType {
				summary.WebRTCRTCPFeedbackByType[feedbackType] += count
			}
			summary.WebRTCDataMessagesToWorker += webrtcState.DataMessagesToWorker
			summary.WebRTCDataMessagesToViewer += webrtcState.DataMessagesToViewer
			summary.WebRTCPointerDrops += webrtcState.PointerDroppedMessages
			summary.WebRTCControlDrops += webrtcState.ControlDroppedMessages
			summary.WebRTCPendingPointer += webrtcState.PendingPointerMessages
			summary.WebRTCPendingControl += webrtcState.PendingControlMessages
		}
	}
	summary.MediaTermination.Wave2AcceptanceComplete = len(s.sessions) > 0 &&
		summary.MediaTermination.SessionsWithoutGatewayTerminatedMedia == 0 &&
		summary.MediaTermination.SessionsWithGatewayTerminatedMedia == len(s.sessions)
	summary.MediaTermination.RelayModeAcceptance.AcceptanceState = relayModeAcceptanceState(summary.MediaTermination.RelayModeAcceptance, len(s.sessions))
	return summary
}

func (s *Service) snapshotWebRTCRelayStateLocked(sessionID string) *WebRTCRelayStateSnapshot {
	state := s.webrtcRelays[sessionID]
	if state == nil {
		return nil
	}
	return state.snapshot()
}

func (s *Service) snapshotSignalStateLocked(sessionID string) *SignalStateSnapshot {
	state := s.signals[sessionID]
	if state == nil {
		return nil
	}
	return &SignalStateSnapshot{
		ViewerConnected:        state.viewer != nil,
		WorkerConnected:        state.worker != nil,
		PendingViewerSignals:   len(state.pendingViewer),
		PendingWorkerSignals:   len(state.pendingWorker),
		ViewerConnectEvents:    state.viewerConnectEvents,
		WorkerConnectEvents:    state.workerConnectEvents,
		ViewerDisconnectEvents: state.viewerDisconnectEvents,
		WorkerDisconnectEvents: state.workerDisconnectEvents,
		ViewerHeartbeats:       state.viewerHeartbeats,
		ViewerSignalMessages:   state.viewerSignalMessages,
		WorkerStateUpdates:     state.workerStateUpdates,
		SignalsToViewer:        state.signalsToViewer,
		SignalsToWorker:        state.signalsToWorker,
		LastViewerSeenAt:       cloneTimePointer(state.lastViewerSeenAt),
		LastWorkerState:        state.lastWorkerState,
		LastWorkerStateAt:      cloneTimePointer(state.lastWorkerStateAt),
		LastSignalForwardedAt:  cloneTimePointer(state.lastSignalForwardedAt),
		Terminated:             state.terminated,
		TerminatedAt:           cloneTimePointer(state.terminatedAt),
		TerminationReason:      state.terminationReason,
	}
}

func (s *Service) runtimeViewerProxy() (*httputil.ReverseProxy, error) {
	baseURL := strings.TrimSpace(s.cfg.RuntimeNotifyBaseURL)
	if baseURL == "" {
		return nil, &apiError{status: http.StatusServiceUnavailable, message: "runtime viewer proxy is not configured"}
	}

	target, err := url.Parse(baseURL)
	if err != nil {
		return nil, &apiError{status: http.StatusBadGateway, message: "runtime viewer proxy base URL is invalid"}
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.URL.Path = joinURLPath(target.Path, req.URL.Path)
		req.Host = target.Host
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) {
		httpx.WriteError(w, http.StatusBadGateway, serviceName, "runtime viewer proxy failed: "+err.Error())
	}
	return proxy, nil
}

func (s *Service) CreateSession(req contracts.MediaGatewaySessionRequest) (contracts.MediaGatewaySessionResponse, int, error) {
	normalizedReq, err := s.validateRequest(req)
	if err != nil {
		var apiErr *apiError
		if errors.As(err, &apiErr) {
			s.mu.Lock()
			s.recordAdmissionDecisionLocked(s.admissionDecisionFromErrorLocked(req, apiErr))
			s.mu.Unlock()
		}
		return contracts.MediaGatewaySessionResponse{}, 0, err
	}

	if record, _, ok := s.getStoredSession(context.Background(), normalizedReq.SessionID); ok {
		if !requestsEquivalentForReplay(record.Request, normalizedReq) {
			conflict := &apiError{status: http.StatusConflict, message: "sessionId replay does not match existing gateway session"}
			s.mu.Lock()
			s.recordAdmissionDecisionLocked(s.admissionDecisionFromErrorLocked(normalizedReq, conflict))
			s.mu.Unlock()
			return contracts.MediaGatewaySessionResponse{}, 0, conflict
		}
		s.mu.Lock()
		s.recordAdmissionDecisionLocked(AdmissionDecision{
			SessionID:        normalizedReq.SessionID,
			TenantID:         normalizedReq.TenantID,
			WorkerID:         normalizedReq.WorkerAssignment.WorkerID,
			Admitted:         true,
			IdempotentReplay: true,
			StatusCode:       http.StatusOK,
			Reason:           "shared-store idempotent session replay",
			ReasonCode:       "idempotent-replay",
			EvaluatedAt:      time.Now().UTC(),
			Quotas:           s.quotaConfig(),
			Usage:            s.admissionUsageForRequestLocked(normalizedReq),
		})
		s.mu.Unlock()
		return record.Response, http.StatusOK, nil
	}

	s.mu.Lock()

	if record, ok := s.sessions[normalizedReq.SessionID]; ok {
		if !requestsEquivalentForReplay(record.Request, normalizedReq) {
			conflict := &apiError{status: http.StatusConflict, message: "sessionId replay does not match existing gateway session"}
			s.recordAdmissionDecisionLocked(s.admissionDecisionFromErrorLocked(normalizedReq, conflict))
			s.mu.Unlock()
			return contracts.MediaGatewaySessionResponse{}, 0, conflict
		}
		s.recordAdmissionDecisionLocked(AdmissionDecision{
			SessionID:        normalizedReq.SessionID,
			TenantID:         normalizedReq.TenantID,
			WorkerID:         normalizedReq.WorkerAssignment.WorkerID,
			Admitted:         true,
			IdempotentReplay: true,
			StatusCode:       http.StatusOK,
			Reason:           "idempotent session replay",
			ReasonCode:       "idempotent-replay",
			EvaluatedAt:      time.Now().UTC(),
			Quotas:           s.quotaConfig(),
			Usage:            s.admissionUsageForRequestLocked(normalizedReq),
		})
		s.mu.Unlock()
		return record.Response, http.StatusOK, nil
	}

	admissionDecision, err := s.evaluateAdmissionLocked(normalizedReq)
	if err != nil {
		s.recordAdmissionDecisionLocked(admissionDecision)
		s.mu.Unlock()
		return contracts.MediaGatewaySessionResponse{}, 0, err
	}

	resp, viewerEntryToken := s.buildResponse(normalizedReq)
	record := SessionRecord{
		Request:          normalizedReq,
		Response:         resp,
		Admission:        &admissionDecision,
		ViewerEntryToken: viewerEntryToken,
		CreatedAt:        time.Now().UTC(),
	}
	s.sessions[normalizedReq.SessionID] = record
	s.recordAdmissionDecisionLocked(admissionDecision)
	s.mu.Unlock()

	if err := s.storeSession(context.Background(), record); err != nil {
		s.mu.Lock()
		delete(s.sessions, normalizedReq.SessionID)
		s.mu.Unlock()
		return contracts.MediaGatewaySessionResponse{}, 0, &apiError{status: http.StatusBadGateway, message: "gateway session store unavailable"}
	}

	return resp, http.StatusCreated, nil
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

func (s *Service) validateRequest(req contracts.MediaGatewaySessionRequest) (contracts.MediaGatewaySessionRequest, error) {
	req.SessionID = strings.TrimSpace(req.SessionID)
	req.TenantID = strings.TrimSpace(req.TenantID)
	req.ProfileID = strings.TrimSpace(req.ProfileID)
	req.TargetURL = strings.TrimSpace(req.TargetURL)
	req.ViewerEntryMode = strings.TrimSpace(req.ViewerEntryMode)
	req.PreferredTransport = strings.TrimSpace(req.PreferredTransport)
	req.ViewerToken = strings.TrimSpace(req.ViewerToken)
	req.WorkerToken = strings.TrimSpace(req.WorkerToken)
	req.PublicBaseURL = strings.TrimSpace(req.PublicBaseURL)
	req.PublicWsURL = strings.TrimSpace(req.PublicWsURL)
	req.GatewayAssignment.SessionID = strings.TrimSpace(req.GatewayAssignment.SessionID)
	req.GatewayAssignment.GatewayID = strings.TrimSpace(req.GatewayAssignment.GatewayID)
	req.GatewayAssignment.Region = strings.TrimSpace(req.GatewayAssignment.Region)
	req.GatewayAssignment.WorkerID = strings.TrimSpace(req.GatewayAssignment.WorkerID)
	req.GatewayAssignment.RelayMode = strings.TrimSpace(req.GatewayAssignment.RelayMode)
	req.GatewayAssignment.PublicBaseURL = strings.TrimSpace(req.GatewayAssignment.PublicBaseURL)
	req.GatewayAssignment.PublicWsURL = strings.TrimSpace(req.GatewayAssignment.PublicWsURL)
	req.WorkerAssignment.SessionID = strings.TrimSpace(req.WorkerAssignment.SessionID)
	req.WorkerAssignment.WorkerID = strings.TrimSpace(req.WorkerAssignment.WorkerID)
	req.WorkerAssignment.Region = strings.TrimSpace(req.WorkerAssignment.Region)

	switch {
	case req.SessionID == "":
		return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "sessionId is required"}
	case req.TenantID == "":
		return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "tenantId is required"}
	case req.ViewerToken == "":
		return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "viewerToken is required"}
	case req.WorkerToken == "":
		return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "workerToken is required"}
	case req.WorkerAssignment.WorkerID == "":
		return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "workerAssignment.workerId is required"}
	}
	if req.Generation <= 0 {
		req.Generation = 1
	}

	if req.TargetURL != "" {
		targetURL, err := url.Parse(req.TargetURL)
		if err != nil || !targetURL.IsAbs() || (targetURL.Scheme != "http" && targetURL.Scheme != "https") {
			return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "targetUrl must be an absolute http or https URL"}
		}
	}

	if req.GatewayAssignment.SessionID == "" {
		req.GatewayAssignment.SessionID = req.SessionID
	}
	if req.WorkerAssignment.SessionID == "" {
		req.WorkerAssignment.SessionID = req.SessionID
	}
	if req.GatewayAssignment.SessionID != req.SessionID || req.WorkerAssignment.SessionID != req.SessionID {
		return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "assignment session ids must match sessionId"}
	}

	if req.GatewayAssignment.Region == "" {
		req.GatewayAssignment.Region = s.cfg.Region
	}
	if req.GatewayAssignment.Region != s.cfg.Region {
		return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusConflict, message: "gateway assignment region does not match this gateway"}
	}

	if req.WorkerAssignment.Region == "" {
		req.WorkerAssignment.Region = req.GatewayAssignment.Region
	}

	if req.GatewayAssignment.GatewayID == "" {
		req.GatewayAssignment.GatewayID = s.cfg.GatewayID
	}
	if req.GatewayAssignment.GatewayID != s.cfg.GatewayID {
		return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusConflict, message: "gateway assignment targets a different gateway"}
	}

	if req.GatewayAssignment.WorkerID == "" {
		req.GatewayAssignment.WorkerID = req.WorkerAssignment.WorkerID
	}
	if req.GatewayAssignment.WorkerID != req.WorkerAssignment.WorkerID {
		return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "gatewayAssignment.workerId must match workerAssignment.workerId"}
	}
	if req.GatewayAssignment.RelayMode != "" && !s.isSupportedRelayMode(req.GatewayAssignment.RelayMode) {
		return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "relayMode must be gateway-relay, or gateway-media-relay when MEDIA_GATEWAY_ENABLE_MEDIA_RELAY=true"}
	}

	if req.PublicBaseURL != "" {
		if _, err := parseAbsolutePublicURL(req.PublicBaseURL, "publicBaseUrl", "http", "https"); err != nil {
			return contracts.MediaGatewaySessionRequest{}, err
		}
		if publicEndpointExposesWorker(req.PublicBaseURL, req.WorkerAssignment.WorkerID) {
			return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "direct worker public endpoint exposure is not allowed"}
		}
	}
	if req.GatewayAssignment.PublicBaseURL != "" {
		if _, err := parseAbsolutePublicURL(req.GatewayAssignment.PublicBaseURL, "gatewayAssignment.publicBaseUrl", "http", "https"); err != nil {
			return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "publicBaseUrl must be an absolute URL"}
		}
		if publicEndpointExposesWorker(req.GatewayAssignment.PublicBaseURL, req.WorkerAssignment.WorkerID) {
			return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "direct worker public endpoint exposure is not allowed"}
		}
	}
	if req.PublicWsURL != "" {
		if _, err := parseAbsolutePublicURL(req.PublicWsURL, "publicWsUrl", "ws", "wss"); err != nil {
			return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "publicWsUrl must be an absolute ws or wss URL"}
		}
		if publicEndpointExposesWorker(req.PublicWsURL, req.WorkerAssignment.WorkerID) {
			return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "direct worker public endpoint exposure is not allowed"}
		}
	}
	if req.GatewayAssignment.PublicWsURL != "" {
		if _, err := parseAbsolutePublicURL(req.GatewayAssignment.PublicWsURL, "gatewayAssignment.publicWsUrl", "ws", "wss"); err != nil {
			return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "publicWsUrl must be an absolute ws or wss URL"}
		}
		if publicEndpointExposesWorker(req.GatewayAssignment.PublicWsURL, req.WorkerAssignment.WorkerID) {
			return contracts.MediaGatewaySessionRequest{}, &apiError{status: http.StatusBadRequest, message: "direct worker public endpoint exposure is not allowed"}
		}
	}

	return req, nil
}

func (s *Service) buildResponse(req contracts.MediaGatewaySessionRequest) (contracts.MediaGatewaySessionResponse, string) {
	publicBaseURL := firstNonEmpty(req.PublicBaseURL, req.GatewayAssignment.PublicBaseURL, s.cfg.PublicBaseURL)
	publicWsURL := firstNonEmpty(req.PublicWsURL, req.GatewayAssignment.PublicWsURL, s.cfg.PublicWsURL, deriveWSURL(publicBaseURL))
	workerBaseURL := firstNonEmpty(s.cfg.WorkerBaseURL, publicBaseURL)
	workerWsURL := firstNonEmpty(s.cfg.WorkerWsURL, publicWsURL)
	preferredTransport := s.selectTransport(req.PreferredTransport)
	relayMode := firstNonEmpty(req.GatewayAssignment.RelayMode, s.cfg.RelayMode)
	if !s.isSupportedRelayMode(relayMode) {
		relayMode = relayModeGatewayRelay
	}
	viewerEntryToken := newOpaqueID("entry_")
	mediaTermination := s.mediaTerminationCapabilityForRelayMode(relayMode)
	mediaRelayURL := ""
	workerMediaRelayURL := ""
	mediaGatewayURL := ""
	workerMediaGatewayURL := ""
	if relayMode == relayModeGatewayMediaRelay {
		mediaRelayURL = buildMediaRelayURL(publicWsURL, req.SessionID, "viewer", preferredTransport)
		workerMediaRelayURL = buildMediaRelayURL(workerWsURL, req.SessionID, "worker", preferredTransport)
		mediaGatewayURL = buildMediaGatewayURL(publicBaseURL, req.SessionID, "viewer")
		workerMediaGatewayURL = buildMediaGatewayURL(workerBaseURL, req.SessionID, "worker")
	}

	gatewayAssignment := req.GatewayAssignment
	gatewayAssignment.PublicBaseURL = publicBaseURL
	gatewayAssignment.PublicWsURL = publicWsURL
	gatewayAssignment.RelayMode = relayMode

	return contracts.MediaGatewaySessionResponse{
		SessionID:         req.SessionID,
		ViewerEntryMode:   firstNonEmpty(req.ViewerEntryMode, "swg-handoff"),
		GatewayAssignment: gatewayAssignment,
		WorkerAssignment:  req.WorkerAssignment,
		Transport: contracts.GatewayTransport{
			Preferred:        preferredTransport,
			Supported:        append([]string(nil), s.cfg.SupportedTransports...),
			ViewerURL:        buildViewerURL(publicBaseURL, req.SessionID, preferredTransport, viewerEntryToken),
			SignalingURL:     buildSignalingURL(publicWsURL, req.SessionID, preferredTransport),
			MediaRelayURL:    mediaRelayURL,
			MediaGatewayURL:  mediaGatewayURL,
			MediaPlaneMode:   mediaPlaneModeForRelayMode(relayMode),
			Protocol:         protocolForRelayMode(relayMode),
			InputPointerName: inputPointerChannelName,
			InputControlName: inputControlChannelName,
			MediaTermination: ptrMediaTerminationCapability(mediaTermination),
		},
		WorkerBridge: contracts.WorkerBridge{
			BridgeID:         newOpaqueID("bridge_"),
			RelayMode:        relayMode,
			MediaRelayURL:    workerMediaRelayURL,
			MediaGatewayURL:  workerMediaGatewayURL,
			MediaDirection:   mediaDirectionForRelayMode(relayMode),
			Protocol:         protocolForRelayMode(relayMode),
			InputPointerName: inputPointerChannelName,
			InputControlName: inputControlChannelName,
		},
	}, viewerEntryToken
}

func (s *Service) selectTransport(requested string) string {
	requested = strings.TrimSpace(requested)
	if requested != "" && containsString(s.cfg.SupportedTransports, requested) {
		return requested
	}
	if containsString(s.cfg.SupportedTransports, s.cfg.PreferredTransport) {
		return s.cfg.PreferredTransport
	}
	return s.cfg.SupportedTransports[0]
}

func (s *Service) isSupportedRelayMode(relayMode string) bool {
	switch strings.TrimSpace(relayMode) {
	case relayModeGatewayRelay:
		return true
	case relayModeGatewayMediaRelay:
		return s.cfg.EnableMediaRelay
	default:
		return false
	}
}

func relayModeAcceptanceState(summary RelayModeAcceptanceSummary, sessionsTotal int) string {
	if sessionsTotal == 0 {
		if summary.RejectedUnsupportedRelayMode > 0 || summary.RejectedDirectWorkerExposure > 0 {
			return relayModeAcceptanceStateRejected
		}
		return relayModeAcceptanceStateNoSessions
	}
	if summary.AcceptedSessions == sessionsTotal {
		return relayModeAcceptanceStateAccepted
	}
	return relayModeAcceptanceStatePartial
}

func defaultMediaTerminationCapability() contracts.MediaTerminationCapability {
	return contracts.MediaTerminationCapability{
		Mode:                        mediaTerminationModeSignalingRelay,
		MediaPlaneMode:              "direct-webrtc",
		Protocol:                    "webrtc",
		RelayMode:                   relayModeGatewayRelay,
		RelayModeAcceptanceState:    relayModeAcceptanceStateAccepted,
		GatewayTerminatesSignaling:  true,
		GatewayTerminatesMedia:      false,
		WorkerAddressExposure:       workerAddressExposureGatewayOnly,
		DirectWorkerExposureAllowed: false,
		Wave2AcceptanceComplete:     false,
		ImplementationStatus:        mediaTerminationStatusIncomplete,
		ImplementationStatusDetail:  "gateway owns viewer entry and signaling relay mode; full SFU media termination is still incomplete",
	}
}

func (s *Service) mediaTerminationCapabilityForRelayMode(relayMode string) contracts.MediaTerminationCapability {
	if relayMode != relayModeGatewayMediaRelay {
		return defaultMediaTerminationCapability()
	}
	return contracts.MediaTerminationCapability{
		Mode:                        mediaTerminationModeGatewayRelay,
		MediaPlaneMode:              mediaPlaneModeGatewayWebRTCRelay,
		Protocol:                    mediaTerminationProtocolWebRTCSRTP,
		RelayMode:                   relayModeGatewayMediaRelay,
		RelayModeAcceptanceState:    relayModeAcceptanceStateAccepted,
		GatewayTerminatesSignaling:  true,
		GatewayTerminatesMedia:      true,
		WorkerAddressExposure:       workerAddressExposureGatewayOnly,
		DirectWorkerExposureAllowed: false,
		Wave2AcceptanceComplete:     true,
		ImplementationStatus:        mediaTerminationStatusImplemented,
		ImplementationStatusDetail:  "gateway exposes role-bound WebRTC/SRTP media endpoints and keeps the legacy websocket relay only as rollback/control canary",
	}
}

func mediaPlaneModeForRelayMode(relayMode string) string {
	if relayMode == relayModeGatewayMediaRelay {
		return mediaPlaneModeGatewayWebRTCRelay
	}
	return "direct-webrtc"
}

func protocolForRelayMode(relayMode string) string {
	if relayMode == relayModeGatewayMediaRelay {
		return mediaTerminationProtocolWebRTCSRTP
	}
	return "webrtc"
}

func mediaDirectionForRelayMode(relayMode string) string {
	if relayMode == relayModeGatewayMediaRelay {
		return "worker-to-gateway"
	}
	return "worker-to-viewer"
}

func ptrMediaTerminationCapability(value contracts.MediaTerminationCapability) *contracts.MediaTerminationCapability {
	copied := value
	return &copied
}

func parseAbsolutePublicURL(raw string, field string, allowedSchemes ...string) (*url.URL, error) {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return nil, &apiError{status: http.StatusBadRequest, message: field + " must be an absolute URL"}
	}
	if !containsString(allowedSchemes, parsed.Scheme) {
		return nil, &apiError{status: http.StatusBadRequest, message: field + " has an unsupported URL scheme"}
	}
	return parsed, nil
}

func publicEndpointExposesWorker(raw string, workerID string) bool {
	parsed, err := url.Parse(raw)
	if err != nil {
		return false
	}

	host := strings.ToLower(parsed.Hostname())
	if host == "" {
		return false
	}

	workerID = strings.ToLower(strings.TrimSpace(workerID))
	endpointIdentity := host + " " + strings.ToLower(parsed.EscapedPath())
	if workerID != "" && strings.Contains(endpointIdentity, workerID) {
		return true
	}

	return net.ParseIP(host) != nil
}

func viewerCookieName(sessionID string) string {
	return "rbi_viewer_" + sessionID
}

func buildCookie(name, value string, secure bool, maxAge int) string {
	parts := []string{name + "=" + url.QueryEscape(value), "Path=/", "HttpOnly"}
	if maxAge >= 0 {
		parts = append(parts, "Max-Age="+strconv.Itoa(maxAge))
	}
	parts = append(parts, "SameSite=Lax")
	if secure {
		parts = append(parts, "Secure")
	}
	return strings.Join(parts, "; ")
}

func buildViewerCookieHeaders(record SessionRecord) map[string][]string {
	maxAge := 3 * 60 * 60
	secure := strings.HasPrefix(record.Response.GatewayAssignment.PublicBaseURL, "https://")
	return map[string][]string{
		"Set-Cookie": {
			buildCookie(viewerCookieName(record.Request.SessionID), record.Request.ViewerToken, secure, maxAge),
			buildCookie("rbi_active_viewer_session", record.Request.SessionID, secure, maxAge),
		},
	}
}

func buildViewerURL(baseURL, sessionID, transport, viewerEntryToken string) string {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return baseURL
	}

	parsed.Path = joinURLPath(parsed.Path, "/gateway/viewer/"+sessionID)
	query := parsed.Query()
	query.Set("transport", transport)
	if viewerEntryToken != "" {
		query.Set("entryToken", viewerEntryToken)
	}
	parsed.RawQuery = query.Encode()
	return parsed.String()
}

func buildSignalingURL(baseURL, sessionID, transport string) string {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return baseURL
	}

	parsed.Path = gatewayWebSocketPath(parsed.Path, "/gateway/signaling/"+sessionID+"/viewer")
	query := parsed.Query()
	query.Set("transport", transport)
	parsed.RawQuery = query.Encode()
	return parsed.String()
}

func gatewayWebSocketPath(basePath, gatewayPath string) string {
	cleaned := strings.TrimRight(strings.TrimSpace(basePath), "/")
	if cleaned == "" || cleaned == "/ws" {
		return gatewayPath
	}
	return joinURLPath(cleaned, gatewayPath)
}

func buildMediaRelayURL(baseURL, sessionID, role, transport string) string {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return baseURL
	}

	parsed.Path = joinURLPath(parsed.Path, "/gateway/media/"+sessionID+"/"+role)
	query := parsed.Query()
	query.Set("transport", transport)
	parsed.RawQuery = query.Encode()
	return parsed.String()
}

func buildMediaGatewayURL(baseURL, sessionID, role string) string {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return baseURL
	}

	parsed.Path = joinURLPath(parsed.Path, "/gateway/webrtc/"+sessionID+"/"+role)
	parsed.RawQuery = ""
	return parsed.String()
}

func newOpaqueID(prefix string) string {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return prefix + strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	return prefix + hex.EncodeToString(buf)
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

func parseCSVOrDefault(raw string, fallback []string) []string {
	items := parseCSV(raw)
	if len(items) == 0 {
		return fallback
	}
	return items
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

func parseNonNegativeInt(raw string, fallback int) int {
	if raw == "" {
		return fallback
	}

	value, err := strconv.Atoi(raw)
	if err != nil || value < 0 {
		return fallback
	}
	return value
}

func parseBool(raw string, fallback bool) bool {
	value := strings.TrimSpace(strings.ToLower(raw))
	if value == "" {
		return fallback
	}
	return value == "1" || value == "true" || value == "yes" || value == "on"
}

func getenvDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func cloneTimePointer(value time.Time) *time.Time {
	if value.IsZero() {
		return nil
	}
	copied := value
	return &copied
}
