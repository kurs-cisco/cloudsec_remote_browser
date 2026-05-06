package mediagateway

import (
	"net/http"
	"reflect"
	"strings"
	"time"

	"cloudsec_remote_browser/services/internal/contracts"
)

const recentAdmissionDecisionsLimit = 20

type AdmissionQuotaConfig struct {
	MaxActiveSessions          int `json:"maxActiveSessions"`
	MaxActiveSessionsPerTenant int `json:"maxActiveSessionsPerTenant"`
	MaxActiveSessionsPerWorker int `json:"maxActiveSessionsPerWorker"`
}

type AdmissionQuotaUsage struct {
	ActiveSessions       int `json:"activeSessions"`
	TenantActiveSessions int `json:"tenantActiveSessions"`
	WorkerActiveSessions int `json:"workerActiveSessions"`
}

type AdmissionDecision struct {
	SessionID        string               `json:"sessionId,omitempty"`
	TenantID         string               `json:"tenantId,omitempty"`
	WorkerID         string               `json:"workerId,omitempty"`
	Admitted         bool                 `json:"admitted"`
	IdempotentReplay bool                 `json:"idempotentReplay,omitempty"`
	StatusCode       int                  `json:"statusCode"`
	Reason           string               `json:"reason,omitempty"`
	ReasonCode       string               `json:"reasonCode,omitempty"`
	EvaluatedAt      time.Time            `json:"evaluatedAt"`
	Quotas           AdmissionQuotaConfig `json:"quotas"`
	Usage            AdmissionQuotaUsage  `json:"usage"`
}

type AdmissionSummary struct {
	Quotas             AdmissionQuotaConfig `json:"quotas"`
	Attempts           int                  `json:"attempts"`
	Accepted           int                  `json:"accepted"`
	Rejected           int                  `json:"rejected"`
	IdempotentReplays  int                  `json:"idempotentReplays"`
	RejectionsByReason map[string]int       `json:"rejectionsByReason"`
	LastDecision       *AdmissionDecision   `json:"lastDecision,omitempty"`
	RecentDecisions    []AdmissionDecision  `json:"recentDecisions,omitempty"`
}

type admissionState struct {
	Attempts           int
	Accepted           int
	Rejected           int
	IdempotentReplays  int
	RejectionsByReason map[string]int
	RecentDecisions    []AdmissionDecision
	LastDecision       *AdmissionDecision
}

func newAdmissionState() admissionState {
	return admissionState{
		RejectionsByReason: map[string]int{},
	}
}

func (s *Service) quotaConfig() AdmissionQuotaConfig {
	return AdmissionQuotaConfig{
		MaxActiveSessions:          s.cfg.MaxActiveSessions,
		MaxActiveSessionsPerTenant: s.cfg.MaxActiveSessionsPerTenant,
		MaxActiveSessionsPerWorker: s.cfg.MaxActiveSessionsPerWorker,
	}
}

func (s *Service) evaluateAdmissionLocked(req contracts.MediaGatewaySessionRequest) (AdmissionDecision, error) {
	usage := s.admissionUsageForRequestLocked(req)
	decision := AdmissionDecision{
		SessionID:   req.SessionID,
		TenantID:    req.TenantID,
		WorkerID:    req.WorkerAssignment.WorkerID,
		Admitted:    true,
		StatusCode:  http.StatusCreated,
		Reason:      "session admitted",
		ReasonCode:  "accepted",
		EvaluatedAt: time.Now().UTC(),
		Quotas:      s.quotaConfig(),
		Usage:       usage,
	}

	switch {
	case s.cfg.MaxActiveSessions > 0 && usage.ActiveSessions >= s.cfg.MaxActiveSessions:
		decision.Admitted = false
		decision.StatusCode = http.StatusTooManyRequests
		decision.Reason = "gateway active session quota exceeded"
		decision.ReasonCode = "active-sessions-quota-exceeded"
		return decision, &apiError{status: decision.StatusCode, message: decision.Reason}
	case s.cfg.MaxActiveSessionsPerTenant > 0 && usage.TenantActiveSessions >= s.cfg.MaxActiveSessionsPerTenant:
		decision.Admitted = false
		decision.StatusCode = http.StatusTooManyRequests
		decision.Reason = "tenant active session quota exceeded"
		decision.ReasonCode = "tenant-active-sessions-quota-exceeded"
		return decision, &apiError{status: decision.StatusCode, message: decision.Reason}
	case s.cfg.MaxActiveSessionsPerWorker > 0 && usage.WorkerActiveSessions >= s.cfg.MaxActiveSessionsPerWorker:
		decision.Admitted = false
		decision.StatusCode = http.StatusTooManyRequests
		decision.Reason = "worker active session quota exceeded"
		decision.ReasonCode = "worker-active-sessions-quota-exceeded"
		return decision, &apiError{status: decision.StatusCode, message: decision.Reason}
	default:
		return decision, nil
	}
}

