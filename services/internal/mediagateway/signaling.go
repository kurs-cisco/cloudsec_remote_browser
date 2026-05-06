package mediagateway

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"cloudsec_remote_browser/services/internal/httpx"
)

const (
	wsOpcodeContinuation           = 0x0
	wsOpcodeText                   = 0x1
	wsOpcodeClose                  = 0x8
	wsOpcodePing                   = 0x9
	wsOpcodePong                   = 0xA
	signalMaxPendingMessages       = 512
	signalMaxPendingBytesPerRole   = 2 * 1024 * 1024
	signalMaxWebSocketMessageBytes = 256 * 1024
)

type runtimeSessionNotifier interface {
	NotifySessionEvent(ctx context.Context, sessionID string, event runtimeSessionEventRequest) error
}

type runtimeSessionEventRequest struct {
	Action     string `json:"action"`
	State      string `json:"state,omitempty"`
	Reason     string `json:"reason,omitempty"`
	Generation int    `json:"generation,omitempty"`
}

type noopRuntimeSessionNotifier struct{}

func (noopRuntimeSessionNotifier) NotifySessionEvent(context.Context, string, runtimeSessionEventRequest) error {
	return nil
}

type httpRuntimeSessionNotifier struct {
	baseURL string
	secret  string
	client  *http.Client
}

type signalRoute struct {
	SessionID string
	Role      string
}

type signalSessionState struct {
	viewer                 *signalConnection
	worker                 *signalConnection
	pendingViewer          [][]byte
	pendingWorker          [][]byte
	pendingViewerBytes     int
	pendingWorkerBytes     int
	droppedViewerSignals   int
	droppedWorkerSignals   int
	terminated             bool
	viewerConnectEvents    int
	workerConnectEvents    int
	viewerDisconnectEvents int
	workerDisconnectEvents int
	viewerHeartbeats       int
	viewerSignalMessages   int
	workerStateUpdates     int
	signalsToViewer        int
	signalsToWorker        int
	lastViewerSeenAt       time.Time
	lastWorkerState        string
	lastWorkerStateAt      time.Time
	lastSignalForwardedAt  time.Time
	terminatedAt           time.Time
	terminationReason      string
}

type signalConnection struct {
	id         string
	sessionID  string
	role       string
	generation int
	ws         *websocketConn
}

type signalRegisterMessage struct {
	Type      string `json:"type"`
	Role      string `json:"role"`
	SessionID string `json:"sessionId"`
	Token     string `json:"token,omitempty"`
}

type terminateRequest struct {
	Reason string `json:"reason,omitempty"`
}

type websocketConn struct {
	conn      net.Conn
	reader    *bufio.Reader
	writeMu   sync.Mutex
	closeOnce sync.Once
}

func newRuntimeSessionNotifier(cfg Config) runtimeSessionNotifier {
	if cfg.RuntimeNotifyBaseURL == "" {
		return noopRuntimeSessionNotifier{}
	}

	timeout := cfg.RuntimeRequestTimeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}

	return &httpRuntimeSessionNotifier{
		baseURL: cfg.RuntimeNotifyBaseURL,
		secret:  cfg.InternalSharedSecret,
		client: &http.Client{
			Timeout: timeout,
		},
	}
}

func (n *httpRuntimeSessionNotifier) NotifySessionEvent(
	ctx context.Context,
	sessionID string,
	event runtimeSessionEventRequest,
) error {
	body, err := json.Marshal(event)
	if err != nil {
		return err
	}

	endpoint := fmt.Sprintf(
		"%s/api/internal/sessions/%s/events",
		n.baseURL,
		url.PathEscape(sessionID),
	)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if n.secret != "" {
		req.Header.Set("X-RBI-Internal-Secret", n.secret)
	}

	resp, err := n.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(message)))
	}
	return nil
}

