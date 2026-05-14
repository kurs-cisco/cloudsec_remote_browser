package sessionauthority

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"cloudsec_remote_browser/services/internal/contracts"
)

func TestDefaultConfigUsesGatewayMediaRelay(t *testing.T) {
	t.Setenv("SESSION_AUTHORITY_RELAY_MODE", "")

	cfg := LoadConfigFromEnv()
	if cfg.RelayMode != "gateway-media-relay" {
		t.Fatalf("expected default relay mode gateway-media-relay, got %q", cfg.RelayMode)
	}

	svc := NewService(Config{})
	if svc.cfg.RelayMode != "gateway-media-relay" {
		t.Fatalf("expected zero-value service relay mode gateway-media-relay, got %q", svc.cfg.RelayMode)
	}
}

func TestBootstrapCreatesLocalAssignments(t *testing.T) {
	svc := NewServiceWithClient(Config{
		DefaultRegion:        "us-east-1",
		Regions:              []string{"us-east-1", "us-west-2"},
		TenantRegions:        map[string]string{"tenant-a": "us-west-2"},
		HandoffBaseURL:       "https://edge.example.com",
		GatewayPublicBaseURL: "https://gateway.example.com",
		GatewayPublicWsURL:   "wss://gateway.example.com/ws",
		ViewerEntryMode:      "swg-handoff",
		RelayMode:            "gateway-relay",
		RuntimeClass:         "kata-clh",
		NodePool:             "rbi-workers",
	}, nil)

	body := marshalJSON(t, contracts.EdgeBootstrapRequest{
		TransactionID:    "tx-123",
		TargetURL:        "https://example.com/",
		OrgID:            "tenant-a",
		BoundaryType:     "org",
		BoundaryID:       "tenant-a",
		OriginID:         "origin-a",
		OriginType:       "64",
		TenantID:         "tenant-a",
		ProfileID:        "profile-1",
		Policy:           "strict",
		ContractVersion:  "v2",
		RequestKind:      "https-decrypted-document",
		OriginalMethod:   "GET",
		Provider:         "in_house",
		ProviderCategory: "cat-b",
		FallbackProvider: "fail_closed",
		Nonce:            "nonce-123",
		KeyID:            "key-1",
		UpstreamHost:     "example.com",
		UpstreamScheme:   "https",
		UpstreamPort:     "443",
		Viewport: &contracts.Viewport{
			Width:             1440,
			Height:            900,
			DeviceScaleFactor: 1,
		},
		Client: map[string]any{
			"browser": "cloudsec-swg",
			"source":  "zeus",
		},
		Experiments: map[string]any{
			"sourceCoupledAv": true,
		},
		PublicBaseURL: "https://public.example.com",
		PublicWsURL:   "wss://public.example.com/ws",
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/bootstrap", bytes.NewReader(body))
	svc.Handler().ServeHTTP(recorder, request)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d: %s", http.StatusCreated, recorder.Code, recorder.Body.String())
	}

	var resp contracts.EdgeBootstrapResponse
	if err := json.NewDecoder(recorder.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if resp.SessionID == "" {
		t.Fatal("expected sessionId to be set")
	}
	if resp.ViewerEntry != "swg-handoff" {
		t.Fatalf("expected viewerEntryMode swg-handoff, got %q", resp.ViewerEntry)
	}
	if !strings.HasPrefix(resp.HandoffURL, "https://public.example.com/swg/handoff?token=") {
		t.Fatalf("unexpected handoffUrl %q", resp.HandoffURL)
	}
	if resp.GatewayAssignment == nil || resp.GatewayAssignment.Region != "us-west-2" {
		t.Fatalf("expected us-west-2 gateway assignment, got %#v", resp.GatewayAssignment)
	}
	if resp.GatewayAssignment.SessionID != resp.SessionID {
		t.Fatalf("expected gateway assignment sessionId %q, got %q", resp.SessionID, resp.GatewayAssignment.SessionID)
	}
	if resp.WorkerAssignment == nil || resp.WorkerAssignment.RuntimeClass != "kata-clh" {
		t.Fatalf("unexpected worker assignment %#v", resp.WorkerAssignment)
	}
	if resp.WorkerAssignment.SessionID != resp.SessionID {
		t.Fatalf("expected worker assignment sessionId %q, got %q", resp.SessionID, resp.WorkerAssignment.SessionID)
	}

	recordResponse := httptest.NewRecorder()
	recordRequest := httptest.NewRequest(http.MethodGet, "/v1/sessions/"+resp.SessionID, nil)
	svc.Handler().ServeHTTP(recordResponse, recordRequest)
	if recordResponse.Code != http.StatusOK {
		t.Fatalf("expected GET status %d, got %d", http.StatusOK, recordResponse.Code)
	}

	var record SessionRecord
	if err := json.NewDecoder(recordResponse.Body).Decode(&record); err != nil {
		t.Fatalf("decode record: %v", err)
	}
	if record.Source != "local" {
		t.Fatalf("expected local source, got %q", record.Source)
	}
}

func TestBootstrapDelegatesPlacementToRuntime(t *testing.T) {
	var captured contracts.RuntimeSessionRequest
	var capturedUpdate contracts.RuntimeSessionUpdateRequest
	var capturedGateway contracts.MediaGatewaySessionRequest

	runtime := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("X-RBI-Internal-Secret"); got != "shared-secret" {
			t.Fatalf("expected secret header, got %q", got)
		}
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/api/internal/sessions":
			if err := json.NewDecoder(r.Body).Decode(&captured); err != nil {
				t.Fatalf("decode runtime request: %v", err)
			}
			_ = json.NewEncoder(w).Encode(contracts.RuntimeSessionResponse{
				SessionID:            "sess_runtime",
				HandoffURL:           "https://runtime.example.com/swg/handoff?token=abc123",
				ViewerEntry:          "swg-handoff",
				ViewerSignalingToken: "viewer-signal-token",
				ViewerToken:          "viewer-cookie-token",
				WorkerToken:          "worker-token",
				Generation:           3,
			})
		case r.Method == http.MethodPatch && r.URL.Path == "/api/internal/sessions/sess_runtime":
			if err := json.NewDecoder(r.Body).Decode(&capturedUpdate); err != nil {
				t.Fatalf("decode runtime update request: %v", err)
			}
			_ = json.NewEncoder(w).Encode(contracts.RuntimeSessionResponse{
				SessionID: "sess_runtime",
				GatewayAssignment: &contracts.GatewayAssignment{
					SessionID:     "sess_runtime",
					GatewayID:     "gateway-us-east-1-01",
					Region:        "us-east-1",
					WorkerID:      "worker-us-east-1-001",
					RelayMode:     "gateway-relay",
					PublicBaseURL: "https://gateway.example.com",
					PublicWsURL:   "wss://gateway.example.com/ws",
				},
				WorkerAssignment: &contracts.WorkerAssignment{
					SessionID:        "sess_runtime",
					WorkerID:         "worker-us-east-1-001",
					Region:           "us-east-1",
					RuntimeClass:     "kata-clh",
					NodePool:         "rbi-workers",
					AvailabilityZone: "us-east-1a",
				},
				Transport: &contracts.GatewayTransport{
					Preferred:    "webrtc",
					Supported:    []string{"webrtc", "websocket"},
					ViewerURL:    "https://gateway.example.com/gateway/viewer/sess_runtime?transport=webrtc",
					SignalingURL: "wss://gateway.example.com/gateway/signaling/sess_runtime/viewer?transport=webrtc",
				},
				WorkerBridge: &contracts.WorkerBridge{
					BridgeID:  "bridge-sess_runtime",
					RelayMode: "gateway-relay",
				},
			})
		default:
			t.Fatalf("unexpected runtime request %s %q", r.Method, r.URL.Path)
		}
	}))
	defer runtime.Close()

	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/sessions" {
			t.Fatalf("unexpected gateway path %q", r.URL.Path)
		}
		if got := r.Header.Get("X-RBI-Internal-Secret"); got != "shared-secret" {
			t.Fatalf("expected gateway secret header, got %q", got)
		}
		if err := json.NewDecoder(r.Body).Decode(&capturedGateway); err != nil {
			t.Fatalf("decode gateway request: %v", err)
		}
		_ = json.NewEncoder(w).Encode(contracts.MediaGatewaySessionResponse{
			SessionID:       "sess_runtime",
			ViewerEntryMode: "swg-handoff",
			GatewayAssignment: contracts.GatewayAssignment{
				SessionID:     "sess_runtime",
				GatewayID:     "gateway-us-east-1-01",
				Region:        "us-east-1",
				WorkerID:      "worker-us-east-1-001",
				RelayMode:     "gateway-relay",
				PublicBaseURL: "https://gateway.example.com",
				PublicWsURL:   "wss://gateway.example.com/ws",
			},
			WorkerAssignment: contracts.WorkerAssignment{
				SessionID:        "sess_runtime",
				WorkerID:         "worker-us-east-1-001",
				Region:           "us-east-1",
				RuntimeClass:     "kata-clh",
				NodePool:         "rbi-workers",
				AvailabilityZone: "us-east-1a",
			},
			Transport: contracts.GatewayTransport{
				Preferred:    "webrtc",
				Supported:    []string{"webrtc", "websocket"},
				ViewerURL:    "https://gateway.example.com/gateway/viewer/sess_runtime?transport=webrtc",
				SignalingURL: "wss://gateway.example.com/gateway/signaling/sess_runtime/viewer?transport=webrtc",
			},
			WorkerBridge: contracts.WorkerBridge{
				BridgeID:  "bridge-sess_runtime",
				RelayMode: "gateway-relay",
			},
		})
	}))
	defer gateway.Close()

	svc := NewService(Config{
		DefaultRegion:              "us-east-1",
		Regions:                    []string{"us-east-1"},
		HandoffBaseURL:             "https://edge.example.com",
		GatewayPublicBaseURL:       "https://gateway.example.com",
		GatewayPublicWsURL:         "wss://gateway.example.com/ws",
		ViewerEntryMode:            "swg-handoff",
		RelayMode:                  "gateway-relay",
		RuntimeClass:               "kata-clh",
		NodePool:                   "rbi-workers",
		InternalSharedSecret:       "shared-secret",
		RuntimeBaseURL:             runtime.URL,
		RuntimeSharedSecret:        "shared-secret",
		RuntimeRequestTimeout:      2 * time.Second,
		MediaGatewayBaseURL:        gateway.URL,
		MediaGatewayRequestTimeout: 2 * time.Second,
	})

	body := marshalJSON(t, contracts.EdgeBootstrapRequest{
		TransactionID:    "tx-runtime",
		TargetURL:        "https://example.com/path",
		OrgID:            "tenant-runtime",
		BoundaryType:     "org",
		BoundaryID:       "tenant-runtime",
		OriginID:         "origin-runtime",
		OriginType:       "64",
		TenantID:         "tenant-runtime",
		ProfileID:        "profile-runtime",
		Policy:           "policy-runtime",
		ContractVersion:  "v2",
		RequestKind:      "https-decrypted-document",
		OriginalMethod:   "GET",
		Provider:         "in_house",
		ProviderCategory: "cat-b",
		FallbackProvider: "fail_closed",
		Nonce:            "nonce-runtime",
		KeyID:            "key-runtime",
		UpstreamHost:     "example.com",
		UpstreamScheme:   "https",
		UpstreamPort:     "443",
		Client: map[string]any{
			"browser":  "cloudsec-swg",
			"identity": map[string]any{"principal": "user@example.com"},
		},
		Experiments: map[string]any{
			"sourceCoupledAv": false,
		},
		PublicBaseURL: "https://public.example.com",
		PublicWsURL:   "wss://public.example.com/ws",
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/bootstrap", bytes.NewReader(body))
	request.Header.Set("X-RBI-Internal-Secret", "shared-secret")
	svc.Handler().ServeHTTP(recorder, request)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d: %s", http.StatusCreated, recorder.Code, recorder.Body.String())
	}

	if captured.TargetURL != "https://example.com/path" {
		t.Fatalf("expected targetUrl to be forwarded, got %q", captured.TargetURL)
	}
	if captured.RequestContext["mode"] != "swg" {
		t.Fatalf("expected requestContext.mode swg, got %#v", captured.RequestContext["mode"])
	}
	if captured.SessionPlacement == nil || captured.SessionPlacement.GatewayAssignment == nil || captured.SessionPlacement.WorkerAssignment == nil {
		t.Fatalf("expected sessionPlacement to be sent, got %#v", captured.SessionPlacement)
	}
	if captured.SessionPlacement.GatewayAssignment.Region != "us-east-1" {
		t.Fatalf("expected gateway region us-east-1, got %q", captured.SessionPlacement.GatewayAssignment.Region)
	}
	if captured.SessionPlacement.WorkerAssignment.RuntimeClass != "kata-clh" {
		t.Fatalf("expected runtimeClass kata-clh, got %q", captured.SessionPlacement.WorkerAssignment.RuntimeClass)
	}
	if authMode := captured.Client["authMode"]; authMode != "swg" {
		t.Fatalf("expected client authMode swg, got %#v", authMode)
	}
	swg, ok := captured.Client["swg"].(map[string]any)
	if !ok {
		t.Fatalf("expected client.swg object, got %#v", captured.Client["swg"])
	}
	if swg["transactionId"] != "tx-runtime" {
		t.Fatalf("expected client.swg.transactionId tx-runtime, got %#v", swg["transactionId"])
	}
	if capturedGateway.SessionID != "sess_runtime" {
		t.Fatalf("expected gateway session id sess_runtime, got %q", capturedGateway.SessionID)
	}
	if capturedGateway.ViewerToken != "viewer-signal-token" {
		t.Fatalf("expected viewer token to be registered with gateway, got %q", capturedGateway.ViewerToken)
	}
	if capturedGateway.WorkerToken != "worker-token" {
		t.Fatalf("expected worker token to be registered with gateway, got %q", capturedGateway.WorkerToken)
	}
	if capturedGateway.Generation != 3 {
		t.Fatalf("expected generation 3, got %d", capturedGateway.Generation)
	}
	if capturedUpdate.SessionPlacement == nil || capturedUpdate.SessionPlacement.GatewayAssignment == nil {
		t.Fatalf("expected runtime update session placement, got %#v", capturedUpdate.SessionPlacement)
	}
	if capturedUpdate.Transport == nil || !strings.Contains(capturedUpdate.Transport.SignalingURL, "/gateway/signaling/sess_runtime/viewer") {
		t.Fatalf("expected runtime update transport, got %#v", capturedUpdate.Transport)
	}
	if capturedUpdate.WorkerBridge == nil || capturedUpdate.WorkerBridge.BridgeID == "" {
		t.Fatalf("expected runtime update worker bridge, got %#v", capturedUpdate.WorkerBridge)
	}

	var resp contracts.EdgeBootstrapResponse
	if err := json.NewDecoder(recorder.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.SessionID != "sess_runtime" {
		t.Fatalf("expected runtime session id, got %q", resp.SessionID)
	}
	if resp.GatewayAssignment == nil || resp.GatewayAssignment.SessionID != "sess_runtime" {
		t.Fatalf("expected gateway assignment to be rebound to runtime session id, got %#v", resp.GatewayAssignment)
	}
	if resp.WorkerAssignment == nil || resp.WorkerAssignment.SessionID != "sess_runtime" {
		t.Fatalf("expected worker assignment to be rebound to runtime session id, got %#v", resp.WorkerAssignment)
	}
	if resp.Transport == nil || !strings.Contains(resp.Transport.SignalingURL, "/gateway/signaling/sess_runtime/viewer") {
		t.Fatalf("expected gateway transport to be returned, got %#v", resp.Transport)
	}
	if resp.WorkerBridge == nil || resp.WorkerBridge.BridgeID == "" {
		t.Fatalf("expected worker bridge to be returned, got %#v", resp.WorkerBridge)
	}
}

func TestBootstrapPropagatesMediaRelayThroughRuntimeUpdate(t *testing.T) {
	var capturedGateway contracts.MediaGatewaySessionRequest
	var capturedUpdate contracts.RuntimeSessionUpdateRequest

	runtime := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/api/internal/sessions":
			_ = json.NewEncoder(w).Encode(contracts.RuntimeSessionResponse{
				SessionID:            "sess_media_runtime",
				ViewerEntry:          "swg-handoff",
				ViewerSignalingToken: "viewer-signal-token",
				WorkerToken:          "worker-token",
				Generation:           4,
				GatewayAssignment: &contracts.GatewayAssignment{
					SessionID: "sess_media_runtime",
					GatewayID: "gateway-us-east-1-01",
					Region:    "us-east-1",
					WorkerID:  "worker-us-east-1-001",
				},
			})
		case r.Method == http.MethodPatch && r.URL.Path == "/api/internal/sessions/sess_media_runtime":
			if err := json.NewDecoder(r.Body).Decode(&capturedUpdate); err != nil {
				t.Fatalf("decode runtime update request: %v", err)
			}
			_ = json.NewEncoder(w).Encode(contracts.RuntimeSessionResponse{
				SessionID: "sess_media_runtime",
				Transport: &contracts.GatewayTransport{
					Preferred: "websocket",
					Supported: []string{"websocket"},
					ViewerURL: "https://runtime.example.com/stale-viewer-url",
				},
				WorkerBridge: &contracts.WorkerBridge{
					BridgeID: "runtime-bridge",
				},
			})
		default:
			t.Fatalf("unexpected runtime request %s %q", r.Method, r.URL.Path)
		}
	}))
	defer runtime.Close()

	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/sessions" {
			t.Fatalf("unexpected gateway path %q", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&capturedGateway); err != nil {
			t.Fatalf("decode gateway request: %v", err)
		}
		_ = json.NewEncoder(w).Encode(validMediaRelayGatewayResponse())
	}))
	defer gateway.Close()

	svc := NewService(Config{
		DefaultRegion:              "us-east-1",
		Regions:                    []string{"us-east-1"},
		HandoffBaseURL:             "https://edge.example.com",
		GatewayPublicBaseURL:       "https://gateway.example.com",
		GatewayPublicWsURL:         "wss://gateway.example.com/ws",
		ViewerEntryMode:            "swg-handoff",
		RelayMode:                  "gateway-media-relay",
		RuntimeClass:               "kata-clh",
		NodePool:                   "rbi-workers",
		RuntimeBaseURL:             runtime.URL,
		RuntimeRequestTimeout:      2 * time.Second,
		MediaGatewayBaseURL:        gateway.URL,
		MediaGatewayRequestTimeout: 2 * time.Second,
	})

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/bootstrap", bytes.NewReader(marshalJSON(t, contracts.EdgeBootstrapRequest{
		TransactionID:    "tx-media-relay",
		TargetURL:        "https://example.com/media",
		OrgID:            "tenant-media",
		BoundaryType:     "org",
		BoundaryID:       "tenant-media",
		OriginID:         "origin-media",
		OriginType:       "64",
		TenantID:         "tenant-media",
		ProfileID:        "profile-media",
		Policy:           "policy-media",
		ContractVersion:  "v2",
		RequestKind:      "https-decrypted-document",
		OriginalMethod:   "GET",
		Provider:         "in_house",
		ProviderCategory: "cat-b",
		FallbackProvider: "fail_closed",
		Nonce:            "nonce-media",
		KeyID:            "key-media",
		UpstreamHost:     "example.com",
		UpstreamScheme:   "https",
		UpstreamPort:     "443",
	})))
	svc.Handler().ServeHTTP(recorder, request)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected status %d, got %d: %s", http.StatusCreated, recorder.Code, recorder.Body.String())
	}
	if capturedGateway.GatewayAssignment.RelayMode != "gateway-media-relay" {
		t.Fatalf("expected gateway-media-relay registration, got %#v", capturedGateway.GatewayAssignment)
	}
	if capturedUpdate.Transport == nil || !strings.Contains(capturedUpdate.Transport.MediaRelayURL, "/gateway/media/sess_media_runtime/viewer") {
		t.Fatalf("expected runtime update viewer media relay URL, got %#v", capturedUpdate.Transport)
	}
	if capturedUpdate.Transport.MediaTermination == nil || !capturedUpdate.Transport.MediaTermination.GatewayTerminatesMedia {
		t.Fatalf("expected runtime update media relay capability, got %#v", capturedUpdate.Transport)
	}
	if capturedUpdate.Transport.MediaGatewayURL == "" ||
		!strings.Contains(capturedUpdate.Transport.MediaGatewayURL, "/gateway/webrtc/sess_media_runtime/viewer") ||
		capturedUpdate.Transport.MediaPlaneMode != mediaPlaneModeGatewayWebRTCRelay ||
		capturedUpdate.Transport.Protocol != mediaTerminationProtocolWebRTCSRTP {
		t.Fatalf("expected runtime update WebRTC/SRTP viewer gateway contract, got %#v", capturedUpdate.Transport)
	}
	if capturedUpdate.WorkerBridge == nil || !strings.Contains(capturedUpdate.WorkerBridge.MediaRelayURL, "/gateway/media/sess_media_runtime/worker") {
		t.Fatalf("expected runtime update worker media relay URL, got %#v", capturedUpdate.WorkerBridge)
	}
	if capturedUpdate.WorkerBridge == nil ||
		!strings.Contains(capturedUpdate.WorkerBridge.MediaGatewayURL, "/gateway/webrtc/sess_media_runtime/worker") ||
		capturedUpdate.WorkerBridge.Protocol != mediaTerminationProtocolWebRTCSRTP {
		t.Fatalf("expected runtime update WebRTC/SRTP worker gateway contract, got %#v", capturedUpdate.WorkerBridge)
	}

	var resp contracts.EdgeBootstrapResponse
	if err := json.NewDecoder(recorder.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.GatewayAssignment == nil || resp.GatewayAssignment.RelayMode != "gateway-media-relay" {
		t.Fatalf("expected final gateway-media-relay assignment, got %#v", resp.GatewayAssignment)
	}
	if resp.Transport == nil || !strings.Contains(resp.Transport.MediaRelayURL, "/gateway/media/sess_media_runtime/viewer") {
		t.Fatalf("expected final viewer media relay URL, got %#v", resp.Transport)
	}
	if resp.Transport.MediaTermination == nil || !resp.Transport.MediaTermination.GatewayTerminatesMedia {
		t.Fatalf("expected final media relay capability, got %#v", resp.Transport)
	}
	if resp.Transport.MediaGatewayURL == "" ||
		!strings.Contains(resp.Transport.MediaGatewayURL, "/gateway/webrtc/sess_media_runtime/viewer") ||
		resp.Transport.MediaPlaneMode != mediaPlaneModeGatewayWebRTCRelay ||
		resp.Transport.Protocol != mediaTerminationProtocolWebRTCSRTP {
		t.Fatalf("expected final WebRTC/SRTP viewer gateway contract, got %#v", resp.Transport)
	}
	if resp.WorkerBridge == nil || !strings.Contains(resp.WorkerBridge.MediaRelayURL, "/gateway/media/sess_media_runtime/worker") {
		t.Fatalf("expected final worker media relay URL, got %#v", resp.WorkerBridge)
	}
	if resp.WorkerBridge == nil ||
		!strings.Contains(resp.WorkerBridge.MediaGatewayURL, "/gateway/webrtc/sess_media_runtime/worker") ||
		resp.WorkerBridge.Protocol != mediaTerminationProtocolWebRTCSRTP {
		t.Fatalf("expected final WebRTC/SRTP worker gateway contract, got %#v", resp.WorkerBridge)
	}
}