func (s *Service) recordAdmissionDecisionLocked(decision AdmissionDecision) {
	decisionCopy := decision

	s.admission.Attempts++
	switch {
	case decisionCopy.IdempotentReplay:
		s.admission.IdempotentReplays++
	case decisionCopy.Admitted:
		s.admission.Accepted++
	default:
		s.admission.Rejected++
		if decisionCopy.ReasonCode != "" {
			s.admission.RejectionsByReason[decisionCopy.ReasonCode]++
		}
	}

	s.admission.LastDecision = &decisionCopy
	s.admission.RecentDecisions = append(s.admission.RecentDecisions, decisionCopy)
	if len(s.admission.RecentDecisions) > recentAdmissionDecisionsLimit {
		s.admission.RecentDecisions = append([]AdmissionDecision(nil), s.admission.RecentDecisions[len(s.admission.RecentDecisions)-recentAdmissionDecisionsLimit:]...)
	}
}

func (s *Service) buildAdmissionSummaryLocked() AdmissionSummary {
	summary := AdmissionSummary{
		Quotas:             s.quotaConfig(),
		Attempts:           s.admission.Attempts,
		Accepted:           s.admission.Accepted,
		Rejected:           s.admission.Rejected,
		IdempotentReplays:  s.admission.IdempotentReplays,
		RejectionsByReason: cloneStringIntMap(s.admission.RejectionsByReason),
	}
	if s.admission.LastDecision != nil {
		last := *s.admission.LastDecision
		summary.LastDecision = &last
	}
	if len(s.admission.RecentDecisions) > 0 {
		summary.RecentDecisions = append([]AdmissionDecision(nil), s.admission.RecentDecisions...)
	}
	return summary
}

func (s *Service) admissionDecisionFromErrorLocked(req contracts.MediaGatewaySessionRequest, apiErr *apiError) AdmissionDecision {
	usage := s.admissionUsageForRequestLocked(req)
	return AdmissionDecision{
		SessionID:   strings.TrimSpace(req.SessionID),
		TenantID:    strings.TrimSpace(req.TenantID),
		WorkerID:    strings.TrimSpace(req.WorkerAssignment.WorkerID),
		Admitted:    false,
		StatusCode:  apiErr.status,
		Reason:      apiErr.message,
		ReasonCode:  classifyAdmissionReason(apiErr.message, apiErr.status),
		EvaluatedAt: time.Now().UTC(),
		Quotas:      s.quotaConfig(),
		Usage:       usage,
	}
}

type activeSessionUsage struct {
	ActiveSessions       int
	TenantActiveSessions int
	WorkerActiveSessions int
}

func (s *Service) activeSessionUsageLocked() (activeSessionUsage, map[string]int, map[string]int) {
	tenantCounts := map[string]int{}
	workerCounts := map[string]int{}
	total := 0
	for sessionID, record := range s.sessions {
		if !s.isSessionActiveLocked(sessionID) {
			continue
		}
		total++
		if record.Request.TenantID != "" {
			tenantCounts[record.Request.TenantID]++
		}
		if record.Request.WorkerAssignment.WorkerID != "" {
			workerCounts[record.Request.WorkerAssignment.WorkerID]++
		}
	}
	return activeSessionUsage{ActiveSessions: total}, tenantCounts, workerCounts
}