func (s *Service) handleTerminateSession(w http.ResponseWriter, r *http.Request, sessionID string) {
	defer r.Body.Close()
	rawBody, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, serviceName, "invalid terminate request")
		return
	}

	_, owner, ok := s.getSessionWithOwner(r.Context(), sessionID)
	if !ok {
		httpx.WriteError(w, http.StatusNotFound, serviceName, "session not found")
		return
	}
	if s.proxyOwnerRequest(w, r, owner, rawBody) {
		return
	}

	var body terminateRequest
	_ = json.NewDecoder(bytes.NewReader(rawBody)).Decode(&body)
	reason := strings.TrimSpace(body.Reason)
	if reason == "" {
		reason = "session terminated"
	}

	s.terminateSignalSession(sessionID, reason)
	s.terminateMediaRelaySession(sessionID, reason)
	s.terminateWebRTCRelaySession(sessionID, reason)
	s.deleteStoredSession(context.Background(), sessionID)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"sessionId": sessionID,
		"state":     "terminated",
		"reason":    reason,
	})
}

func (s *Service) handleSignaling(w http.ResponseWriter, r *http.Request) {
	route, err := parseSignalRoute(r.URL.Path)
	if err != nil {
		httpx.WriteError(w, http.StatusNotFound, serviceName, "signaling route not found")
		return
	}
	ws, err := upgradeWebSocket(w, r)
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, serviceName, err.Error())
		return
	}
	go s.runSignalConnection(route, ws)
}

func (s *Service) runSignalConnection(route signalRoute, ws *websocketConn) {
	defer ws.CloseNow()

	register, err := readSignalRegisterMessage(ws)
	if err != nil {
		_ = ws.WriteJSON(map[string]any{"type": "error", "message": err.Error()})
		ws.CloseWithReason(1008, "invalid register")
		return
	}
	if register.Role != route.Role || register.SessionID != route.SessionID {
		_ = ws.WriteJSON(map[string]any{"type": "error", "message": "registration path mismatch"})
		ws.CloseWithReason(1008, "registration path mismatch")
		return
	}

	record, ok := s.GetSession(route.SessionID)
	if !ok {
		_ = ws.WriteJSON(map[string]any{"type": "error", "message": "session not found"})
		ws.CloseWithReason(1008, "session not found")
		return
	}

	expectedToken := record.Request.WorkerToken
	if route.Role == "viewer" {
		expectedToken = record.Request.ViewerToken
	}
	if expectedToken == "" || register.Token != expectedToken {
		_ = ws.WriteJSON(map[string]any{"type": "error", "message": "invalid session token"})
		ws.CloseWithReason(1008, "invalid session token")
		return
	}

	generation := record.Request.Generation
	if generation <= 0 {
		generation = 1
	}
	conn := &signalConnection{
		id:         newOpaqueID("sig_"),
		sessionID:  route.SessionID,
		role:       route.Role,
		generation: generation,
		ws:         ws,
	}

	previous, pending, terminated := s.registerSignalConnection(route.SessionID, route.Role, conn)
	if terminated {
		_ = ws.WriteJSON(map[string]any{"type": "error", "message": "session is terminated"})
		ws.CloseWithReason(1008, "session terminated")
		return
	}
	if previous != nil {
		previous.ws.CloseWithReason(1000, "superseded by newer connection")
	}
	if err := s.notifyRuntimeEvent(route.SessionID, route.Role, generation, "connected", "", ""); err != nil {
		_ = ws.WriteJSON(map[string]any{"type": "error", "message": "runtime notify failed"})
		ws.CloseWithReason(1011, "runtime notify failed")
		return
	}

	_ = ws.WriteJSON(map[string]any{"type": "registered", "role": route.Role})
	for _, payload := range pending {
		ws.SetWriteDeadline(time.Now().Add(mediaRelayWriteTimeout))
		if err := ws.WriteText(payload); err != nil {
			break
		}
	}

	for {
		payload, err := ws.ReadText()
		if err != nil {
			break
		}
		if len(payload) > signalMaxWebSocketMessageBytes {
			_ = ws.WriteJSON(map[string]any{"type": "error", "message": "signaling payload exceeds maximum message size"})
			ws.CloseWithReason(1009, "signaling payload too large")
			break
		}

		var envelope map[string]any
		if err := json.Unmarshal(payload, &envelope); err != nil {
			_ = ws.WriteJSON(map[string]any{"type": "error", "message": "invalid signaling payload"})
			continue
		}
		messageType := strings.TrimSpace(fmt.Sprint(envelope["type"]))
		if record.Response.WorkerBridge.RelayMode == relayModeGatewayMediaRelay &&
			isLegacyWebRTCSignalMessage(messageType) {
			_ = ws.WriteJSON(map[string]any{
				"type":      "error",
				"sessionId": route.SessionID,
				"message":   "legacy webrtc signaling is disabled for gateway-terminated media sessions",
				"code":      "gateway-webrtc-relay-required",
			})
			continue
		}
		switch messageType {
		case "heartbeat":
			if route.Role == "viewer" {
				s.noteViewerHeartbeat(route.SessionID)
				_ = s.notifyRuntimeEvent(route.SessionID, route.Role, generation, "seen", "", "")
			}
			_ = ws.WriteJSON(map[string]any{
				"type":      "heartbeat-ack",
				"sessionId": route.SessionID,
				"ts":        time.Now().UnixMilli(),
			})
		case "worker-state":
			if route.Role == "worker" {
				state := strings.TrimSpace(fmt.Sprint(envelope["state"]))
				s.noteWorkerState(route.SessionID, state)
				_ = s.notifyRuntimeEvent(route.SessionID, route.Role, generation, "state", state, "")
			}
			if route.Role == "viewer" {
				s.noteViewerSignal(route.SessionID)
				_ = s.notifyRuntimeEvent(route.SessionID, route.Role, generation, "seen", "", "")
			}
			s.forwardSignal(route.SessionID, oppositeRole(route.Role), payload)
		default:
			if route.Role == "viewer" {
				s.noteViewerSignal(route.SessionID)
				_ = s.notifyRuntimeEvent(route.SessionID, route.Role, generation, "seen", "", "")
			}
			s.forwardSignal(route.SessionID, oppositeRole(route.Role), payload)
		}
	}

	released, wasTerminated := s.unregisterSignalConnection(route.SessionID, route.Role, conn.id)
	if !released || wasTerminated {
		return
	}
	_ = s.notifyRuntimeEvent(route.SessionID, route.Role, generation, "disconnected", "", "")
}

