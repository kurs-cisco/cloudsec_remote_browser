package mediagateway

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"cloudsec_remote_browser/services/internal/contracts"
	"cloudsec_remote_browser/services/internal/httpx"
	"github.com/pion/webrtc/v4"
)

func TestDefaultConfigUsesGatewayMediaRelay(t *testing.T) {
	t.Setenv("MEDIA_GATEWAY_DEFAULT_RELAY_MODE", "")
	t.Setenv("MEDIA_GATEWAY_ENABLE_MEDIA_RELAY", "")

	cfg := LoadConfigFromEnv()
	if cfg.RelayMode != relayModeGatewayMediaRelay {
		t.Fatalf("expected default relay mode %q, got %q", relayModeGatewayMediaRelay, cfg.RelayMode)
	}
	if !cfg.EnableMediaRelay {
		t.Fatal("expected media relay to be enabled by default")
	}

	svc := NewService(Config{})
	if svc.cfg.RelayMode != relayModeGatewayMediaRelay {
		t.Fatalf("expected zero-value service relay mode %q, got %q", relayModeGatewayMediaRelay, svc.cfg.RelayMode)
	}
	if !svc.cfg.EnableMediaRelay {
		t.Fatal("expected zero-value service to enable media relay")
	}
}

func TestGatewaySignalingURLDoesNotPublishWsPrefix(t *testing.T) {
	got := buildSignalingURL("wss://gateway.example.com/ws", "sess_123", "websocket")
	parsed, err := url.Parse(got)
	if err != nil {
		t.Fatalf("parse signaling URL: %v", err)
	}
	if parsed.Path != "/gateway/signaling/sess_123/viewer" {
		t.Fatalf("expected gateway signaling path without /ws prefix, got %q", parsed.Path)
	}
}

func TestParseSignalRouteAcceptsLegacyWsPrefix(t *testing.T) {
	route, err := parseSignalRoute("/ws/gateway/signaling/sess_123/viewer")
	if err != nil {
		t.Fatalf("parse /ws gateway signaling route: %v", err)
	}
	if route.SessionID != "sess_123" || route.Role != "viewer" {
		t.Fatalf("unexpected route: %#v", route)
	}
}

func TestPionConfigurationSkipsTURNWithoutCredentials(t *testing.T) {
	svc := NewService(Config{
		ICEURLs: []string{
			"stun:turn.example.com:3478",
			"turn:turn.example.com:3478?transport=udp",
		},
	})
	cfg := svc.pionConfiguration()
	if len(cfg.ICEServers) != 1 {
		t.Fatalf("expected only the STUN server when TURN credentials are absent, got %#v", cfg.ICEServers)
	}
	if cfg.ICEServers[0].URLs[0] != "stun:turn.example.com:3478" {
		t.Fatalf("unexpected ICE server: %#v", cfg.ICEServers[0])
	}
}

func TestPionConfigurationBuildsTURNCredentialsFromSharedSecret(t *testing.T) {
	svc := NewService(Config{
		GatewayID:         "gateway-test-01",
		ICEURLs:           []string{"turn:turn.example.com:3478?transport=udp"},
		TURNSharedSecret:  "test-secret",
		TURNCredentialTTL: time.Minute,
	})
	cfg := svc.pionConfiguration()
	if len(cfg.ICEServers) != 1 {
		t.Fatalf("expected one TURN server, got %#v", cfg.ICEServers)
	}
	server := cfg.ICEServers[0]
	if !strings.Contains(server.Username, ":media-gateway.gateway-test-01") {
		t.Fatalf("unexpected generated TURN username %q", server.Username)
	}
	if server.Credential == nil || fmt.Sprint(server.Credential) == "" {
		t.Fatalf("expected generated TURN credential, got %#v", server.Credential)
	}
}

func TestCreateSessionReturnsViewerTransport(t *testing.T) {
	svc := NewService(Config{
		Region:              "us-west-2",
		GatewayID:           "gateway-us-west-2-01",
		PublicBaseURL:       "https://gateway.example.com",
		PublicWsURL:         "wss://gateway.example.com/ws",
		SupportedTransports: []string{"webtransport", "websocket"},
		PreferredTransport:  "webtransport",
		RelayMode:           "gateway-relay",
	})

	requestBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:          "sess_123",
		TenantID:           "tenant-a",
		ProfileID:          "profile-a",
		ViewerEntryMode:    "swg-handoff",
		PreferredTransport: "websocket",
		Generation:         2,
		ViewerToken:        "viewer-token-123",
		WorkerToken:        "worker-token-123",
		PublicBaseURL:      "https://public-gateway.example.com",
		PublicWsURL:        "wss://public-gateway.example.com/ws",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID:     "worker-us-west-2-007",
			RuntimeClass: "kata-clh",
		},
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(requestBody))
	svc.Handler().ServeHTTP(recorder, request)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d: %s", http.StatusCreated, recorder.Code, recorder.Body.String())
	}

	var resp contracts.MediaGatewaySessionResponse
	if err := json.NewDecoder(recorder.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if resp.Transport.Preferred != "websocket" {
		t.Fatalf("expected websocket transport, got %q", resp.Transport.Preferred)
	}
	if !strings.Contains(resp.Transport.ViewerURL, "/gateway/viewer/sess_123") {
		t.Fatalf("unexpected viewerUrl %q", resp.Transport.ViewerURL)
	}
	if !strings.Contains(resp.Transport.SignalingURL, "/gateway/signaling/sess_123/viewer") {
		t.Fatalf("unexpected signalingUrl %q", resp.Transport.SignalingURL)
	}
	if resp.Transport.MediaTermination == nil {
		t.Fatal("expected media termination capability to be reported")
	}
	if resp.Transport.MediaTermination.Mode != mediaTerminationModeSignalingRelay {
		t.Fatalf("expected media termination mode %q, got %#v", mediaTerminationModeSignalingRelay, resp.Transport.MediaTermination)
	}
	if resp.Transport.MediaTermination.GatewayTerminatesMedia {
		t.Fatalf("gateway media termination must not be reported complete yet: %#v", resp.Transport.MediaTermination)
	}
	if resp.Transport.MediaTermination.Wave2AcceptanceComplete {
		t.Fatalf("Wave 2 media termination acceptance must remain incomplete: %#v", resp.Transport.MediaTermination)
	}
	if resp.Transport.MediaTermination.RelayMode != relayModeGatewayRelay {
		t.Fatalf("expected media termination relay mode %q, got %#v", relayModeGatewayRelay, resp.Transport.MediaTermination)
	}
	if resp.Transport.MediaTermination.RelayModeAcceptanceState != relayModeAcceptanceStateAccepted {
		t.Fatalf("expected relay mode acceptance state %q, got %#v", relayModeAcceptanceStateAccepted, resp.Transport.MediaTermination)
	}
	if resp.Transport.MediaTermination.DirectWorkerExposureAllowed {
		t.Fatalf("direct worker exposure must not be allowed: %#v", resp.Transport.MediaTermination)
	}
	if strings.Contains(resp.Transport.ViewerURL, "worker-us-west-2-007") {
		t.Fatalf("viewerUrl should not expose worker id: %q", resp.Transport.ViewerURL)
	}
	if resp.GatewayAssignment.PublicBaseURL != "https://public-gateway.example.com" {
		t.Fatalf("expected public base URL override, got %q", resp.GatewayAssignment.PublicBaseURL)
	}
	if resp.WorkerBridge.BridgeID == "" {
		t.Fatal("expected worker bridge id to be set")
	}

	recordResponse := httptest.NewRecorder()
	recordRequest := httptest.NewRequest(http.MethodGet, "/v1/sessions/sess_123", nil)
	svc.Handler().ServeHTTP(recordResponse, recordRequest)
	if recordResponse.Code != http.StatusOK {
		t.Fatalf("expected GET status %d, got %d", http.StatusOK, recordResponse.Code)
	}
	var record SessionRecord
	if err := json.NewDecoder(recordResponse.Body).Decode(&record); err != nil {
		t.Fatalf("decode record: %v", err)
	}
	if record.Admission == nil || !record.Admission.Admitted {
		t.Fatalf("expected admitted session record, got %#v", record.Admission)
	}

	replayResponse := httptest.NewRecorder()
	replayRequest := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(requestBody))
	svc.Handler().ServeHTTP(replayResponse, replayRequest)
	if replayResponse.Code != http.StatusOK {
		t.Fatalf("expected idempotent status %d, got %d", http.StatusOK, replayResponse.Code)
	}
}

