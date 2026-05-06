package mediagateway

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"cloudsec_remote_browser/services/internal/contracts"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

func TestGatewayWebRTCRelayForwardsRTPAndDataChannels(t *testing.T) {
	svc, sessionID := newTestGatewayMediaRelaySession(t)

	workerPC, workerTrack, workerControlMessages := newTestWorkerPeer(t)
	workerOffer := createGatheredTestOffer(t, workerPC)
	workerAnswer := postTestGatewayOffer(t, svc, sessionID, "worker", "worker-token-webrtc", workerOffer)
	if err := workerPC.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP:  workerAnswer,
	}); err != nil {
		t.Fatalf("set worker answer: %v", err)
	}

	viewerPC, viewerControl, viewerRTP := newTestViewerPeer(t)
	viewerOffer := createGatheredTestOffer(t, viewerPC)
	viewerAnswer := postTestGatewayOffer(t, svc, sessionID, "viewer", "viewer-token-webrtc", viewerOffer)
	if err := viewerPC.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer,
		SDP:  viewerAnswer,
	}); err != nil {
		t.Fatalf("set viewer answer: %v", err)
	}

	waitForTestDataChannelOpen(t, viewerControl)

	if err := viewerControl.SendText(`{"type":"pointer.button","button":0}`); err != nil {
		t.Fatalf("send viewer control message: %v", err)
	}
	select {
	case msg := <-workerControlMessages:
		if msg != `{"type":"pointer.button","button":0}` {
			t.Fatalf("unexpected worker control payload %q", msg)
		}
	case <-time.After(8 * time.Second):
		t.Fatal("timed out waiting for worker control data channel message")
	}

	if err := workerTrack.WriteRTP(&rtp.Packet{
		Header: rtp.Header{
			Version:        2,
			PayloadType:    96,
			SequenceNumber: 1,
			Timestamp:      90000,
			SSRC:           1234,
		},
		Payload: []byte{0x10, 0x00, 0x01},
	}); err != nil {
		t.Fatalf("write worker RTP: %v", err)
	}
	select {
	case <-viewerRTP:
	case <-time.After(8 * time.Second):
		t.Fatal("timed out waiting for viewer RTP")
	}

	summary := svc.buildSummary()
	if summary.WebRTCRelaySessions != 1 ||
		summary.WebRTCRTPPacketsToViewer == 0 ||
		summary.WebRTCDataMessagesToWorker == 0 {
		t.Fatalf("expected WebRTC relay summary counters, got %#v", summary)
	}
}

func newTestGatewayMediaRelaySession(t *testing.T) (*Service, string) {
	t.Helper()
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
		SessionID:   "sess_webrtc_integration",
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
	recorder := httptest.NewRecorder()
	svc.Handler().ServeHTTP(
		recorder,
		httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(createBody)),
	)
	if recorder.Code != http.StatusCreated {
		t.Fatalf("expected create status %d, got %d: %s", http.StatusCreated, recorder.Code, recorder.Body.String())
	}
	return svc, "sess_webrtc_integration"
}

func newTestWorkerPeer(t *testing.T) (*webrtc.PeerConnection, *webrtc.TrackLocalStaticRTP, <-chan string) {
	t.Helper()
	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatalf("new worker peer: %v", err)
	}
	t.Cleanup(func() {
		_ = pc.Close()
	})
	track, err := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{
		MimeType:  webrtc.MimeTypeVP8,
		ClockRate: 90000,
	}, "video", "desktop")
	if err != nil {
		t.Fatalf("new worker VP8 track: %v", err)
	}
	if _, err := pc.AddTrack(track); err != nil {
		t.Fatalf("add worker VP8 track: %v", err)
	}
	if _, err := pc.CreateDataChannel(inputPointerChannelName, &webrtc.DataChannelInit{
		Ordered:        boolPtr(false),
		MaxRetransmits: uint16Ptr(0),
	}); err != nil {
		t.Fatalf("create worker pointer channel: %v", err)
	}
	control, err := pc.CreateDataChannel(inputControlChannelName, nil)
	if err != nil {
		t.Fatalf("create worker control channel: %v", err)
	}
	messages := make(chan string, 1)
	control.OnMessage(func(msg webrtc.DataChannelMessage) {
		messages <- string(msg.Data)
	})
	return pc, track, messages
}

func newTestViewerPeer(t *testing.T) (*webrtc.PeerConnection, *webrtc.DataChannel, <-chan struct{}) {
	t.Helper()
	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatalf("new viewer peer: %v", err)
	}
	t.Cleanup(func() {
		_ = pc.Close()
	})
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		t.Fatalf("add viewer video transceiver: %v", err)
	}
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		t.Fatalf("add viewer audio transceiver: %v", err)
	}
	if _, err := pc.CreateDataChannel(inputPointerChannelName, &webrtc.DataChannelInit{
		Ordered:        boolPtr(false),
		MaxRetransmits: uint16Ptr(0),
	}); err != nil {
		t.Fatalf("create viewer pointer channel: %v", err)
	}
	control, err := pc.CreateDataChannel(inputControlChannelName, nil)
	if err != nil {
		t.Fatalf("create viewer control channel: %v", err)
	}
	rtpReceived := make(chan struct{}, 1)
	pc.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		if track.Kind() != webrtc.RTPCodecTypeVideo {
			return
		}
		go func() {
			if _, _, err := track.ReadRTP(); err == nil {
				rtpReceived <- struct{}{}
			}
		}()
	})
	return pc, control, rtpReceived
}

func createGatheredTestOffer(t *testing.T, pc *webrtc.PeerConnection) string {
	t.Helper()
	gatherComplete := webrtc.GatheringCompletePromise(pc)
	offer, err := pc.CreateOffer(nil)
	if err != nil {
		t.Fatalf("create offer: %v", err)
	}
	if err := pc.SetLocalDescription(offer); err != nil {
		t.Fatalf("set local offer: %v", err)
	}
	select {
	case <-gatherComplete:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for ICE gathering")
	}
	return pc.LocalDescription().SDP
}

func postTestGatewayOffer(
	t *testing.T,
	svc *Service,
	sessionID string,
	role string,
	token string,
	sdp string,
) string {
	t.Helper()
	body := marshalJSON(t, map[string]any{
		"type":      "offer",
		"sessionId": sessionID,
		"role":      role,
		"token":     token,
		"sdp":       sdp,
	})
	recorder := httptest.NewRecorder()
	svc.Handler().ServeHTTP(
		recorder,
		httptest.NewRequest(
			http.MethodPost,
			"/gateway/webrtc/"+sessionID+"/"+role+"/offer",
			bytes.NewReader(body),
		),
	)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected %s gateway offer status %d, got %d: %s", role, http.StatusOK, recorder.Code, recorder.Body.String())
	}
	var payload map[string]any
	if err := json.NewDecoder(recorder.Body).Decode(&payload); err != nil {
		t.Fatalf("decode gateway offer response: %v", err)
	}
	sdpAnswer, _ := payload["sdp"].(string)
	if sdpAnswer == "" {
		t.Fatalf("gateway response missing SDP answer: %#v", payload)
	}
	return sdpAnswer
}

func waitForTestDataChannelOpen(t *testing.T, dc *webrtc.DataChannel) {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if dc.ReadyState() == webrtc.DataChannelStateOpen {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for data channel %q to open; state=%s", dc.Label(), dc.ReadyState().String())
}

func boolPtr(value bool) *bool {
	return &value
}

func uint16Ptr(value uint16) *uint16 {
	return &value
}
