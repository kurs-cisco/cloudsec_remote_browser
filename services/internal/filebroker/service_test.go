package filebroker

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"cloudsec_remote_browser/services/internal/contracts"
)

func TestFileBrokerAllowsSupportedDownload(t *testing.T) {
	svc := NewService(Config{MaxFileBytes: 1024})
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/files", bytes.NewReader(mustJSON(t, contracts.FileBrokerRequest{
		BrokerAuditContext: contracts.BrokerAuditContext{
			SessionID: "sess_file",
			TenantID:  "tenant-a",
			Provider:  "cloudsec",
		},
		Direction: "download",
		FileName:  "report.pdf",
		MimeType:  "application/pdf",
		SizeBytes: 512,
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
		t.Fatalf("expected allowed release, got %#v", resp)
	}
}

func TestFileBrokerFallsBackToMenloForUnsupportedDirection(t *testing.T) {
	svc := NewService(Config{})
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/files", bytes.NewReader(mustJSON(t, contracts.FileBrokerRequest{
		BrokerAuditContext: contracts.BrokerAuditContext{
			SessionID: "sess_file",
			TenantID:  "tenant-a",
		},
		Direction: "print",
		FileName:  "report.pdf",
		MimeType:  "application/pdf",
		SizeBytes: 128,
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
		resp.Reason != contracts.BrokerReasonUnsupportedDirection ||
		resp.FallbackProvider != "menlo" ||
		resp.Action != "fallback-to-menlo" {
		t.Fatalf("expected Menlo fallback for unsupported direction, got %#v", resp)
	}
}

func TestFileBrokerBlocksOversizedAndTracksSummary(t *testing.T) {
	svc := NewService(Config{MaxFileBytes: 10})
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/files", bytes.NewReader(mustJSON(t, contracts.FileBrokerRequest{
		BrokerAuditContext: contracts.BrokerAuditContext{
			SessionID: "sess_file",
			TenantID:  "tenant-a",
		},
		Direction: "upload",
		FileName:  "large.bin",
		MimeType:  "application/octet-stream",
		SizeBytes: 11,
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
		summary.DecisionReasons[string(contracts.BrokerReasonPayloadTooLarge)] != 1 ||
		summary.LastDecision == nil ||
		summary.LastDecision.FallbackProvider != "menlo" {
		t.Fatalf("unexpected summary %#v", summary)
	}
}

func TestFileBrokerRejectsMalformedRequest(t *testing.T) {
	svc := NewService(Config{})
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/files", bytes.NewReader([]byte(`{}`)))
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