func TestCreateSessionRejectsForeignRegion(t *testing.T) {
	svc := NewService(Config{
		Region:              "us-west-2",
		GatewayID:           "gateway-us-west-2-01",
		PublicBaseURL:       "https://gateway.example.com",
		PublicWsURL:         "wss://gateway.example.com/ws",
		SupportedTransports: []string{"webtransport", "websocket"},
		PreferredTransport:  "webtransport",
		RelayMode:           "gateway-relay",
	})

	requestBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_456",
		TenantID:    "tenant-b",
		ViewerToken: "viewer-token-456",
		WorkerToken: "worker-token-456",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-east-1",
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-east-1-001",
		},
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(requestBody))
	svc.Handler().ServeHTTP(recorder, request)

	if recorder.Code != http.StatusConflict {
		t.Fatalf("expected status %d, got %d: %s", http.StatusConflict, recorder.Code, recorder.Body.String())
	}
}

func TestCreateSessionRejectsUnsupportedRelayMode(t *testing.T) {
	svc := NewService(Config{
		Region:              "us-west-2",
		GatewayID:           "gateway-us-west-2-01",
		PublicBaseURL:       "https://gateway.example.com",
		PublicWsURL:         "wss://gateway.example.com/ws",
		SupportedTransports: []string{"webtransport", "websocket"},
		PreferredTransport:  "webtransport",
		RelayMode:           "gateway-relay",
	})

	requestBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_direct",
		TenantID:    "tenant-a",
		ViewerToken: "viewer-token-direct",
		WorkerToken: "worker-token-direct",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
			RelayMode: "direct",
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(requestBody))
	svc.Handler().ServeHTTP(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected status %d, got %d: %s", http.StatusBadRequest, recorder.Code, recorder.Body.String())
	}

	summaryResponse := httptest.NewRecorder()
	summaryRequest := httptest.NewRequest(http.MethodGet, "/v1/summary", nil)
	svc.Handler().ServeHTTP(summaryResponse, summaryRequest)
	if summaryResponse.Code != http.StatusOK {
		t.Fatalf("expected summary status %d, got %d: %s", http.StatusOK, summaryResponse.Code, summaryResponse.Body.String())
	}

	var summary SummaryResponse
	if err := json.NewDecoder(summaryResponse.Body).Decode(&summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.Admission.RejectionsByReason["unsupported-relay-mode"] != 1 {
		t.Fatalf("expected unsupported relay mode rejection, got %#v", summary.Admission.RejectionsByReason)
	}
	if summary.MediaTermination.Wave2AcceptanceComplete {
		t.Fatalf("Wave 2 media termination must not be complete with no gateway media sessions: %#v", summary.MediaTermination)
	}
}

func TestCreateSessionGatewayMediaRelayModeReportsWave2Acceptance(t *testing.T) {
	svc := NewService(Config{
		Region:              "us-west-2",
		GatewayID:           "gateway-us-west-2-01",
		PublicBaseURL:       "https://gateway.example.com",
		PublicWsURL:         "wss://gateway.example.com/ws",
		WorkerBaseURL:       "http://media-gateway.control.svc.cluster.local:18082",
		WorkerWsURL:         "ws://media-gateway.control.svc.cluster.local:18082",
		SupportedTransports: []string{"websocket"},
		PreferredTransport:  "websocket",
		RelayMode:           "gateway-relay",
		EnableMediaRelay:    true,
	})

	requestBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:          "sess_media",
		TenantID:           "tenant-a",
		PreferredTransport: "websocket",
		ViewerToken:        "viewer-token-media",
		WorkerToken:        "worker-token-media",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
			RelayMode: relayModeGatewayMediaRelay,
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(requestBody))
	svc.Handler().ServeHTTP(recorder, request)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d: %s", http.StatusCreated, recorder.Code, recorder.Body.String())
	}

	var resp contracts.MediaGatewaySessionResponse
	if err := json.NewDecoder(recorder.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.WorkerBridge.RelayMode != relayModeGatewayMediaRelay {
		t.Fatalf("expected media relay mode, got %#v", resp.WorkerBridge)
	}
	if !strings.Contains(resp.Transport.MediaRelayURL, "/gateway/media/sess_media/viewer") {
		t.Fatalf("expected viewer media relay URL, got %q", resp.Transport.MediaRelayURL)
	}
	if !strings.Contains(resp.WorkerBridge.MediaRelayURL, "/gateway/media/sess_media/worker") {
		t.Fatalf("expected worker media relay URL, got %q", resp.WorkerBridge.MediaRelayURL)
	}
	if !strings.HasPrefix(resp.WorkerBridge.MediaRelayURL, "ws://media-gateway.control.svc.cluster.local:18082/") {
		t.Fatalf("expected worker media relay URL to use internal worker gateway base, got %q", resp.WorkerBridge.MediaRelayURL)
	}
	if !strings.HasPrefix(resp.WorkerBridge.MediaGatewayURL, "http://media-gateway.control.svc.cluster.local:18082/") {
		t.Fatalf("expected worker WebRTC URL to use internal worker gateway base, got %q", resp.WorkerBridge.MediaGatewayURL)
	}
	if !strings.HasPrefix(resp.Transport.MediaGatewayURL, "https://gateway.example.com/") {
		t.Fatalf("expected viewer WebRTC URL to keep public gateway base, got %q", resp.Transport.MediaGatewayURL)
	}
	if strings.Contains(resp.Transport.ViewerURL, "worker-us-west-2-001") ||
		strings.Contains(resp.Transport.SignalingURL, "worker-us-west-2-001") ||
		strings.Contains(resp.Transport.MediaRelayURL, "worker-us-west-2-001") {
		t.Fatalf("browser-facing URLs must not expose worker identity: %#v", resp.Transport)
	}
	if resp.Transport.MediaTermination == nil || !resp.Transport.MediaTermination.GatewayTerminatesMedia {
		t.Fatalf("expected gateway media termination capability, got %#v", resp.Transport.MediaTermination)
	}
	if !resp.Transport.MediaTermination.Wave2AcceptanceComplete {
		t.Fatalf("expected media relay sessions to satisfy Wave 2 transport acceptance, got %#v", resp.Transport.MediaTermination)
	}

	svc.mu.Lock()
	svc.mediaRelays["sess_media"] = &mediaSessionState{
		viewer:             &signalConnection{id: "viewer-media"},
		worker:             &signalConnection{id: "worker-media"},
		framesToViewer:     3,
		framesToWorker:     4,
		bytesToViewer:      300,
		bytesToWorker:      400,
		lastFrameRelayedAt: time.Unix(1700000100, 0).UTC(),
	}
	svc.mu.Unlock()

	summaryResponse := httptest.NewRecorder()
	summaryRequest := httptest.NewRequest(http.MethodGet, "/v1/summary", nil)
	svc.Handler().ServeHTTP(summaryResponse, summaryRequest)
	if summaryResponse.Code != http.StatusOK {
		t.Fatalf("expected summary status %d, got %d: %s", http.StatusOK, summaryResponse.Code, summaryResponse.Body.String())
	}

	var summary SummaryResponse
	if err := json.NewDecoder(summaryResponse.Body).Decode(&summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.MediaTermination.SessionsByMode[mediaTerminationModeGatewayRelay] != 1 {
		t.Fatalf("expected gateway media relay count, got %#v", summary.MediaTermination.SessionsByMode)
	}
	if summary.MediaTermination.SessionsWithGatewayTerminatedMedia != 1 ||
		summary.MediaTermination.SessionsWithoutGatewayTerminatedMedia != 0 ||
		!summary.MediaTermination.Wave2AcceptanceComplete {
		t.Fatalf("unexpected media termination summary %#v", summary.MediaTermination)
	}
	if summary.MediaRelaySessions != 1 || summary.MediaViewerConnected != 1 || summary.MediaWorkerConnected != 1 {
		t.Fatalf("unexpected media relay connection summary %#v", summary)
	}
	if summary.MediaFramesToViewer != 3 || summary.MediaFramesToWorker != 4 ||
		summary.MediaBytesToViewer != 300 || summary.MediaBytesToWorker != 400 {
		t.Fatalf("unexpected media relay traffic summary %#v", summary)
	}
}

func TestGatewayWebRTCRelayEndpointValidatesTokenAndCodec(t *testing.T) {
	svc := NewService(Config{
		Region:              "us-west-2",
		GatewayID:           "gateway-us-west-2-01",
		PublicBaseURL:       "https://gateway.example.com",
		PublicWsURL:         "wss://gateway.example.com/ws",
		SupportedTransports: []string{"websocket"},
		PreferredTransport:  "websocket",
		RelayMode:           "gateway-relay",
		EnableMediaRelay:    true,
	})

	createBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_webrtc",
		TenantID:    "tenant-a",
		ViewerToken: "viewer-token-webrtc",
		WorkerToken: "worker-token-webrtc",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
			RelayMode: relayModeGatewayMediaRelay,
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	})
	createResponse := httptest.NewRecorder()
	svc.Handler().ServeHTTP(
		createResponse,
		httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(createBody)),
	)
	if createResponse.Code != http.StatusCreated {
		t.Fatalf("expected create status %d, got %d: %s", http.StatusCreated, createResponse.Code, createResponse.Body.String())
	}

	acceptedBody := marshalJSON(t, map[string]any{
		"type":  "offer",
		"token": "viewer-token-webrtc",
		"sdp":   newTestViewerOfferSDP(t),
	})
	acceptedResponse := httptest.NewRecorder()
	svc.Handler().ServeHTTP(
		acceptedResponse,
		httptest.NewRequest(http.MethodPost, "/gateway/webrtc/sess_webrtc/viewer/offer", bytes.NewReader(acceptedBody)),
	)
	if acceptedResponse.Code != http.StatusOK {
		t.Fatalf("expected webrtc status %d, got %d: %s", http.StatusOK, acceptedResponse.Code, acceptedResponse.Body.String())
	}
	var accepted map[string]any
	if err := json.NewDecoder(acceptedResponse.Body).Decode(&accepted); err != nil {
		t.Fatalf("decode accepted response: %v", err)
	}
	if accepted["type"] != "answer" || !strings.Contains(fmt.Sprint(accepted["sdp"]), "m=video") {
		t.Fatalf("expected SDP answer response, got %#v", accepted)
	}
	if accepted["mediaPlaneMode"] != mediaPlaneModeGatewayWebRTCRelay ||
		accepted["protocol"] != mediaTerminationProtocolWebRTCSRTP ||
		accepted["inputPointerName"] != inputPointerChannelName ||
		accepted["inputControlName"] != inputControlChannelName {
		t.Fatalf("unexpected webrtc response %#v", accepted)
	}

	badCodecBody := marshalJSON(t, map[string]any{
		"type":  "offer",
		"token": "viewer-token-webrtc",
		"sdp":   "v=0\r\na=rtpmap:102 H264/90000\r\n",
	})
	badCodecResponse := httptest.NewRecorder()
	svc.Handler().ServeHTTP(
		badCodecResponse,
		httptest.NewRequest(http.MethodPost, "/gateway/webrtc/sess_webrtc/viewer/offer", bytes.NewReader(badCodecBody)),
	)
	if badCodecResponse.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("expected unsupported codec status %d, got %d: %s", http.StatusUnsupportedMediaType, badCodecResponse.Code, badCodecResponse.Body.String())
	}
	summaryResponse := httptest.NewRecorder()
	svc.Handler().ServeHTTP(summaryResponse, httptest.NewRequest(http.MethodGet, "/v1/summary", nil))
	if summaryResponse.Code != http.StatusOK {
		t.Fatalf("expected summary status %d, got %d: %s", http.StatusOK, summaryResponse.Code, summaryResponse.Body.String())
	}
	var summary SummaryResponse
	if err := json.NewDecoder(summaryResponse.Body).Decode(&summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.WebRTCCodecRejects.Total != 1 ||
		summary.WebRTCCodecRejects.ByRole["viewer"] != 1 ||
		summary.WebRTCCodecRejects.ByReason["unsupported-video-codec"] != 1 {
		t.Fatalf("expected VP8/Opus codec reject counters, got %#v", summary.WebRTCCodecRejects)
	}

	badTokenBody := marshalJSON(t, map[string]any{
		"type":  "offer",
		"token": "wrong-token",
		"sdp":   "v=0\r\na=rtpmap:96 VP8/90000\r\n",
	})
	badTokenResponse := httptest.NewRecorder()
	svc.Handler().ServeHTTP(
		badTokenResponse,
		httptest.NewRequest(http.MethodPost, "/gateway/webrtc/sess_webrtc/viewer/offer", bytes.NewReader(badTokenBody)),
	)
	if badTokenResponse.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized status %d, got %d: %s", http.StatusUnauthorized, badTokenResponse.Code, badTokenResponse.Body.String())
	}
}