func TestValidateMediaGatewaySessionResponseRejectsMalformedOrIncomplete(t *testing.T) {
	req := contracts.MediaGatewaySessionRequest{
		SessionID:   "sess_media_runtime",
		ViewerToken: "viewer-token",
		WorkerToken: "worker-token",
		GatewayAssignment: contracts.GatewayAssignment{
			RelayMode: relayModeGatewayMediaRelay,
		},
	}
	tests := []struct {
		name      string
		mutateReq func(*contracts.MediaGatewaySessionRequest)
		mutate    func(*contracts.MediaGatewaySessionResponse)
		want      string
	}{
		{
			name: "missing viewer token",
			mutateReq: func(req *contracts.MediaGatewaySessionRequest) {
				req.ViewerToken = ""
			},
			want: "viewerToken",
		},
		{
			name: "shared role token",
			mutateReq: func(req *contracts.MediaGatewaySessionRequest) {
				req.WorkerToken = req.ViewerToken
			},
			want: "role-bound",
		},
		{
			name: "mismatched session",
			mutate: func(resp *contracts.MediaGatewaySessionResponse) {
				resp.SessionID = "sess_other"
			},
			want: "sessionId does not match",
		},
		{
			name: "invalid viewer URL",
			mutate: func(resp *contracts.MediaGatewaySessionResponse) {
				resp.Transport.ViewerURL = "not-a-url"
			},
			want: "transport.viewerUrl is invalid",
		},
		{
			name: "missing viewer media relay URL",
			mutate: func(resp *contracts.MediaGatewaySessionResponse) {
				resp.Transport.MediaRelayURL = ""
			},
			want: "transport.mediaRelayUrl",
		},
		{
			name: "invalid worker media relay URL",
			mutate: func(resp *contracts.MediaGatewaySessionResponse) {
				resp.WorkerBridge.MediaRelayURL = "https://gateway.example.com/not-ws"
			},
			want: "workerBridge.mediaRelayUrl is invalid",
		},
		{
			name: "missing viewer webrtc gateway URL",
			mutate: func(resp *contracts.MediaGatewaySessionResponse) {
				resp.Transport.MediaGatewayURL = ""
			},
			want: "transport.mediaGatewayUrl",
		},
		{
			name: "worker webrtc gateway URL is viewer role",
			mutate: func(resp *contracts.MediaGatewaySessionResponse) {
				resp.WorkerBridge.MediaGatewayURL = "https://gateway.example.com/gateway/webrtc/sess_media_runtime/viewer"
			},
			want: "workerBridge.mediaGatewayUrl is not worker role-bound",
		},
		{
			name: "wrong media plane",
			mutate: func(resp *contracts.MediaGatewaySessionResponse) {
				resp.Transport.MediaPlaneMode = "direct-webrtc"
			},
			want: "gateway-webrtc-relay mediaPlaneMode",
		},
		{
			name: "wrong transport protocol",
			mutate: func(resp *contracts.MediaGatewaySessionResponse) {
				resp.Transport.Protocol = "webrtc"
			},
			want: "webrtc-srtp transport protocol",
		},
		{
			name: "missing media relay capability",
			mutate: func(resp *contracts.MediaGatewaySessionResponse) {
				resp.Transport.MediaTermination = nil
			},
			want: "transport.mediaTermination",
		},
		{
			name: "incomplete media relay capability",
			mutate: func(resp *contracts.MediaGatewaySessionResponse) {
				resp.Transport.MediaTermination.GatewayTerminatesMedia = false
			},
			want: "gateway-media-relay capability",
		},
		{
			name: "wrong capability protocol",
			mutate: func(resp *contracts.MediaGatewaySessionResponse) {
				resp.Transport.MediaTermination.Protocol = "webrtc"
			},
			want: "mediaTermination requires webrtc-srtp protocol",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := req
			if tt.mutateReq != nil {
				tt.mutateReq(&req)
			}
			resp := validMediaRelayGatewayResponse()
			if tt.mutate != nil {
				tt.mutate(&resp)
			}
			err := validateMediaGatewaySessionResponse(req, resp)
			if err == nil {
				t.Fatal("expected validation error")
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("expected error containing %q, got %q", tt.want, err.Error())
			}
		})
	}
}

