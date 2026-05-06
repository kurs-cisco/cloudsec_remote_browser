package mediagateway

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"

	"cloudsec_remote_browser/services/internal/contracts"
	"cloudsec_remote_browser/services/internal/httpx"
	"github.com/pion/webrtc/v4"
)

type webrtcRoute struct {
	SessionID string
	Role      string
	Action    string
}

type webrtcOfferRequest struct {
	Type      string         `json:"type,omitempty"`
	Role      string         `json:"role,omitempty"`
	SessionID string         `json:"sessionId,omitempty"`
	SDP       string         `json:"sdp,omitempty"`
	Token     string         `json:"token,omitempty"`
	Candidate map[string]any `json:"candidate,omitempty"`
}

func (s *Service) handleWebRTCRelay(w http.ResponseWriter, r *http.Request) {
	route, err := parseWebRTCRoute(r.URL.Path)
	if err != nil {
		httpx.WriteError(w, http.StatusNotFound, serviceName, "webrtc relay route not found")
		return
	}
	if r.Method != http.MethodPost {
		httpx.MethodNotAllowed(w, serviceName, http.MethodPost)
		return
	}

	defer r.Body.Close()
	rawBody, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 512*1024))
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, serviceName, "invalid webrtc relay request")
		return
	}
	var body webrtcOfferRequest
	if err := json.NewDecoder(bytes.NewReader(rawBody)).Decode(&body); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, serviceName, "invalid webrtc relay request")
		return
	}
	if body.Token == "" {
		body.Token = bearerToken(r.Header.Get("Authorization"))
	}

	record, owner, ok := s.getSessionWithOwner(r.Context(), route.SessionID)
	if !ok {
		httpx.WriteError(w, http.StatusNotFound, serviceName, "session not found")
		return
	}
	if s.proxyOwnerRequest(w, r, owner, rawBody) {
		return
	}
	if record.Response.WorkerBridge.RelayMode != relayModeGatewayMediaRelay ||
		record.Response.Transport.MediaTermination == nil ||
		!record.Response.Transport.MediaTermination.GatewayTerminatesMedia {
		httpx.WriteError(w, http.StatusBadRequest, serviceName, "session is not using gateway webrtc relay")
		return
	}
	if err := validateGatewayWebRTCContract(record.Response); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, serviceName, err.Error())
		return
	}

	expectedToken := record.Request.WorkerToken
	if route.Role == "viewer" {
		expectedToken = record.Request.ViewerToken
	}
	if expectedToken == "" || body.Token != expectedToken {
		httpx.WriteError(w, http.StatusUnauthorized, serviceName, "invalid session token")
		return
	}

	if route.Action == "offer" {
		codecsAllowed, reason := sdpAllowsGatewayCodecs(body.SDP)
		if !codecsAllowed {
			s.recordWebRTCCodecReject(route.Role, reason)
			httpx.WriteError(w, http.StatusUnsupportedMediaType, serviceName, "unsupported-codec")
			return
		}
	}

	if s.isSignalSessionTerminated(route.SessionID) {
		httpx.WriteError(w, http.StatusGone, serviceName, "session is terminated")
		return
	}

	relay, err := s.getOrCreatePionRelaySession(record)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, serviceName, "failed to initialize webrtc relay")
		return
	}

	switch route.Action {
	case "offer":
		answerSDP, err := relay.handleOffer(route.Role, body.SDP)
		if err != nil {
			writeWebRTCRelayError(w, err)
			return
		}
		httpx.WriteJSON(w, http.StatusOK, map[string]any{
			"type":                   "answer",
			"sdp":                    answerSDP,
			"sessionId":              route.SessionID,
			"role":                   route.Role,
			"action":                 route.Action,
			"mediaPlaneMode":         mediaPlaneModeGatewayWebRTCRelay,
			"protocol":               mediaTerminationProtocolWebRTCSRTP,
			"gatewayTerminatesMedia": true,
			"inputPointerName":       inputPointerChannelName,
			"inputControlName":       inputControlChannelName,
			"status":                 "answer",
		})
	case "ice":
		candidate, err := parseWebRTCICECandidate(body.Candidate)
		if err != nil {
			httpx.WriteError(w, http.StatusBadRequest, serviceName, err.Error())
			return
		}
		if err := relay.handleICE(route.Role, candidate); err != nil {
			writeWebRTCRelayError(w, err)
			return
		}
		httpx.WriteJSON(w, http.StatusOK, map[string]any{
			"sessionId": route.SessionID,
			"role":      route.Role,
			"action":    route.Action,
			"status":    "accepted",
		})
	default:
		httpx.WriteError(w, http.StatusNotFound, serviceName, "webrtc relay route not found")
	}
}

func writeWebRTCRelayError(w http.ResponseWriter, err error) {
	var apiErr *apiError
	if errors.As(err, &apiErr) {
		httpx.WriteError(w, apiErr.status, serviceName, apiErr.message)
		return
	}
	httpx.WriteError(w, http.StatusBadGateway, serviceName, "webrtc relay failed: "+err.Error())
}