func TestGatewayWebRTCRelayRequiresGatewayContract(t *testing.T) {
	svc := NewService(Config{
		Region:              "us-west-2",
		GatewayID:           "gateway-us-west-2-01",
		PublicBaseURL:       "https://gateway.example.com",
		PublicWsURL:         "wss://gateway.example.com/ws",
		SupportedTransports: []string{"websocket"},
		PreferredTransport:  "websocket",
		RelayMode:           "gateway-relay",
		EnableMediaRelay:    true,
	})

	createBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_missing_contract",
		TenantID:    "tenant-a",
		ViewerToken: "viewer-token-webrtc",
		WorkerToken: "worker-token-webrtc",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
			RelayMode: relayModeGatewayMediaRelay,
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	})
	createResponse := httptest.NewRecorder()
	svc.Handler().ServeHTTP(
		createResponse,
		httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(createBody)),
	)
	if createResponse.Code != http.StatusCreated {
		t.Fatalf("expected create status %d, got %d: %s", http.StatusCreated, createResponse.Code, createResponse.Body.String())
	}

	svc.mu.Lock()
	record := svc.sessions["sess_missing_contract"]
	record.Response.Transport.MediaGatewayURL = ""
	svc.sessions["sess_missing_contract"] = record
	svc.mu.Unlock()

	offerBody := marshalJSON(t, map[string]any{
		"type":  "offer",
		"token": "viewer-token-webrtc",
		"sdp":   newTestViewerOfferSDP(t),
	})
	offerResponse := httptest.NewRecorder()
	svc.Handler().ServeHTTP(
		offerResponse,
		httptest.NewRequest(http.MethodPost, "/gateway/webrtc/sess_missing_contract/viewer/offer", bytes.NewReader(offerBody)),
	)
	if offerResponse.Code != http.StatusBadRequest {
		t.Fatalf("expected bad request status %d, got %d: %s", http.StatusBadRequest, offerResponse.Code, offerResponse.Body.String())
	}
	if !strings.Contains(offerResponse.Body.String(), "transport.mediaGatewayUrl") {
		t.Fatalf("expected missing mediaGatewayUrl error, got %s", offerResponse.Body.String())
	}
	if _, ok := svc.webrtcRelays["sess_missing_contract"]; ok {
		t.Fatal("gateway webrtc relay should not be created for an incomplete contract")
	}
}

func TestTerminateSessionClosesWebRTCRelayAndUpdatesSummary(t *testing.T) {
	svc := NewService(Config{
		Region:              "us-west-2",
		GatewayID:           "gateway-us-west-2-01",
		PublicBaseURL:       "https://gateway.example.com",
		PublicWsURL:         "wss://gateway.example.com/ws",
		SupportedTransports: []string{"websocket"},
		PreferredTransport:  "websocket",
		RelayMode:           "gateway-relay",
		EnableMediaRelay:    true,
	})

	createBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_terminate_webrtc",
		TenantID:    "tenant-a",
		ViewerToken: "viewer-token-webrtc",
		WorkerToken: "worker-token-webrtc",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
			RelayMode: relayModeGatewayMediaRelay,
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	})
	createResponse := httptest.NewRecorder()
	svc.Handler().ServeHTTP(
		createResponse,
		httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(createBody)),
	)
	if createResponse.Code != http.StatusCreated {
		t.Fatalf("expected create status %d, got %d: %s", http.StatusCreated, createResponse.Code, createResponse.Body.String())
	}

	offerBody := marshalJSON(t, map[string]any{
		"type":  "offer",
		"token": "viewer-token-webrtc",
		"sdp":   newTestViewerOfferSDP(t),
	})
	offerResponse := httptest.NewRecorder()
	svc.Handler().ServeHTTP(
		offerResponse,
		httptest.NewRequest(http.MethodPost, "/gateway/webrtc/sess_terminate_webrtc/viewer/offer", bytes.NewReader(offerBody)),
	)
	if offerResponse.Code != http.StatusOK {
		t.Fatalf("expected offer status %d, got %d: %s", http.StatusOK, offerResponse.Code, offerResponse.Body.String())
	}

	terminateResponse := httptest.NewRecorder()
	terminateBody := marshalJSON(t, terminateRequest{Reason: "cutover-drain"})
	svc.Handler().ServeHTTP(
		terminateResponse,
		httptest.NewRequest(http.MethodPost, "/v1/sessions/sess_terminate_webrtc/terminate", bytes.NewReader(terminateBody)),
	)
	if terminateResponse.Code != http.StatusOK {
		t.Fatalf("expected terminate status %d, got %d: %s", http.StatusOK, terminateResponse.Code, terminateResponse.Body.String())
	}

	record, ok := svc.GetSession("sess_terminate_webrtc")
	if !ok {
		t.Fatal("expected session record after termination")
	}
	if record.WebRTCRelayState == nil || !record.WebRTCRelayState.Terminated {
		t.Fatalf("expected terminated webrtc relay state, got %#v", record.WebRTCRelayState)
	}
	if record.WebRTCRelayState.TerminationReason != "cutover-drain" {
		t.Fatalf("expected termination reason, got %#v", record.WebRTCRelayState)
	}
	if len(record.WebRTCRelayState.ViewerDataChannels) != 0 || len(record.WebRTCRelayState.WorkerDataChannels) != 0 {
		t.Fatalf("expected data channel state to be cleared, got %#v", record.WebRTCRelayState)
	}

	summary := svc.buildSummary()
	if summary.WebRTCRelaySessions != 1 ||
		summary.WebRTCActiveRelaySessions != 0 ||
		summary.WebRTCTerminatedRelays != 1 ||
		summary.WebRTCTerminationReasons["cutover-drain"] != 1 ||
		summary.WebRTCLastTerminationReason != "cutover-drain" {
		t.Fatalf("unexpected webrtc termination summary %#v", summary)
	}

	postTerminateOffer := httptest.NewRecorder()
	svc.Handler().ServeHTTP(
		postTerminateOffer,
		httptest.NewRequest(http.MethodPost, "/gateway/webrtc/sess_terminate_webrtc/viewer/offer", bytes.NewReader(offerBody)),
	)
	if postTerminateOffer.Code != http.StatusGone {
		t.Fatalf("expected terminated session offer status %d, got %d: %s", http.StatusGone, postTerminateOffer.Code, postTerminateOffer.Body.String())
	}
}

