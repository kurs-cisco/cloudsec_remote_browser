package filebroker

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	"cloudsec_remote_browser/services/internal/contracts"
	"cloudsec_remote_browser/services/internal/httpx"
)

const FileBroker = "file-broker"

type Config struct {
	MaxFileBytes      int64
	AllowedDirections []string
	AllowedMimeTypes  []string
	TTLSeconds        int
	FallbackProvider  string
}

type Service struct {
	cfg     Config
	mu      sync.Mutex
	summary contracts.BrokerSummary
}

func NewService(cfg Config) *Service {
	if cfg.MaxFileBytes <= 0 {
		cfg.MaxFileBytes = 25 * 1024 * 1024
	}
	if len(cfg.AllowedDirections) == 0 {
		cfg.AllowedDirections = []string{"download", "upload"}
	}
	if len(cfg.AllowedMimeTypes) == 0 {
		cfg.AllowedMimeTypes = []string{
			"application/octet-stream",
			"application/pdf",
			"image/jpeg",
			"image/png",
			"text/plain",
		}
	}
	if cfg.TTLSeconds <= 0 {
		cfg.TTLSeconds = 300
	}
	if strings.TrimSpace(cfg.FallbackProvider) == "" {
		cfg.FallbackProvider = "menlo"
	}
	return &Service{
		cfg: cfg,
		summary: contracts.BrokerSummary{
			Service:         FileBroker,
			DecisionReasons: map[string]int{},
		},
	}
}

func (s *Service) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/v1/files", s.handleFile)
	mux.HandleFunc("/v1/summary", s.handleSummary)
	return mux
}

func (s *Service) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		httpx.MethodNotAllowed(w, FileBroker, http.MethodGet)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"ok": true, "service": FileBroker})
}

func (s *Service) handleSummary(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		httpx.MethodNotAllowed(w, FileBroker, http.MethodGet)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	httpx.WriteJSON(w, http.StatusOK, s.summary)
}

func (s *Service) handleFile(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpx.MethodNotAllowed(w, FileBroker, http.MethodPost)
		return
	}
	var req contracts.FileBrokerRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, FileBroker, "invalid file broker request")
		return
	}
	if strings.TrimSpace(req.SessionID) == "" ||
		strings.TrimSpace(req.TenantID) == "" ||
		strings.TrimSpace(req.Direction) == "" ||
		strings.TrimSpace(req.FileName) == "" {
		httpx.WriteError(w, http.StatusBadRequest, FileBroker, "sessionId, tenantId, direction, and fileName are required")
		return
	}

	resp := s.evaluate(req)
	s.record(resp, req.SizeBytes)
	httpx.WriteJSON(w, http.StatusCreated, resp)
}

func (s *Service) evaluate(req contracts.FileBrokerRequest) contracts.BrokerResponse {
	direction := normalize(req.Direction)
	mimeType := normalize(req.MimeType)
	decision := contracts.BrokerDecisionAllowed
	reason := contracts.BrokerReasonPolicyAllowed
	action := "release"
	fallbackProvider := ""
	releaseRef := "file-release-" + opaqueID()

	switch {
	case !containsNormalized(s.cfg.AllowedDirections, direction):
		decision = contracts.BrokerDecisionUnsupported
		reason = contracts.BrokerReasonUnsupportedDirection
	case req.SizeBytes < 0 || req.SizeBytes > s.cfg.MaxFileBytes:
		decision = contracts.BrokerDecisionBlocked
		reason = contracts.BrokerReasonPayloadTooLarge
	case mimeType != "" && !containsNormalized(s.cfg.AllowedMimeTypes, mimeType):
		decision = contracts.BrokerDecisionBlocked
		reason = contracts.BrokerReasonUnsupportedMimeType
	case hasPolicyLabel(req.PolicyLabels, "block", "blocked", "dlp-block", "malware", "scan-failed"):
		decision = contracts.BrokerDecisionBlocked
		reason = contracts.BrokerReasonPolicyBlocked
	case hasPolicyLabel(req.PolicyLabels, "scan-required", "av-required", "dlp-scan-required", "requires-sandbox", "unknown-reputation"):
		decision = contracts.BrokerDecisionBlocked
		reason = contracts.BrokerReasonScanRequired
	}

	if decision != contracts.BrokerDecisionAllowed {
		action = "fallback-to-menlo"
		fallbackProvider = s.cfg.FallbackProvider
		releaseRef = ""
	}

	return contracts.BrokerResponse{
		ID:               "file-broker-" + opaqueID(),
		Decision:         decision,
		Reason:           reason,
		SessionID:        strings.TrimSpace(req.SessionID),
		TenantID:         strings.TrimSpace(req.TenantID),
		Direction:        direction,
		Action:           action,
		FallbackProvider: fallbackProvider,
		ReleaseRef:       releaseRef,
		AuditID:          "audit-" + opaqueID(),
		TTLSeconds:       s.cfg.TTLSeconds,
	}
}

func (s *Service) record(resp contracts.BrokerResponse, bytes int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.summary.RequestsTotal++
	if bytes > 0 {
		s.summary.BytesTotal += bytes
	}
	switch resp.Decision {
	case contracts.BrokerDecisionAllowed:
		s.summary.Allowed++
	case contracts.BrokerDecisionUnsupported:
		s.summary.Unsupported++
	default:
		s.summary.Blocked++
	}
	s.summary.DecisionReasons[string(resp.Reason)]++
	copied := resp
	s.summary.LastDecision = &copied
}

func normalize(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}

func containsNormalized(values []string, value string) bool {
	return slices.ContainsFunc(values, func(candidate string) bool {
		return normalize(candidate) == value
	})
}

func hasPolicyLabel(labels []string, candidates ...string) bool {
	for _, label := range labels {
		normalized := normalize(label)
		for _, candidate := range candidates {
			if normalized == normalize(candidate) {
				return true
			}
		}
	}
	return false
}

func opaqueID() string {
	var buf [8]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return strings.ReplaceAll(time.Now().UTC().Format("20060102150405.000000000"), ".", "")
	}
	return hex.EncodeToString(buf[:])
}