func parseWebRTCRoute(path string) (webrtcRoute, error) {
	trimmed := strings.TrimSuffix(path, "/")
	parts := strings.Split(trimmed, "/")
	if len(parts) != 6 || parts[1] != "gateway" || parts[2] != "webrtc" {
		return webrtcRoute{}, errors.New("invalid webrtc relay path")
	}
	if parts[4] != "viewer" && parts[4] != "worker" {
		return webrtcRoute{}, errors.New("invalid webrtc relay role")
	}
	if parts[5] != "offer" && parts[5] != "ice" {
		return webrtcRoute{}, errors.New("invalid webrtc relay action")
	}
	sessionID, err := url.PathUnescape(parts[3])
	if err != nil || sessionID == "" {
		return webrtcRoute{}, errors.New("invalid webrtc relay session id")
	}
	return webrtcRoute{SessionID: sessionID, Role: parts[4], Action: parts[5]}, nil
}

func bearerToken(header string) string {
	header = strings.TrimSpace(header)
	if len(header) < len("Bearer ") || !strings.EqualFold(header[:len("Bearer ")], "Bearer ") {
		return ""
	}
	return strings.TrimSpace(header[len("Bearer "):])
}

func parseWebRTCICECandidate(candidate map[string]any) (webrtc.ICECandidateInit, error) {
	if len(candidate) == 0 {
		return webrtc.ICECandidateInit{}, errors.New("missing ice candidate")
	}
	var init webrtc.ICECandidateInit
	var buf bytes.Buffer
	if err := json.NewEncoder(&buf).Encode(candidate); err != nil {
		return init, errors.New("invalid ice candidate")
	}
	if err := json.NewDecoder(&buf).Decode(&init); err != nil {
		return init, errors.New("invalid ice candidate")
	}
	if strings.TrimSpace(init.Candidate) == "" {
		return init, errors.New("missing ice candidate")
	}
	return init, nil
}

func sdpAllowsGatewayCodecs(sdp string) (bool, string) {
	normalized := strings.ToLower(sdp)
	if strings.TrimSpace(normalized) == "" {
		return false, "empty-sdp"
	}
	hasVideoMedia := strings.Contains(normalized, "\nm=video ") || strings.Contains(normalized, "\rm=video ") || strings.HasPrefix(normalized, "m=video ")
	hasAudioMedia := strings.Contains(normalized, "\nm=audio ") || strings.Contains(normalized, "\rm=audio ") || strings.HasPrefix(normalized, "m=audio ")
	hasVP8 := strings.Contains(normalized, "vp8/90000")
	hasOpus := strings.Contains(normalized, "opus/48000")
	if !hasVideoMedia && !hasAudioMedia {
		switch {
		case hasVP8 || hasOpus:
			return true, ""
		case strings.Contains(normalized, "h264/90000") ||
			strings.Contains(normalized, "vp9/90000") ||
			strings.Contains(normalized, "av1/90000"):
			return false, "unsupported-video-codec"
		case strings.Contains(normalized, "pcmu/8000") ||
			strings.Contains(normalized, "pcma/8000") ||
			strings.Contains(normalized, "g722/8000"):
			return false, "unsupported-audio-codec"
		default:
			return false, "unsupported-codec"
		}
	}
	if hasVideoMedia && !hasVP8 {
		return false, "unsupported-video-codec"
	}
	if hasAudioMedia && !hasOpus {
		return false, "unsupported-audio-codec"
	}
	return true, ""
}

func validateGatewayWebRTCContract(resp contracts.MediaGatewaySessionResponse) error {
	switch {
	case strings.TrimSpace(resp.Transport.MediaGatewayURL) == "":
		return errors.New("gateway webrtc contract missing transport.mediaGatewayUrl")
	case strings.TrimSpace(resp.WorkerBridge.MediaGatewayURL) == "":
		return errors.New("gateway webrtc contract missing workerBridge.mediaGatewayUrl")
	case strings.TrimSpace(resp.Transport.MediaPlaneMode) != mediaPlaneModeGatewayWebRTCRelay:
		return errors.New("gateway webrtc contract requires gateway-webrtc-relay media plane")
	case strings.TrimSpace(resp.Transport.Protocol) != mediaTerminationProtocolWebRTCSRTP:
		return errors.New("gateway webrtc contract requires webrtc-srtp protocol")
	case strings.TrimSpace(resp.WorkerBridge.Protocol) != mediaTerminationProtocolWebRTCSRTP:
		return errors.New("gateway webrtc contract requires workerBridge webrtc-srtp protocol")
	default:
		return nil
	}
}

func newWebRTCCodecRejectSummary() WebRTCCodecRejectSummary {
	return WebRTCCodecRejectSummary{
		ByRole:   map[string]int{},
		ByReason: map[string]int{},
	}
}

func cloneWebRTCCodecRejectSummary(source WebRTCCodecRejectSummary) WebRTCCodecRejectSummary {
	return WebRTCCodecRejectSummary{
		Total:    source.Total,
		ByRole:   cloneStringIntMap(source.ByRole),
		ByReason: cloneStringIntMap(source.ByReason),
	}
}

func (s *Service) recordWebRTCCodecReject(role string, reason string) {
	role = strings.TrimSpace(role)
	if role == "" {
		role = "unknown"
	}
	reason = strings.TrimSpace(reason)
	if reason == "" {
		reason = "unsupported-codec"
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.codecRejects.ByRole == nil {
		s.codecRejects.ByRole = map[string]int{}
	}
	if s.codecRejects.ByReason == nil {
		s.codecRejects.ByReason = map[string]int{}
	}
	s.codecRejects.Total++
	s.codecRejects.ByRole[role]++
	s.codecRejects.ByReason[reason]++
}