func TestWebRTCRelayPeerDisconnectTerminatesSessionStateAndSummary(t *testing.T) {
	svc, sessionID := newTestGatewayMediaRelaySession(t)

	record, ok := svc.GetSession(sessionID)
	if !ok {
		t.Fatal("expected gateway media relay session")
	}
	relay, err := svc.getOrCreatePionRelaySession(record)
	if err != nil {
		t.Fatalf("create webrtc relay: %v", err)
	}

	svc.mu.Lock()
	svc.mediaRelays[sessionID] = &mediaSessionState{
		pendingViewer:      [][]byte{[]byte("queued-frame")},
		pendingViewerBytes: len("queued-frame"),
		pendingWorker:      [][]byte{[]byte("queued-input")},
		pendingWorkerBytes: len("queued-input"),
	}
	svc.mu.Unlock()

	before := svc.buildSummary()
	if before.ActiveSessions != 1 || before.WebRTCActiveRelaySessions != 1 {
		t.Fatalf("expected active session before peer disconnect, got %#v", before)
	}

	relay.handlePeerConnectionStateChange("viewer", nil, webrtc.PeerConnectionStateDisconnected)

	record, ok = svc.GetSession(sessionID)
	if !ok {
		t.Fatal("expected session record after peer disconnect")
	}
	if record.WebRTCRelayState == nil || !record.WebRTCRelayState.Terminated {
		t.Fatalf("expected terminated webrtc relay state, got %#v", record.WebRTCRelayState)
	}
	if record.WebRTCRelayState.TerminationReason != "viewer peer disconnected" {
		t.Fatalf("expected disconnect termination reason, got %#v", record.WebRTCRelayState)
	}
	if record.SignalState == nil || !record.SignalState.Terminated {
		t.Fatalf("expected signal session to be terminated by media close, got %#v", record.SignalState)
	}
	if record.MediaRelayState == nil || !record.MediaRelayState.Terminated ||
		record.MediaRelayState.PendingViewerFrames != 0 ||
		record.MediaRelayState.PendingWorkerFrames != 0 {
		t.Fatalf("expected media relay state cleanup, got %#v", record.MediaRelayState)
	}

	summary := svc.buildSummary()
	if summary.ActiveSessions != 0 ||
		summary.WebRTCActiveRelaySessions != 0 ||
		summary.WebRTCTerminatedRelays != 1 ||
		summary.WebRTCTerminationReasons["viewer peer disconnected"] != 1 {
		t.Fatalf("unexpected summary after peer disconnect %#v", summary)
	}
	if summary.ActiveSessionsByTenant["tenant-a"] != 0 ||
		summary.ActiveSessionsByWorker["worker-us-west-2-001"] != 0 {
		t.Fatalf("expected disconnected relay to be removed from active usage, got tenants=%#v workers=%#v", summary.ActiveSessionsByTenant, summary.ActiveSessionsByWorker)
	}
}

func TestTerminatedWebRTCRelayWithoutSignalStateDoesNotConsumeWorkerQuota(t *testing.T) {
	svc := NewService(Config{
		Region:                     "us-west-2",
		GatewayID:                  "gateway-us-west-2-01",
		PublicBaseURL:              "https://gateway.example.com",
		PublicWsURL:                "wss://gateway.example.com/ws",
		SupportedTransports:        []string{"websocket"},
		PreferredTransport:         "websocket",
		RelayMode:                  "gateway-relay",
		EnableMediaRelay:           true,
		MaxActiveSessionsPerWorker: 1,
	})

	firstReq := contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_stale_webrtc",
		TenantID:    "tenant-a",
		ViewerToken: "viewer-token-stale-webrtc",
		WorkerToken: "worker-token-stale-webrtc",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
			RelayMode: relayModeGatewayMediaRelay,
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	}
	if _, status, err := svc.CreateSession(firstReq); err != nil || status != http.StatusCreated {
		t.Fatalf("expected first session create, status=%d err=%v", status, err)
	}
	record, ok := svc.GetSession(firstReq.SessionID)
	if !ok {
		t.Fatal("expected first gateway session record")
	}
	relay, err := svc.getOrCreatePionRelaySession(record)
	if err != nil {
		t.Fatalf("create webrtc relay: %v", err)
	}
	relay.close("viewer peer disconnected")

	svc.mu.Lock()
	delete(svc.signals, firstReq.SessionID)
	svc.mu.Unlock()

	summary := svc.buildSummary()
	if summary.ActiveSessions != 0 || summary.ActiveSessionsByWorker[firstReq.WorkerAssignment.WorkerID] != 0 {
		t.Fatalf("terminated webrtc relay must not consume worker quota, got %#v", summary)
	}

	secondReq := firstReq
	secondReq.SessionID = "sess_after_stale_webrtc"
	secondReq.ViewerToken = "viewer-token-after-stale-webrtc"
	secondReq.WorkerToken = "worker-token-after-stale-webrtc"
	if _, status, err := svc.CreateSession(secondReq); err != nil || status != http.StatusCreated {
		t.Fatalf("expected replacement session to be admitted after terminated relay, status=%d err=%v", status, err)
	}
}

func TestStalePendingGatewaySessionDoesNotConsumeWorkerQuota(t *testing.T) {
	svc := NewService(Config{
		Region:                     "us-west-2",
		GatewayID:                  "gateway-us-west-2-01",
		PublicBaseURL:              "https://gateway.example.com",
		PublicWsURL:                "wss://gateway.example.com/ws",
		SupportedTransports:        []string{"websocket"},
		PreferredTransport:         "websocket",
		RelayMode:                  "gateway-relay",
		EnableMediaRelay:           true,
		MaxActiveSessionsPerWorker: 1,
		PendingSessionActiveTTL:    time.Second,
	})

	firstReq := contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_stale_pending",
		TenantID:    "tenant-a",
		ViewerToken: "viewer-token-stale-pending",
		WorkerToken: "worker-token-stale-pending",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
			RelayMode: relayModeGatewayMediaRelay,
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	}
	if _, status, err := svc.CreateSession(firstReq); err != nil || status != http.StatusCreated {
		t.Fatalf("expected first session create, status=%d err=%v", status, err)
	}

	svc.mu.Lock()
	record := svc.sessions[firstReq.SessionID]
	record.CreatedAt = time.Now().Add(-2 * time.Second)
	svc.sessions[firstReq.SessionID] = record
	svc.mu.Unlock()

	summary := svc.buildSummary()
	if summary.ActiveSessions != 0 || summary.ActiveSessionsByWorker[firstReq.WorkerAssignment.WorkerID] != 0 {
		t.Fatalf("stale pending session must not consume worker quota, got %#v", summary)
	}

	secondReq := firstReq
	secondReq.SessionID = "sess_after_stale_pending"
	secondReq.ViewerToken = "viewer-token-after-stale-pending"
	secondReq.WorkerToken = "worker-token-after-stale-pending"
	if _, status, err := svc.CreateSession(secondReq); err != nil || status != http.StatusCreated {
		t.Fatalf("expected session to be admitted after stale pending expiry, status=%d err=%v", status, err)
	}

	summary = svc.buildSummary()
	if summary.ActiveSessions != 1 || summary.ActiveSessionsByWorker[firstReq.WorkerAssignment.WorkerID] != 1 {
		t.Fatalf("expected only replacement session to consume worker quota, got %#v", summary)
	}
}