func validMediaRelayGatewayResponse() contracts.MediaGatewaySessionResponse {
	return contracts.MediaGatewaySessionResponse{
		SessionID:       "sess_media_runtime",
		ViewerEntryMode: "swg-handoff",
		GatewayAssignment: contracts.GatewayAssignment{
			SessionID:     "sess_media_runtime",
			GatewayID:     "gateway-us-east-1-01",
			Region:        "us-east-1",
			WorkerID:      "worker-us-east-1-001",
			RelayMode:     "gateway-media-relay",
			PublicBaseURL: "https://gateway.example.com",
			PublicWsURL:   "wss://gateway.example.com/ws",
		},
		WorkerAssignment: contracts.WorkerAssignment{
			SessionID:        "sess_media_runtime",
			WorkerID:         "worker-us-east-1-001",
			Region:           "us-east-1",
			RuntimeClass:     "kata-clh",
			NodePool:         "rbi-workers",
			AvailabilityZone: "us-east-1a",
		},
		Transport: contracts.GatewayTransport{
			Preferred:       "websocket",
			Supported:       []string{"websocket"},
			ViewerURL:       "https://gateway.example.com/gateway/viewer/sess_media_runtime?transport=websocket",
			SignalingURL:    "wss://gateway.example.com/gateway/signaling/sess_media_runtime/viewer?transport=websocket",
			MediaRelayURL:   "wss://gateway.example.com/gateway/media/sess_media_runtime/viewer?transport=websocket",
			MediaGatewayURL: "https://gateway.example.com/gateway/webrtc/sess_media_runtime/viewer",
			MediaPlaneMode:  mediaPlaneModeGatewayWebRTCRelay,
			Protocol:        mediaTerminationProtocolWebRTCSRTP,
			MediaTermination: &contracts.MediaTerminationCapability{
				Mode:                       "gateway-media-relay",
				MediaPlaneMode:             mediaPlaneModeGatewayWebRTCRelay,
				Protocol:                   mediaTerminationProtocolWebRTCSRTP,
				RelayMode:                  relayModeGatewayMediaRelay,
				RelayModeAcceptanceState:   "accepted",
				GatewayTerminatesSignaling: true,
				GatewayTerminatesMedia:     true,
				WorkerAddressExposure:      "gateway-only",
				Wave2AcceptanceComplete:    true,
				ImplementationStatus:       "implemented",
			},
		},
		WorkerBridge: contracts.WorkerBridge{
			BridgeID:        "bridge-sess_media_runtime",
			RelayMode:       relayModeGatewayMediaRelay,
			MediaRelayURL:   "wss://gateway.example.com/gateway/media/sess_media_runtime/worker?transport=websocket",
			MediaGatewayURL: "https://gateway.example.com/gateway/webrtc/sess_media_runtime/worker",
			Protocol:        mediaTerminationProtocolWebRTCSRTP,
		},
	}
}

func marshalJSON(t *testing.T, value any) []byte {
	t.Helper()

	body, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal json: %v", err)
	}
	return body
}