func isLegacyWebRTCSignalMessage(messageType string) bool {
	switch strings.TrimSpace(messageType) {
	case "sdp-offer", "sdp-answer", "ice-candidate":
		return true
	default:
		return false
	}
}

func (s *Service) notifyRuntimeEvent(
	sessionID string,
	role string,
	generation int,
	action string,
	state string,
	reason string,
) error {
	request := runtimeSessionEventRequest{Generation: generation}
	switch action {
	case "connected":
		if role == "viewer" {
			request.Action = "viewer-connected"
		} else {
			request.Action = "worker-ready"
		}
	case "seen":
		request.Action = "viewer-seen"
	case "state":
		request.Action = "worker-state"
		request.State = state
	case "disconnected":
		if role == "viewer" {
			request.Action = "viewer-disconnected"
		} else {
			request.Action = "worker-disconnected"
		}
	default:
		request.Action = action
	}
	request.Reason = reason
	return s.runtimeNotifier.NotifySessionEvent(context.Background(), sessionID, request)
}

func (s *Service) registerSignalConnection(
	sessionID string,
	role string,
	conn *signalConnection,
) (*signalConnection, [][]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	state := s.signals[sessionID]
	if state == nil {
		state = &signalSessionState{}
		s.signals[sessionID] = state
	}
	if state.terminated {
		return nil, nil, true
	}

	var previous *signalConnection
	var pending [][]byte
	if role == "viewer" {
		previous = state.viewer
		state.viewer = conn
		pending = state.pendingViewer
		state.pendingViewer = nil
		state.pendingViewerBytes = 0
		state.viewerConnectEvents++
	} else {
		previous = state.worker
		state.worker = conn
		pending = state.pendingWorker
		state.pendingWorker = nil
		state.pendingWorkerBytes = 0
		state.workerConnectEvents++
	}
	return previous, pending, false
}