func TestGatewayMediaRelayWebSocketForwardsBidirectionally(t *testing.T) {
	svc := NewService(Config{
		Region:              "us-west-2",
		GatewayID:           "gateway-us-west-2-01",
		PublicBaseURL:       "https://gateway.example.com",
		PublicWsURL:         "wss://gateway.example.com/ws",
		SupportedTransports: []string{"websocket"},
		PreferredTransport:  "websocket",
		RelayMode:           "gateway-relay",
		EnableMediaRelay:    true,
	})
	server := httptest.NewServer(svc.Handler())
	defer server.Close()

	publicWsURL := strings.Replace(server.URL, "http://", "ws://", 1)
	svc.cfg.PublicBaseURL = server.URL
	svc.cfg.PublicWsURL = publicWsURL
	svc.cfg.WorkerBaseURL = server.URL
	svc.cfg.WorkerWsURL = publicWsURL
	requestBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:          "sess_media_ws",
		TenantID:           "tenant-a",
		PreferredTransport: "websocket",
		ViewerToken:        "viewer-token-media-ws",
		WorkerToken:        "worker-token-media-ws",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
			RelayMode: relayModeGatewayMediaRelay,
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(requestBody))
	svc.Handler().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d: %s", http.StatusCreated, recorder.Code, recorder.Body.String())
	}

	var resp contracts.MediaGatewaySessionResponse
	if err := json.NewDecoder(recorder.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	worker := dialTestWebSocket(t, resp.WorkerBridge.MediaRelayURL)
	defer worker.CloseNow()
	writeTestWebSocketJSON(t, worker, map[string]any{
		"type":      "register",
		"role":      "worker",
		"sessionId": "sess_media_ws",
		"token":     "worker-token-media-ws",
	})
	assertTestWebSocketMessageType(t, worker, "media-registered")

	viewer := dialTestWebSocket(t, resp.Transport.MediaRelayURL)
	defer viewer.CloseNow()
	writeTestWebSocketJSON(t, viewer, map[string]any{
		"type":      "register",
		"role":      "viewer",
		"sessionId": "sess_media_ws",
		"token":     "viewer-token-media-ws",
	})
	assertTestWebSocketMessageType(t, viewer, "media-registered")

	workerPayload := map[string]any{"type": "pixel-frame", "seq": float64(1)}
	writeTestWebSocketJSON(t, worker, workerPayload)
	assertTestWebSocketJSON(t, viewer, workerPayload)

	viewerPayload := map[string]any{"type": "input-event", "seq": float64(2)}
	writeTestWebSocketJSON(t, viewer, viewerPayload)
	assertTestWebSocketJSON(t, worker, viewerPayload)

	summaryResponse := httptest.NewRecorder()
	summaryRequest := httptest.NewRequest(http.MethodGet, "/v1/summary", nil)
	svc.Handler().ServeHTTP(summaryResponse, summaryRequest)
	if summaryResponse.Code != http.StatusOK {
		t.Fatalf("expected summary status %d, got %d: %s", http.StatusOK, summaryResponse.Code, summaryResponse.Body.String())
	}
	var summary SummaryResponse
	if err := json.NewDecoder(summaryResponse.Body).Decode(&summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if !summary.MediaTermination.Wave2AcceptanceComplete {
		t.Fatalf("expected gateway media relay session to satisfy Wave 2 relay acceptance, got %#v", summary.MediaTermination)
	}
	if summary.MediaFramesToViewer != 1 || summary.MediaFramesToWorker != 1 {
		t.Fatalf("expected one frame in each relay direction, got viewer=%d worker=%d", summary.MediaFramesToViewer, summary.MediaFramesToWorker)
	}
	if summary.MediaBytesToViewer == 0 || summary.MediaBytesToWorker == 0 {
		t.Fatalf("expected byte counters in both relay directions, got viewer=%d worker=%d", summary.MediaBytesToViewer, summary.MediaBytesToWorker)
	}
}

func TestCreateSessionRejectsDirectWorkerPublicEndpointExposure(t *testing.T) {
	svc := NewService(Config{
		Region:              "us-west-2",
		GatewayID:           "gateway-us-west-2-01",
		PublicBaseURL:       "https://gateway.example.com",
		PublicWsURL:         "wss://gateway.example.com/ws",
		SupportedTransports: []string{"webtransport", "websocket"},
		PreferredTransport:  "webtransport",
		RelayMode:           "gateway-relay",
	})

	requestBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:     "sess_worker_exposure",
		TenantID:      "tenant-a",
		ViewerToken:   "viewer-token-worker-exposure",
		WorkerToken:   "worker-token-worker-exposure",
		PublicBaseURL: "https://worker-us-west-2-001.example.com",
		PublicWsURL:   "wss://worker-us-west-2-001.example.com/ws",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(requestBody))
	svc.Handler().ServeHTTP(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected status %d, got %d: %s", http.StatusBadRequest, recorder.Code, recorder.Body.String())
	}

	summaryResponse := httptest.NewRecorder()
	summaryRequest := httptest.NewRequest(http.MethodGet, "/v1/summary", nil)
	svc.Handler().ServeHTTP(summaryResponse, summaryRequest)
	if summaryResponse.Code != http.StatusOK {
		t.Fatalf("expected summary status %d, got %d: %s", http.StatusOK, summaryResponse.Code, summaryResponse.Body.String())
	}

	var summary SummaryResponse
	if err := json.NewDecoder(summaryResponse.Body).Decode(&summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.Admission.RejectionsByReason["direct-worker-public-endpoint"] != 1 {
		t.Fatalf("expected direct worker exposure rejection, got %#v", summary.Admission.RejectionsByReason)
	}
	if summary.MediaTermination.RelayModeAcceptance.RejectedDirectWorkerExposure != 1 {
		t.Fatalf("expected relay acceptance to count direct worker exposure rejection, got %#v", summary.MediaTermination.RelayModeAcceptance)
	}
}

func TestGatewayViewerEntrySetsCookieAndViewerProxyPassesThrough(t *testing.T) {
	var proxiedPath string
	var proxiedCookie string

	runtime := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		proxiedPath = r.URL.RequestURI()
		proxiedCookie = r.Header.Get("Cookie")
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = io.WriteString(w, `{"ok":true}`)
	}))
	defer runtime.Close()

	svc := NewService(Config{
		Region:               "us-west-2",
		GatewayID:            "gateway-us-west-2-01",
		PublicBaseURL:        "https://gateway.example.com",
		PublicWsURL:          "wss://gateway.example.com/ws",
		SupportedTransports:  []string{"websocket"},
		PreferredTransport:   "websocket",
		RelayMode:            "gateway-relay",
		RuntimeNotifyBaseURL: runtime.URL,
	})

	createBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:       "sess_proxy",
		TenantID:        "tenant-a",
		ViewerEntryMode: "swg-handoff",
		ViewerToken:     "viewer-token-123",
		WorkerToken:     "worker-token-123",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	})

	createRecorder := httptest.NewRecorder()
	createRequest := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(createBody))
	svc.Handler().ServeHTTP(createRecorder, createRequest)
	if createRecorder.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d: %s", http.StatusCreated, createRecorder.Code, createRecorder.Body.String())
	}

	var createResp contracts.MediaGatewaySessionResponse
	if err := json.NewDecoder(createRecorder.Body).Decode(&createResp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	viewerURL, err := url.Parse(createResp.Transport.ViewerURL)
	if err != nil {
		t.Fatalf("parse viewer url: %v", err)
	}

	entryRecorder := httptest.NewRecorder()
	entryRequest := httptest.NewRequest(http.MethodGet, viewerURL.RequestURI(), nil)
	svc.Handler().ServeHTTP(entryRecorder, entryRequest)
	if entryRecorder.Code != http.StatusSeeOther {
		t.Fatalf("expected status %d, got %d: %s", http.StatusSeeOther, entryRecorder.Code, entryRecorder.Body.String())
	}
	if got := entryRecorder.Header().Get("Location"); got != "/viewer?sessionId=sess_proxy" {
		t.Fatalf("unexpected redirect location %q", got)
	}
	cookies := entryRecorder.Header().Values("Set-Cookie")
	if len(cookies) < 2 {
		t.Fatalf("expected viewer cookies to be set, got %#v", cookies)
	}

	proxyRecorder := httptest.NewRecorder()
	proxyRequest := httptest.NewRequest(http.MethodGet, "/api/sessions/sess_proxy", nil)
	proxyRequest.Header.Set("Cookie", joinCookies(cookies))
	svc.Handler().ServeHTTP(proxyRecorder, proxyRequest)
	if proxyRecorder.Code != http.StatusOK {
		t.Fatalf("expected proxy status %d, got %d: %s", http.StatusOK, proxyRecorder.Code, proxyRecorder.Body.String())
	}
	if proxiedPath != "/api/sessions/sess_proxy" {
		t.Fatalf("expected proxied path /api/sessions/sess_proxy, got %q", proxiedPath)
	}
	if !strings.Contains(proxiedCookie, "rbi_viewer_sess_proxy=viewer-token-123") {
		t.Fatalf("expected proxied viewer cookie, got %q", proxiedCookie)
	}
}