func (s *Service) admissionUsageForRequestLocked(req contracts.MediaGatewaySessionRequest) AdmissionQuotaUsage {
	usage, tenantCounts, workerCounts := s.activeSessionUsageLocked()
	return AdmissionQuotaUsage{
		ActiveSessions:       usage.ActiveSessions,
		TenantActiveSessions: tenantCounts[req.TenantID],
		WorkerActiveSessions: workerCounts[req.WorkerAssignment.WorkerID],
	}
}

func (s *Service) isSessionActiveLocked(sessionID string) bool {
	record, hasRecord := s.sessions[sessionID]

	if state := s.signals[sessionID]; state != nil && state.terminated {
		return false
	}
	if state := s.mediaRelays[sessionID]; state != nil && state.terminated {
		return false
	}
	if relay := s.webrtcRelays[sessionID]; relay != nil {
		return !relay.isTerminated()
	}
	if state := s.mediaRelays[sessionID]; state != nil {
		return true
	}
	if state := s.signals[sessionID]; state != nil {
		return true
	}
	if !hasRecord {
		return false
	}

	pendingTTL := s.cfg.PendingSessionActiveTTL
	if pendingTTL <= 0 {
		pendingTTL = defaultPendingSessionActiveTTL
	}
	return time.Since(record.CreatedAt) <= pendingTTL
}

func normalizeReplayComparableRequest(req contracts.MediaGatewaySessionRequest) contracts.MediaGatewaySessionRequest {
	req.Client = normalizeOptionalMap(req.Client)
	req.Experiments = normalizeOptionalMap(req.Experiments)
	return req
}

func requestsEquivalentForReplay(a, b contracts.MediaGatewaySessionRequest) bool {
	return reflect.DeepEqual(
		normalizeReplayComparableRequest(a),
		normalizeReplayComparableRequest(b),
	)
}

func normalizeOptionalMap(value map[string]any) map[string]any {
	if len(value) == 0 {
		return nil
	}
	return value
}

func classifyAdmissionReason(message string, status int) string {
	switch {
	case status == http.StatusTooManyRequests && strings.Contains(message, "tenant"):
		return "tenant-active-sessions-quota-exceeded"
	case status == http.StatusTooManyRequests && strings.Contains(message, "worker"):
		return "worker-active-sessions-quota-exceeded"
	case status == http.StatusTooManyRequests:
		return "active-sessions-quota-exceeded"
	case status == http.StatusConflict && strings.Contains(message, "replay"):
		return "session-id-conflict"
	case status == http.StatusConflict && strings.Contains(message, "region"):
		return "gateway-region-mismatch"
	case status == http.StatusConflict && strings.Contains(message, "gateway"):
		return "gateway-id-mismatch"
	case status == http.StatusBadRequest && strings.Contains(message, "workerAssignment.workerId"):
		return "worker-assignment-mismatch"
	case status == http.StatusBadRequest && strings.Contains(message, "relayMode"):
		return "unsupported-relay-mode"
	case status == http.StatusBadRequest && strings.Contains(message, "direct worker public endpoint"):
		return "direct-worker-public-endpoint"
	case status == http.StatusBadRequest && strings.Contains(message, "session ids"):
		return "assignment-session-id-mismatch"
	case status == http.StatusBadRequest && strings.Contains(message, "sessionId"):
		return "session-id-required"
	case status == http.StatusBadRequest && strings.Contains(message, "tenantId"):
		return "tenant-id-required"
	case status == http.StatusBadRequest && strings.Contains(message, "viewerToken"):
		return "viewer-token-required"
	case status == http.StatusBadRequest && strings.Contains(message, "workerToken"):
		return "worker-token-required"
	case status == http.StatusBadRequest && strings.Contains(message, "targetUrl"):
		return "invalid-target-url"
	default:
		trimmed := strings.TrimSpace(strings.ToLower(message))
		if trimmed == "" {
			return "admission-rejected"
		}
		trimmed = strings.ReplaceAll(trimmed, " ", "-")
		return trimmed
	}
}

func cloneStringIntMap(source map[string]int) map[string]int {
	if len(source) == 0 {
		return map[string]int{}
	}
	clone := make(map[string]int, len(source))
	for key, value := range source {
		clone[key] = value
	}
	return clone
}
