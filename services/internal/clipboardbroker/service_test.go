package clipboardbroker

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"cloudsec_remote_browser/services/internal/contracts"
)

func TestClipboardBrokerAllowsTextToRemote(t *testing.T) {
	svc := NewService(Config{MaxTextBytes: 1024})
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/clipboard", bytes.NewReader(mustJSON(t, contracts.ClipboardBrokerRequest{
		BrokerAuditContext: contracts.BrokerAuditContext{
			SessionID: "sess_clip",
			TenantID:  "tenant-a",
			Provider:  "cloudsec",
		},
		Direction: "to-remote",
		Format:    "text/plain",
		SizeBytes: 5,
		Text:      "hello",
	})))

	svc.Handler().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d: %s", http.StatusCreated, recorder.Code, recorder.Body.String())
	}

	var resp contracts.BrokerResponse
	if err := json.NewDecoder(recorder.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.Decision != contracts.BrokerDecisionAllowed || resp.ReleaseRef == "" || resp.FallbackProvider != "" {
		t.Fatalf("expected allowed clipboard release, got %#v", resp)
	}
}

func TestClipboardBrokerRejectsNonTextWithMenloFallback(t *testing.T) {
	svc := NewService(Config{})
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/clipboard", bytes.NewReader(mustJSON(t, contracts.ClipboardBrokerRequest{
		BrokerAuditContext: contracts.BrokerAuditContext{
			SessionID: "sess_clip",
			TenantID:  "tenant-a",
		},
		Direction: "to-remote",
		Format:    "text/html",
		SizeBytes: 12,
		Text:      "<b>hello</b>",
	})))

	svc.Handler().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d: %s", http.StatusCreated, recorder.Code, recorder.Body.String())
	}
	var resp contracts.BrokerResponse
	if err := json.NewDecoder(recorder.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.Decision != contracts.BrokerDecisionUnsupported ||
		resp.Reason != contracts.BrokerReasonUnsupportedMimeType ||
		resp.FallbackProvider != "menlo" {
		t.Fatalf("expected non-text Menlo fallback, got %#v", resp)
	}
}

func TestClipboardBrokerBlocksPolicyLabelAndTracksSummary(t *testing.T) {
	svc := NewService(Config{})
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/clipboard", bytes.NewReader(mustJSON(t, contracts.ClipboardBrokerRequest{
		BrokerAuditContext: contracts.BrokerAuditContext{
			SessionID: "sess_clip",
			TenantID:  "tenant-a",
		},
		Direction:    "from-remote",
		Format:       "text/plain",
		SizeBytes:    15,
		Text:         "secret material",
		PolicyLabels: []string{"secret"},
	})))

	svc.Handler().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d: %s", http.StatusCreated, recorder.Code, recorder.Body.String())
	}

	summaryRecorder := httptest.NewRecorder()
	svc.Handler().ServeHTTP(summaryRecorder, httptest.NewRequest(http.MethodGet, "/v1/summary", nil))
	if summaryRecorder.Code != http.StatusOK {
		t.Fatalf("expected summary status %d, got %d", http.StatusOK, summaryRecorder.Code)
	}
	var summary contracts.BrokerSummary
	if err := json.NewDecoder(summaryRecorder.Body).Decode(&summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.RequestsTotal != 1 || summary.Blocked != 1 ||
		summary.DecisionReasons[string(contracts.BrokerReasonPolicyBlocked)] != 1 ||
		summary.LastDecision == nil ||
		summary.LastDecision.FallbackProvider != "menlo" {
		t.Fatalf("unexpected summary %#v", summary)
	}
}

func TestClipboardBrokerRejectsMalformedRequest(t *testing.T) {
	svc := NewService(Config{})
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/clipboard", bytes.NewReader([]byte(`{}`)))
	svc.Handler().ServeHTTP(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected status %d, got %d: %s", http.StatusBadRequest, recorder.Code, recorder.Body.String())
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	body, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal json: %v", err)
	}
	return body
}