func TestSummaryReportsSignalAndTransportState(t *testing.T) {
	svc := NewService(Config{
		Region:                     "us-west-2",
		GatewayID:                  "gateway-us-west-2-01",
		PublicBaseURL:              "https://gateway.example.com",
		PublicWsURL:                "wss://gateway.example.com/ws",
		SupportedTransports:        []string{"webtransport", "websocket"},
		PreferredTransport:         "webtransport",
		RelayMode:                  "gateway-relay",
		MaxActiveSessions:          5,
		MaxActiveSessionsPerTenant: 2,
		MaxActiveSessionsPerWorker: 1,
	})

	createBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:          "sess_summary",
		TenantID:           "tenant-a",
		ViewerEntryMode:    "swg-handoff",
		PreferredTransport: "websocket",
		ViewerToken:        "viewer-token-summary",
		WorkerToken:        "worker-token-summary",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-003",
		},
	})

	createRecorder := httptest.NewRecorder()
	createRequest := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(createBody))
	svc.Handler().ServeHTTP(createRecorder, createRequest)
	if createRecorder.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d: %s", http.StatusCreated, createRecorder.Code, createRecorder.Body.String())
	}

	svc.mu.Lock()
	svc.signals["sess_summary"] = &signalSessionState{
		viewer:                 &signalConnection{id: "viewer-1"},
		pendingWorker:          [][]byte{[]byte("offer"), []byte("ice")},
		viewerConnectEvents:    1,
		workerConnectEvents:    1,
		workerDisconnectEvents: 1,
		viewerHeartbeats:       3,
		viewerSignalMessages:   2,
		workerStateUpdates:     4,
		signalsToViewer:        5,
		signalsToWorker:        6,
		lastWorkerState:        "ready",
		lastViewerSeenAt:       time.Unix(1700000000, 0).UTC(),
		lastWorkerStateAt:      time.Unix(1700000001, 0).UTC(),
		lastSignalForwardedAt:  time.Unix(1700000002, 0).UTC(),
	}
	svc.mu.Unlock()

	recordResponse := httptest.NewRecorder()
	recordRequest := httptest.NewRequest(http.MethodGet, "/v1/sessions/sess_summary", nil)
	svc.Handler().ServeHTTP(recordResponse, recordRequest)
	if recordResponse.Code != http.StatusOK {
		t.Fatalf("expected GET status %d, got %d: %s", http.StatusOK, recordResponse.Code, recordResponse.Body.String())
	}

	var record SessionRecord
	if err := json.NewDecoder(recordResponse.Body).Decode(&record); err != nil {
		t.Fatalf("decode record: %v", err)
	}
	if record.SignalState == nil || !record.SignalState.ViewerConnected || record.SignalState.PendingWorkerSignals != 2 {
		t.Fatalf("unexpected signal state %#v", record.SignalState)
	}
	if record.SignalState.ViewerHeartbeats != 3 || record.SignalState.WorkerStateUpdates != 4 {
		t.Fatalf("unexpected signal telemetry %#v", record.SignalState)
	}
	if record.SignalState.LastWorkerState != "ready" {
		t.Fatalf("expected last worker state ready, got %#v", record.SignalState)
	}

	summaryResponse := httptest.NewRecorder()
	summaryRequest := httptest.NewRequest(http.MethodGet, "/v1/summary", nil)
	svc.Handler().ServeHTTP(summaryResponse, summaryRequest)
	if summaryResponse.Code != http.StatusOK {
		t.Fatalf("expected summary status %d, got %d: %s", http.StatusOK, summaryResponse.Code, summaryResponse.Body.String())
	}

	var summary SummaryResponse
	if err := json.NewDecoder(summaryResponse.Body).Decode(&summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.SessionsTotal != 1 || summary.SignalSessions != 1 {
		t.Fatalf("unexpected summary counts %#v", summary)
	}
	if summary.ActiveSessions != 1 {
		t.Fatalf("expected one active session, got %#v", summary)
	}
	if summary.ViewerConnected != 1 || summary.WorkerConnected != 0 {
		t.Fatalf("unexpected connection counts %#v", summary)
	}
	if summary.PendingWorkerSignals != 2 {
		t.Fatalf("unexpected pending worker signal count %#v", summary)
	}
	if summary.Transports["websocket"] != 1 {
		t.Fatalf("expected websocket transport count, got %#v", summary.Transports)
	}
	if summary.MediaTermination.DefaultCapability.GatewayTerminatesMedia {
		t.Fatalf("default capability must not claim gateway media termination: %#v", summary.MediaTermination)
	}
	if summary.MediaTermination.SessionsByMode[mediaTerminationModeSignalingRelay] != 1 {
		t.Fatalf("expected signaling-relay-only media termination count, got %#v", summary.MediaTermination)
	}
	if summary.MediaTermination.SessionsWithoutGatewayTerminatedMedia != 1 || summary.MediaTermination.SessionsWithGatewayTerminatedMedia != 0 {
		t.Fatalf("unexpected media termination session counts %#v", summary.MediaTermination)
	}
	if summary.MediaTermination.Wave2AcceptanceComplete {
		t.Fatalf("Wave 2 media termination must not be marked complete: %#v", summary.MediaTermination)
	}
	if summary.MediaTermination.RelayModeAcceptance.AcceptedMode != relayModeGatewayRelay {
		t.Fatalf("expected accepted relay mode %q, got %#v", relayModeGatewayRelay, summary.MediaTermination.RelayModeAcceptance)
	}
	if summary.MediaTermination.RelayModeAcceptance.AcceptanceState != relayModeAcceptanceStateAccepted {
		t.Fatalf("expected accepted relay mode state, got %#v", summary.MediaTermination.RelayModeAcceptance)
	}
	if summary.MediaTermination.RelayModeAcceptance.AcceptedSessions != 1 {
		t.Fatalf("expected one accepted relay-mode session, got %#v", summary.MediaTermination.RelayModeAcceptance)
	}
	if summary.MediaTermination.RelayModeAcceptance.Wave2MediaTerminationState != mediaTerminationStatusIncomplete {
		t.Fatalf("expected incomplete media termination state, got %#v", summary.MediaTermination.RelayModeAcceptance)
	}
	if summary.ActiveSessionsByTenant["tenant-a"] != 1 {
		t.Fatalf("expected tenant-a active session count, got %#v", summary.ActiveSessionsByTenant)
	}
	if summary.ActiveSessionsByWorker["worker-us-west-2-003"] != 1 {
		t.Fatalf("expected worker active session count, got %#v", summary.ActiveSessionsByWorker)
	}
	if summary.ViewerHeartbeats != 3 || summary.ViewerSignalMessages != 2 || summary.WorkerStateUpdates != 4 {
		t.Fatalf("unexpected signal activity counts %#v", summary)
	}
	if summary.SignalsToViewer != 5 || summary.SignalsToWorker != 6 {
		t.Fatalf("unexpected forwarded signal counts %#v", summary)
	}
	if summary.Admission.Attempts != 1 || summary.Admission.Accepted != 1 {
		t.Fatalf("unexpected admission summary %#v", summary.Admission)
	}
	if summary.Admission.Quotas.MaxActiveSessionsPerWorker != 1 {
		t.Fatalf("expected quota config in summary, got %#v", summary.Admission.Quotas)
	}
	if summary.Admission.LastDecision == nil || !summary.Admission.LastDecision.Admitted {
		t.Fatalf("expected admitted last decision, got %#v", summary.Admission.LastDecision)
	}
}