func (s *Service) unregisterSignalConnection(sessionID string, role string, connectionID string) (bool, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	state := s.signals[sessionID]
	if state == nil {
		return false, false
	}
	if state.terminated {
		return false, true
	}

	var current *signalConnection
	if role == "viewer" {
		current = state.viewer
	} else {
		current = state.worker
	}
	if current == nil || current.id != connectionID {
		return false, false
	}
	if role == "viewer" {
		state.viewer = nil
		state.viewerDisconnectEvents++
	} else {
		state.worker = nil
		state.workerDisconnectEvents++
	}
	return true, false
}

func (s *Service) forwardSignal(sessionID string, role string, payload []byte) {
	payload = append([]byte(nil), payload...)

	s.mu.RLock()
	state := s.signals[sessionID]
	var target *signalConnection
	if state != nil && !state.terminated {
		if role == "viewer" {
			target = state.viewer
		} else {
			target = state.worker
		}
	}
	s.mu.RUnlock()

	if target != nil {
		target.ws.SetWriteDeadline(time.Now().Add(mediaRelayWriteTimeout))
		if err := target.ws.WriteText(payload); err == nil {
			s.noteForwardedSignal(sessionID, role)
			return
		}
		target.ws.CloseWithReason(1011, "signal relay failed")
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	state = s.signals[sessionID]
	if state == nil {
		state = &signalSessionState{}
		s.signals[sessionID] = state
	}
	if state.terminated {
		return
	}
	appendBoundedSignalPayloadLocked(state, role, payload)
	now := time.Now().UTC()
	state.lastSignalForwardedAt = now
	if role == "viewer" {
		state.signalsToViewer++
	} else {
		state.signalsToWorker++
	}
}

func appendBoundedSignalPayloadLocked(state *signalSessionState, role string, payload []byte) {
	if role == "viewer" {
		state.pendingViewer = append(state.pendingViewer, payload)
		state.pendingViewerBytes += len(payload)
		for len(state.pendingViewer) > signalMaxPendingMessages ||
			state.pendingViewerBytes > signalMaxPendingBytesPerRole {
			state.pendingViewerBytes -= len(state.pendingViewer[0])
			state.pendingViewer = state.pendingViewer[1:]
			state.droppedViewerSignals++
		}
		return
	}
	state.pendingWorker = append(state.pendingWorker, payload)
	state.pendingWorkerBytes += len(payload)
	for len(state.pendingWorker) > signalMaxPendingMessages ||
		state.pendingWorkerBytes > signalMaxPendingBytesPerRole {
		state.pendingWorkerBytes -= len(state.pendingWorker[0])
		state.pendingWorker = state.pendingWorker[1:]
		state.droppedWorkerSignals++
	}
}

func (s *Service) terminateSignalSession(sessionID string, reason string) {
	s.mu.Lock()
	state := s.signals[sessionID]
	if state == nil {
		state = &signalSessionState{}
		s.signals[sessionID] = state
	}
	state.terminated = true
	state.terminatedAt = time.Now().UTC()
	state.terminationReason = reason
	viewer := state.viewer
	worker := state.worker
	state.viewer = nil
	state.worker = nil
	state.pendingViewer = nil
	state.pendingWorker = nil
	s.mu.Unlock()

	payload, _ := json.Marshal(map[string]any{
		"type":      "session-terminated",
		"sessionId": sessionID,
		"reason":    reason,
	})
	for _, conn := range []*signalConnection{viewer, worker} {
		if conn == nil {
			continue
		}
		_ = conn.ws.WriteText(payload)
		conn.ws.CloseWithReason(1000, reason)
	}
}

func (s *Service) isSignalSessionTerminated(sessionID string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	state := s.signals[sessionID]
	return state != nil && state.terminated
}

func (s *Service) noteViewerHeartbeat(sessionID string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	state := s.signals[sessionID]
	if state == nil {
		state = &signalSessionState{}
		s.signals[sessionID] = state
	}
	state.viewerHeartbeats++
	state.lastViewerSeenAt = time.Now().UTC()
}

func (s *Service) noteViewerSignal(sessionID string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	state := s.signals[sessionID]
	if state == nil {
		state = &signalSessionState{}
		s.signals[sessionID] = state
	}
	state.viewerSignalMessages++
	state.lastViewerSeenAt = time.Now().UTC()
}

func (s *Service) noteWorkerState(sessionID string, workerState string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	state := s.signals[sessionID]
	if state == nil {
		state = &signalSessionState{}
		s.signals[sessionID] = state
	}
	state.workerStateUpdates++
	state.lastWorkerState = strings.TrimSpace(workerState)
	state.lastWorkerStateAt = time.Now().UTC()
}

func (s *Service) noteForwardedSignal(sessionID string, role string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	state := s.signals[sessionID]
	if state == nil {
		state = &signalSessionState{}
		s.signals[sessionID] = state
	}
	state.lastSignalForwardedAt = time.Now().UTC()
	if role == "viewer" {
		state.signalsToViewer++
		return
	}
	state.signalsToWorker++
}

func parseSignalRoute(path string) (signalRoute, error) {
	trimmed := strings.TrimSuffix(path, "/")
	trimmed = strings.TrimPrefix(trimmed, "/ws")
	parts := strings.Split(trimmed, "/")
	if len(parts) != 5 || parts[1] != "gateway" || parts[2] != "signaling" {
		return signalRoute{}, errors.New("invalid signaling path")
	}
	if parts[4] != "viewer" && parts[4] != "worker" {
		return signalRoute{}, errors.New("invalid signaling role")
	}
	sessionID, err := url.PathUnescape(parts[3])
	if err != nil || sessionID == "" {
		return signalRoute{}, errors.New("invalid signaling session id")
	}
	return signalRoute{
		SessionID: sessionID,
		Role:      parts[4],
	}, nil
}

func oppositeRole(role string) string {
	if role == "viewer" {
		return "worker"
	}
	return "viewer"
}

func readSignalRegisterMessage(ws *websocketConn) (signalRegisterMessage, error) {
	payload, err := ws.ReadText()
	if err != nil {
		return signalRegisterMessage{}, err
	}
	var register signalRegisterMessage
	if err := json.Unmarshal(payload, &register); err != nil {
		return signalRegisterMessage{}, err
	}
	register.Type = strings.TrimSpace(register.Type)
	register.Role = strings.TrimSpace(register.Role)
	register.SessionID = strings.TrimSpace(register.SessionID)
	register.Token = strings.TrimSpace(register.Token)
	if register.Type != "register" {
		return signalRegisterMessage{}, errors.New("first signaling payload must be register")
	}
	if register.Role != "viewer" && register.Role != "worker" {
		return signalRegisterMessage{}, errors.New("invalid register role")
	}
	if register.SessionID == "" {
		return signalRegisterMessage{}, errors.New("register sessionId is required")
	}
	if register.Token == "" {
		return signalRegisterMessage{}, errors.New("register token is required")
	}
	return register, nil
}

func upgradeWebSocket(w http.ResponseWriter, r *http.Request) (*websocketConn, error) {
	if r.Method != http.MethodGet {
		return nil, errors.New("websocket upgrade requires GET")
	}
	if !headerContainsToken(r.Header, "Connection", "upgrade") ||
		!strings.EqualFold(strings.TrimSpace(r.Header.Get("Upgrade")), "websocket") {
		return nil, errors.New("invalid websocket upgrade request")
	}
	if strings.TrimSpace(r.Header.Get("Sec-WebSocket-Version")) != "13" {
		return nil, errors.New("unsupported websocket version")
	}

	key := strings.TrimSpace(r.Header.Get("Sec-WebSocket-Key"))
	if key == "" {
		return nil, errors.New("missing websocket key")
	}

	hijacker, ok := w.(http.Hijacker)
	if !ok {
		return nil, errors.New("server does not support websocket upgrade")
	}
	conn, rw, err := hijacker.Hijack()
	if err != nil {
		return nil, err
	}

	accept := computeWebSocketAccept(key)
	response := strings.Join([]string{
		"HTTP/1.1 101 Switching Protocols",
		"Upgrade: websocket",
		"Connection: Upgrade",
		"Sec-WebSocket-Accept: " + accept,
		"",
		"",
	}, "\r\n")
	if _, err := rw.WriteString(response); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if err := rw.Flush(); err != nil {
		_ = conn.Close()
		return nil, err
	}

	return &websocketConn{
		conn:   conn,
		reader: rw.Reader,
	}, nil
}

func headerContainsToken(header http.Header, key string, expected string) bool {
	for _, entry := range header.Values(key) {
		for _, part := range strings.Split(entry, ",") {
			if strings.EqualFold(strings.TrimSpace(part), expected) {
				return true
			}
		}
	}
	return false
}

func computeWebSocketAccept(key string) string {
	hasher := sha1.New()
	_, _ = hasher.Write([]byte(key))
	_, _ = hasher.Write([]byte("258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(hasher.Sum(nil))
}

func (c *websocketConn) ReadText() ([]byte, error) {
	for {
		opcode, payload, err := c.readFrame()
		if err != nil {
			return nil, err
		}
		switch opcode {
		case wsOpcodeText:
			return payload, nil
		case wsOpcodePing:
			_ = c.writeFrame(wsOpcodePong, payload)
		case wsOpcodePong:
			continue
		case wsOpcodeClose:
			return nil, io.EOF
		default:
			return nil, errors.New("unsupported websocket opcode")
		}
	}
}

func (c *websocketConn) WriteJSON(payload any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	return c.WriteText(body)
}

func (c *websocketConn) WriteText(payload []byte) error {
	return c.writeFrame(wsOpcodeText, payload)
}

func (c *websocketConn) SetWriteDeadline(deadline time.Time) {
	_ = c.conn.SetWriteDeadline(deadline)
}

func (c *websocketConn) CloseWithReason(code int, reason string) {
	c.closeOnce.Do(func() {
		_ = c.writeFrame(wsOpcodeClose, buildClosePayload(code, reason))
		_ = c.conn.Close()
	})
}

func (c *websocketConn) CloseNow() {
	c.closeOnce.Do(func() {
		_ = c.conn.Close()
	})
}

func (c *websocketConn) readFrame() (byte, []byte, error) {
	header := make([]byte, 2)
	if _, err := io.ReadFull(c.reader, header); err != nil {
		return 0, nil, err
	}

	fin := header[0]&0x80 != 0
	opcode := header[0] & 0x0F
	masked := header[1]&0x80 != 0
	payloadLen := int64(header[1] & 0x7F)

	if !fin || opcode == wsOpcodeContinuation {
		return 0, nil, errors.New("fragmented websocket frames are not supported")
	}
	if payloadLen == 126 {
		extended := make([]byte, 2)
		if _, err := io.ReadFull(c.reader, extended); err != nil {
			return 0, nil, err
		}
		payloadLen = int64(binary.BigEndian.Uint16(extended))
	} else if payloadLen == 127 {
		extended := make([]byte, 8)
		if _, err := io.ReadFull(c.reader, extended); err != nil {
			return 0, nil, err
		}
		payloadLen = int64(binary.BigEndian.Uint64(extended))
	}

	var maskKey [4]byte
	if masked {
		if _, err := io.ReadFull(c.reader, maskKey[:]); err != nil {
			return 0, nil, err
		}
	}

	payload := make([]byte, payloadLen)
	if _, err := io.ReadFull(c.reader, payload); err != nil {
		return 0, nil, err
	}
	if masked {
		for i := range payload {
			payload[i] ^= maskKey[i%4]
		}
	}
	return opcode, payload, nil
}

func (c *websocketConn) writeFrame(opcode byte, payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	header := []byte{0x80 | opcode}
	payloadLen := len(payload)
	switch {
	case payloadLen <= 125:
		header = append(header, byte(payloadLen))
	case payloadLen <= 65535:
		header = append(header, 126, byte(payloadLen>>8), byte(payloadLen))
	default:
		header = append(header, 127)
		lengthBytes := make([]byte, 8)
		binary.BigEndian.PutUint64(lengthBytes, uint64(payloadLen))
		header = append(header, lengthBytes...)
	}

	if _, err := c.conn.Write(header); err != nil {
		return err
	}
	if payloadLen == 0 {
		return nil
	}
	_, err := c.conn.Write(payload)
	return err
}

func buildClosePayload(code int, reason string) []byte {
	if code <= 0 {
		return nil
	}
	payload := make([]byte, 2)
	binary.BigEndian.PutUint16(payload, uint16(code))
	if reason == "" {
		return payload
	}
	return append(payload, []byte(reason)...)
}