func TestCreateSessionRejectsQuotaAndReportsAdmissionSummary(t *testing.T) {
	svc := NewService(Config{
		Region:                     "us-west-2",
		GatewayID:                  "gateway-us-west-2-01",
		PublicBaseURL:              "https://gateway.example.com",
		PublicWsURL:                "wss://gateway.example.com/ws",
		SupportedTransports:        []string{"webtransport", "websocket"},
		PreferredTransport:         "webtransport",
		RelayMode:                  "gateway-relay",
		MaxActiveSessions:          1,
		MaxActiveSessionsPerTenant: 1,
		MaxActiveSessionsPerWorker: 1,
	})

	firstBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_a",
		TenantID:    "tenant-a",
		ViewerToken: "viewer-token-a",
		WorkerToken: "worker-token-a",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	})
	firstRecorder := httptest.NewRecorder()
	firstRequest := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(firstBody))
	svc.Handler().ServeHTTP(firstRecorder, firstRequest)
	if firstRecorder.Code != http.StatusCreated {
		t.Fatalf("expected create status %d, got %d: %s", http.StatusCreated, firstRecorder.Code, firstRecorder.Body.String())
	}

	secondBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_b",
		TenantID:    "tenant-a",
		ViewerToken: "viewer-token-b",
		WorkerToken: "worker-token-b",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-002",
		},
	})
	secondRecorder := httptest.NewRecorder()
	secondRequest := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(secondBody))
	svc.Handler().ServeHTTP(secondRecorder, secondRequest)
	if secondRecorder.Code != http.StatusTooManyRequests {
		t.Fatalf("expected rejection status %d, got %d: %s", http.StatusTooManyRequests, secondRecorder.Code, secondRecorder.Body.String())
	}

	summaryResponse := httptest.NewRecorder()
	summaryRequest := httptest.NewRequest(http.MethodGet, "/v1/summary", nil)
	svc.Handler().ServeHTTP(summaryResponse, summaryRequest)
	if summaryResponse.Code != http.StatusOK {
		t.Fatalf("expected summary status %d, got %d: %s", http.StatusOK, summaryResponse.Code, summaryResponse.Body.String())
	}

	var summary SummaryResponse
	if err := json.NewDecoder(summaryResponse.Body).Decode(&summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.Admission.Attempts != 2 || summary.Admission.Accepted != 1 || summary.Admission.Rejected != 1 {
		t.Fatalf("unexpected admission totals %#v", summary.Admission)
	}
	if summary.Admission.RejectionsByReason["active-sessions-quota-exceeded"] != 1 {
		t.Fatalf("expected active session rejection count, got %#v", summary.Admission.RejectionsByReason)
	}
	if summary.Admission.LastDecision == nil || summary.Admission.LastDecision.ReasonCode != "active-sessions-quota-exceeded" {
		t.Fatalf("expected last decision to report quota rejection, got %#v", summary.Admission.LastDecision)
	}
}

func TestCreateSessionRejectsConflictingReplay(t *testing.T) {
	svc := NewService(Config{
		Region:              "us-west-2",
		GatewayID:           "gateway-us-west-2-01",
		PublicBaseURL:       "https://gateway.example.com",
		PublicWsURL:         "wss://gateway.example.com/ws",
		SupportedTransports: []string{"webtransport", "websocket"},
		PreferredTransport:  "webtransport",
		RelayMode:           "gateway-relay",
	})

	createBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_replay",
		TenantID:    "tenant-a",
		ViewerToken: "viewer-token-a",
		WorkerToken: "worker-token-a",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	})
	createRecorder := httptest.NewRecorder()
	createRequest := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(createBody))
	svc.Handler().ServeHTTP(createRecorder, createRequest)
	if createRecorder.Code != http.StatusCreated {
		t.Fatalf("expected create status %d, got %d: %s", http.StatusCreated, createRecorder.Code, createRecorder.Body.String())
	}

	conflictBody := marshalJSON(t, contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_replay",
		TenantID:    "tenant-a",
		ViewerToken: "viewer-token-b",
		WorkerToken: "worker-token-a",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-us-west-2-001",
		},
	})
	conflictRecorder := httptest.NewRecorder()
	conflictRequest := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(conflictBody))
	svc.Handler().ServeHTTP(conflictRecorder, conflictRequest)
	if conflictRecorder.Code != http.StatusConflict {
		t.Fatalf("expected conflict status %d, got %d: %s", http.StatusConflict, conflictRecorder.Code, conflictRecorder.Body.String())
	}

	summaryResponse := httptest.NewRecorder()
	summaryRequest := httptest.NewRequest(http.MethodGet, "/v1/summary", nil)
	svc.Handler().ServeHTTP(summaryResponse, summaryRequest)
	if summaryResponse.Code != http.StatusOK {
		t.Fatalf("expected summary status %d, got %d: %s", http.StatusOK, summaryResponse.Code, summaryResponse.Body.String())
	}

	var summary SummaryResponse
	if err := json.NewDecoder(summaryResponse.Body).Decode(&summary); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if summary.Admission.RejectionsByReason["session-id-conflict"] != 1 {
		t.Fatalf("expected replay conflict admission count, got %#v", summary.Admission.RejectionsByReason)
	}
}

func TestGetSessionFallsBackToSharedGatewayStore(t *testing.T) {
	record := newStoredGatewayMediaRecord(t, "sess_shared_store")
	store := &fakeGatewaySessionStore{
		record: record,
		owner:  gatewayInstance{ID: "remote-owner", BaseURL: "http://10.0.0.10:18082"},
		ok:     true,
	}
	svc := NewService(Config{})
	svc.sessionStore = store

	got, ok := svc.GetSession("sess_shared_store")
	if !ok {
		t.Fatal("expected shared-store session to be returned")
	}
	if got.Request.SessionID != "sess_shared_store" || got.Response.Transport.MediaPlaneMode != mediaPlaneModeGatewayWebRTCRelay {
		t.Fatalf("unexpected shared-store record: %#v", got)
	}
}

func TestCreateSessionPersistsGatewayOwnerInSharedStore(t *testing.T) {
	store := &fakeGatewaySessionStore{}
	svc := NewService(Config{
		Region:              "us-west-2",
		GatewayID:           "gateway-us-west-2-01",
		PublicBaseURL:       "https://gateway.example.com",
		PublicWsURL:         "wss://gateway.example.com/ws",
		SupportedTransports: []string{"webrtc"},
		PreferredTransport:  "webrtc",
		RelayMode:           relayModeGatewayMediaRelay,
		EnableMediaRelay:    true,
		InstanceID:          "owner-a",
		InstanceBaseURL:     "http://10.0.0.7:18082",
	})
	svc.sessionStore = store

	resp, status, err := svc.CreateSession(contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_owner_store",
		TenantID:    "tenant-a",
		ViewerToken: "viewer-token",
		WorkerToken: "worker-token",
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
			RelayMode: relayModeGatewayMediaRelay,
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-a",
		},
	})
	if err != nil || status != http.StatusCreated {
		t.Fatalf("create session failed status=%d err=%v", status, err)
	}
	if store.savedRecord.Request.SessionID != "sess_owner_store" {
		t.Fatalf("expected saved session, got %#v", store.savedRecord)
	}
	if store.savedOwner.ID != "owner-a" || store.savedOwner.BaseURL != "http://10.0.0.7:18082" {
		t.Fatalf("expected local owner to be stored, got %#v", store.savedOwner)
	}
	if resp.Transport.MediaGatewayURL == "" || resp.WorkerBridge.MediaGatewayURL == "" {
		t.Fatalf("expected gateway webrtc URLs, got %#v", resp)
	}
}

func TestWebRTCRelayOfferProxiesToStoredOwner(t *testing.T) {
	record := newStoredGatewayMediaRecord(t, "sess_remote_owner")
	var capturedPath string
	var capturedBody string
	owner := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedPath = r.URL.Path
		body, _ := io.ReadAll(r.Body)
		capturedBody = string(body)
		if r.Header.Get(gatewayForwardedHeader) != "1" {
			t.Errorf("expected forwarded header")
		}
		httpx.WriteJSON(w, http.StatusOK, map[string]any{
			"type":      "answer",
			"sdp":       "v=0\r\n",
			"sessionId": "sess_remote_owner",
			"role":      "worker",
			"proxied":   true,
		})
	}))
	defer owner.Close()

	svc := NewService(Config{
		InstanceID:            "local-owner",
		InstanceBaseURL:       "http://10.0.0.11:18082",
		ForwardRequestTimeout: time.Second,
	})
	svc.sessionStore = &fakeGatewaySessionStore{
		record: record,
		owner:  gatewayInstance{ID: "remote-owner", BaseURL: owner.URL},
		ok:     true,
	}

	offerBody := marshalJSON(t, map[string]any{
		"type":  "offer",
		"token": record.Request.WorkerToken,
		"sdp":   "v=0\r\na=rtpmap:96 VP8/90000\r\n",
	})
	response := httptest.NewRecorder()
	svc.Handler().ServeHTTP(
		response,
		httptest.NewRequest(http.MethodPost, "/gateway/webrtc/sess_remote_owner/worker/offer", bytes.NewReader(offerBody)),
	)
	if response.Code != http.StatusOK {
		t.Fatalf("expected proxied status %d, got %d: %s", http.StatusOK, response.Code, response.Body.String())
	}
	if capturedPath != "/gateway/webrtc/sess_remote_owner/worker/offer" {
		t.Fatalf("expected owner path to be preserved, got %q", capturedPath)
	}
	if !strings.Contains(capturedBody, record.Request.WorkerToken) {
		t.Fatalf("expected original body to be forwarded, got %q", capturedBody)
	}
	if !strings.Contains(response.Body.String(), `"proxied":true`) {
		t.Fatalf("expected owner response body, got %s", response.Body.String())
	}
}

func TestTerminateSessionProxiesToStoredOwner(t *testing.T) {
	record := newStoredGatewayMediaRecord(t, "sess_remote_terminate")
	var capturedPath string
	owner := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedPath = r.URL.Path
		if r.Header.Get(gatewayForwardedHeader) != "1" {
			t.Errorf("expected forwarded header")
		}
		httpx.WriteJSON(w, http.StatusOK, map[string]any{
			"sessionId": "sess_remote_terminate",
			"state":     "terminated",
		})
	}))
	defer owner.Close()

	svc := NewService(Config{
		InstanceID:            "local-owner",
		InstanceBaseURL:       "http://10.0.0.12:18082",
		ForwardRequestTimeout: time.Second,
	})
	svc.sessionStore = &fakeGatewaySessionStore{
		record: record,
		owner:  gatewayInstance{ID: "remote-owner", BaseURL: owner.URL},
		ok:     true,
	}

	response := httptest.NewRecorder()
	body := marshalJSON(t, terminateRequest{Reason: "runtime-ended"})
	request := httptest.NewRequest(http.MethodPost, "/v1/sessions/sess_remote_terminate/terminate", bytes.NewReader(body))
	svc.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("expected proxied terminate status %d, got %d: %s", http.StatusOK, response.Code, response.Body.String())
	}
	if capturedPath != "/v1/sessions/sess_remote_terminate/terminate" {
		t.Fatalf("expected owner terminate path, got %q", capturedPath)
	}
}

type fakeGatewaySessionStore struct {
	record      SessionRecord
	owner       gatewayInstance
	ok          bool
	savedRecord SessionRecord
	savedOwner  gatewayInstance
	deletedID   string
}

func (s *fakeGatewaySessionStore) SaveSession(_ context.Context, record SessionRecord, owner gatewayInstance) error {
	s.savedRecord = record
	s.savedOwner = owner
	s.record = record
	s.owner = owner
	s.ok = true
	return nil
}

func (s *fakeGatewaySessionStore) GetSession(_ context.Context, sessionID string) (SessionRecord, gatewayInstance, bool, error) {
	if !s.ok || s.record.Request.SessionID != sessionID {
		return SessionRecord{}, gatewayInstance{}, false, nil
	}
	return s.record, s.owner, true, nil
}

func (s *fakeGatewaySessionStore) DeleteSession(_ context.Context, sessionID string) error {
	s.deletedID = sessionID
	s.ok = false
	return nil
}

func newStoredGatewayMediaRecord(t *testing.T, sessionID string) SessionRecord {
	t.Helper()

	svc := NewService(Config{
		Region:              "us-west-2",
		GatewayID:           "gateway-us-west-2-01",
		PublicBaseURL:       "https://gateway.example.com",
		PublicWsURL:         "wss://gateway.example.com/ws",
		WorkerBaseURL:       "http://media-gateway.cloudsec-rbi-media.svc.cluster.local:18082",
		WorkerWsURL:         "ws://media-gateway.cloudsec-rbi-media.svc.cluster.local:18082",
		SupportedTransports: []string{"webrtc"},
		PreferredTransport:  "webrtc",
		RelayMode:           relayModeGatewayMediaRelay,
		EnableMediaRelay:    true,
	})
	_, status, err := svc.CreateSession(contracts.MediaGatewaySessionRequest{
		SessionID:   sessionID,
		TenantID:    "tenant-a",
		ViewerToken: "viewer-token-" + sessionID,
		WorkerToken: "worker-token-" + sessionID,
		GatewayAssignment: contracts.GatewayAssignment{
			GatewayID: "gateway-us-west-2-01",
			Region:    "us-west-2",
			RelayMode: relayModeGatewayMediaRelay,
		},
		WorkerAssignment: contracts.WorkerAssignment{
			WorkerID: "worker-" + sessionID,
		},
	})
	if err != nil || status != http.StatusCreated {
		t.Fatalf("create stored gateway session failed status=%d err=%v", status, err)
	}
	record, ok := svc.GetSession(sessionID)
	if !ok {
		t.Fatalf("created session %q not found", sessionID)
	}
	return record
}

func joinCookies(values []string) string {
	parts := make([]string, 0, len(values))
	for _, value := range values {
		parts = append(parts, strings.SplitN(value, ";", 2)[0])
	}
	return strings.Join(parts, "; ")
}

func marshalJSON(t *testing.T, value any) []byte {
	t.Helper()

	body, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal json: %v", err)
	}
	return body
}

func newTestViewerOfferSDP(t *testing.T) string {
	t.Helper()

	mediaEngine := &webrtc.MediaEngine{}
	if err := mediaEngine.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:     webrtc.MimeTypeVP8,
			ClockRate:    90000,
			RTCPFeedback: videoRTCPFeedback(),
		},
		PayloadType: 96,
	}, webrtc.RTPCodecTypeVideo); err != nil {
		t.Fatalf("register VP8 codec: %v", err)
	}
	if err := mediaEngine.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeOpus,
			ClockRate:   48000,
			Channels:    2,
			SDPFmtpLine: "minptime=10;useinbandfec=1",
		},
		PayloadType: 111,
	}, webrtc.RTPCodecTypeAudio); err != nil {
		t.Fatalf("register Opus codec: %v", err)
	}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(mediaEngine))
	pc, err := api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatalf("new peer connection: %v", err)
	}
	t.Cleanup(func() {
		_ = pc.Close()
	})
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		t.Fatalf("add video transceiver: %v", err)
	}
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		t.Fatalf("add audio transceiver: %v", err)
	}
	gatherComplete := webrtc.GatheringCompletePromise(pc)
	offer, err := pc.CreateOffer(nil)
	if err != nil {
		t.Fatalf("create offer: %v", err)
	}
	if err := pc.SetLocalDescription(offer); err != nil {
		t.Fatalf("set local description: %v", err)
	}
	select {
	case <-gatherComplete:
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out gathering test offer ICE")
	}
	return pc.LocalDescription().SDP
}

func dialTestWebSocket(t *testing.T, rawURL string) *websocketConn {
	t.Helper()

	parsed, err := url.Parse(rawURL)
	if err != nil {
		t.Fatalf("parse websocket URL %q: %v", rawURL, err)
	}
	conn, err := net.Dial("tcp", parsed.Host)
	if err != nil {
		t.Fatalf("dial websocket %q: %v", parsed.Host, err)
	}

	keyBytes := make([]byte, 16)
	if _, err := rand.Read(keyBytes); err != nil {
		_ = conn.Close()
		t.Fatalf("generate websocket key: %v", err)
	}
	key := base64.StdEncoding.EncodeToString(keyBytes)
	path := parsed.RequestURI()
	if path == "" {
		path = "/"
	}

	request := strings.Join([]string{
		"GET " + path + " HTTP/1.1",
		"Host: " + parsed.Host,
		"Upgrade: websocket",
		"Connection: Upgrade",
		"Sec-WebSocket-Key: " + key,
		"Sec-WebSocket-Version: 13",
		"",
		"",
	}, "\r\n")
	if _, err := io.WriteString(conn, request); err != nil {
		_ = conn.Close()
		t.Fatalf("write websocket upgrade: %v", err)
	}

	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, nil)
	if err != nil {
		_ = conn.Close()
		t.Fatalf("read websocket upgrade response: %v", err)
	}
	if response.StatusCode != http.StatusSwitchingProtocols {
		_ = conn.Close()
		t.Fatalf("expected websocket upgrade status %d, got %d", http.StatusSwitchingProtocols, response.StatusCode)
	}

	return &websocketConn{
		conn:   conn,
		reader: reader,
	}
}

func writeTestWebSocketJSON(t *testing.T, ws *websocketConn, payload any) {
	t.Helper()
	if err := ws.WriteJSON(payload); err != nil {
		t.Fatalf("write websocket JSON: %v", err)
	}
}

func readTestWebSocketJSON(t *testing.T, ws *websocketConn) map[string]any {
	t.Helper()
	payload, err := ws.ReadText()
	if err != nil {
		t.Fatalf("read websocket JSON: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("decode websocket payload %q: %v", string(payload), err)
	}
	return decoded
}

func assertTestWebSocketMessageType(t *testing.T, ws *websocketConn, messageType string) {
	t.Helper()
	message := readTestWebSocketJSON(t, ws)
	if message["type"] != messageType {
		t.Fatalf("expected websocket message type %q, got %#v", messageType, message)
	}
}

func assertTestWebSocketJSON(t *testing.T, ws *websocketConn, expected map[string]any) {
	t.Helper()
	actual := readTestWebSocketJSON(t, ws)
	if !jsonMapsEqual(actual, expected) {
		t.Fatalf("expected websocket payload %#v, got %#v", expected, actual)
	}
}

func jsonMapsEqual(actual map[string]any, expected map[string]any) bool {
	actualBody, err := json.Marshal(actual)
	if err != nil {
		return false
	}
	expectedBody, err := json.Marshal(expected)
	if err != nil {
		return false
	}
	return string(actualBody) == string(expectedBody)
}
