package mediagateway

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"cloudsec_remote_browser/services/internal/httpx"
)

const (
	mediaRelayMaxPendingFrames       = 256
	mediaRelayMaxPendingBytesPerRole = 4 * 1024 * 1024
	mediaRelayMaxWebSocketFrameBytes = 256 * 1024
	mediaRelayWriteTimeout           = 5 * time.Second
)

type mediaRoute struct {
	SessionID string
	Role      string
}

type MediaRelayStateSnapshot struct {
	ViewerConnected        bool       `json:"viewerConnected"`
	WorkerConnected        bool       `json:"workerConnected"`
	PendingViewerFrames    int        `json:"pendingViewerFrames"`
	PendingWorkerFrames    int        `json:"pendingWorkerFrames"`
	PendingViewerBytes     int        `json:"pendingViewerBytes"`
	PendingWorkerBytes     int        `json:"pendingWorkerBytes"`
	MaxPendingViewerFrames int        `json:"maxPendingViewerFrames"`
	MaxPendingWorkerFrames int        `json:"maxPendingWorkerFrames"`
	DroppedViewerFrames    int        `json:"droppedViewerFrames"`
	DroppedWorkerFrames    int        `json:"droppedWorkerFrames"`
	ViewerConnectEvents    int        `json:"viewerConnectEvents"`
	WorkerConnectEvents    int        `json:"workerConnectEvents"`
	ViewerDisconnectEvents int        `json:"viewerDisconnectEvents"`
	WorkerDisconnectEvents int        `json:"workerDisconnectEvents"`
	FramesToViewer         int        `json:"framesToViewer"`
	FramesToWorker         int        `json:"framesToWorker"`
	BytesToViewer          int        `json:"bytesToViewer"`
	BytesToWorker          int        `json:"bytesToWorker"`
	LastFrameRelayedAt     *time.Time `json:"lastFrameRelayedAt,omitempty"`
	Terminated             bool       `json:"terminated"`
	TerminationReason      string     `json:"terminationReason,omitempty"`
}

type mediaSessionState struct {
	viewer                 *signalConnection
	worker                 *signalConnection
	pendingViewer          [][]byte
	pendingWorker          [][]byte
	pendingViewerBytes     int
	pendingWorkerBytes     int
	maxPendingViewerFrames int
	maxPendingWorkerFrames int
	droppedViewerFrames    int
	droppedWorkerFrames    int
	viewerConnectEvents    int
	workerConnectEvents    int
	viewerDisconnectEvents int
	workerDisconnectEvents int
	framesToViewer         int
	framesToWorker         int
	bytesToViewer          int
	bytesToWorker          int
	lastFrameRelayedAt     time.Time
	terminated             bool
	terminationReason      string
}

func (s *Service) handleMediaRelay(w http.ResponseWriter, r *http.Request) {
	route, err := parseMediaRoute(r.URL.Path)
	if err != nil {
		httpx.WriteError(w, http.StatusNotFound, serviceName, "media relay route not found")
		return
	}
	ws, err := upgradeWebSocket(w, r)
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, serviceName, err.Error())
		return
	}
	go s.runMediaRelayConnection(route, ws)
}

func (s *Service) runMediaRelayConnection(route mediaRoute, ws *websocketConn) {
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
	if record.Response.WorkerBridge.RelayMode != relayModeGatewayMediaRelay ||
		record.Response.Transport.MediaTermination == nil ||
		!record.Response.Transport.MediaTermination.GatewayTerminatesMedia {
		_ = ws.WriteJSON(map[string]any{"type": "error", "message": "session is not using gateway media relay"})
		ws.CloseWithReason(1008, "media relay disabled")
		return
	}
	if s.isSignalSessionTerminated(route.SessionID) {
		_ = ws.WriteJSON(map[string]any{"type": "error", "message": "session is terminated"})
		ws.CloseWithReason(1008, "session terminated")
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

	conn := &signalConnection{
		id:        newOpaqueID("media_"),
		sessionID: route.SessionID,
		role:      route.Role,
		ws:        ws,
	}

	previous, pending, terminated := s.registerMediaConnection(route.SessionID, route.Role, conn)
	if terminated {
		_ = ws.WriteJSON(map[string]any{"type": "error", "message": "session is terminated"})
		ws.CloseWithReason(1008, "session terminated")
		return
	}
	if previous != nil {
		previous.ws.CloseWithReason(1000, "superseded by newer media connection")
	}

	_ = ws.WriteJSON(map[string]any{"type": "media-registered", "role": route.Role})
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
		if len(payload) > mediaRelayMaxWebSocketFrameBytes {
			_ = ws.WriteJSON(map[string]any{"type": "error", "message": "media relay payload exceeds maximum frame size"})
			ws.CloseWithReason(1009, "media relay payload too large")
			break
		}
		if !json.Valid(payload) {
			_ = ws.WriteJSON(map[string]any{"type": "error", "message": "media relay payload must be a JSON text envelope"})
			continue
		}
		s.forwardMedia(route.SessionID, oppositeRole(route.Role), payload)
	}

	s.unregisterMediaConnection(route.SessionID, route.Role, conn.id)
}

func (s *Service) registerMediaConnection(
	sessionID string,
	role string,
	conn *signalConnection,
) (*signalConnection, [][]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	state := s.mediaRelays[sessionID]
	if state == nil {
		state = &mediaSessionState{}
		s.mediaRelays[sessionID] = state
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

func (s *Service) unregisterMediaConnection(sessionID string, role string, connectionID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	state := s.mediaRelays[sessionID]
	if state == nil {
		return false
	}

	var current *signalConnection
	if role == "viewer" {
		current = state.viewer
	} else {
		current = state.worker
	}
	if current == nil || current.id != connectionID {
		return false
	}
	if role == "viewer" {
		state.viewer = nil
		state.viewerDisconnectEvents++
	} else {
		state.worker = nil
		state.workerDisconnectEvents++
	}
	return true
}

func (s *Service) forwardMedia(sessionID string, role string, payload []byte) {
	payload = append([]byte(nil), payload...)

	s.mu.RLock()
	state := s.mediaRelays[sessionID]
	var target *signalConnection
	if state != nil {
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
			s.noteForwardedMedia(sessionID, role, len(payload))
			return
		}
		target.ws.CloseWithReason(1011, "media relay failed")
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	state = s.mediaRelays[sessionID]
	if state == nil {
		state = &mediaSessionState{}
		s.mediaRelays[sessionID] = state
	}
	appendBoundedMediaPayloadLocked(state, role, payload)
	noteMediaRelayLocked(state, role, len(payload))
}

func appendBoundedMediaPayloadLocked(state *mediaSessionState, role string, payload []byte) {
	if role == "viewer" {
		state.pendingViewer = append(state.pendingViewer, payload)
		state.pendingViewerBytes += len(payload)
		for len(state.pendingViewer) > mediaRelayMaxPendingFrames ||
			state.pendingViewerBytes > mediaRelayMaxPendingBytesPerRole {
			state.pendingViewerBytes -= len(state.pendingViewer[0])
			state.pendingViewer = state.pendingViewer[1:]
			state.droppedViewerFrames++
		}
		if len(state.pendingViewer) > state.maxPendingViewerFrames {
			state.maxPendingViewerFrames = len(state.pendingViewer)
		}
		return
	}
	state.pendingWorker = append(state.pendingWorker, payload)
	state.pendingWorkerBytes += len(payload)
	for len(state.pendingWorker) > mediaRelayMaxPendingFrames ||
		state.pendingWorkerBytes > mediaRelayMaxPendingBytesPerRole {
		state.pendingWorkerBytes -= len(state.pendingWorker[0])
		state.pendingWorker = state.pendingWorker[1:]
		state.droppedWorkerFrames++
	}
	if len(state.pendingWorker) > state.maxPendingWorkerFrames {
		state.maxPendingWorkerFrames = len(state.pendingWorker)
	}
}

func (s *Service) noteForwardedMedia(sessionID string, role string, payloadBytes int) {
	s.mu.Lock()
	defer s.mu.Unlock()

	state := s.mediaRelays[sessionID]
	if state == nil {
		state = &mediaSessionState{}
		s.mediaRelays[sessionID] = state
	}
	noteMediaRelayLocked(state, role, payloadBytes)
}

func noteMediaRelayLocked(state *mediaSessionState, role string, payloadBytes int) {
	state.lastFrameRelayedAt = time.Now().UTC()
	if role == "viewer" {
		state.framesToViewer++
		state.bytesToViewer += payloadBytes
		return
	}
	state.framesToWorker++
	state.bytesToWorker += payloadBytes
}

func (s *Service) terminateMediaRelaySession(sessionID string, reason string) {
	s.mu.Lock()
	state := s.mediaRelays[sessionID]
	if state == nil {
		s.mu.Unlock()
		return
	}
	if state.terminated {
		s.mu.Unlock()
		return
	}
	state.terminated = true
	state.terminationReason = reason
	viewer := state.viewer
	worker := state.worker
	state.viewer = nil
	state.worker = nil
	state.pendingViewer = nil
	state.pendingWorker = nil
	state.pendingViewerBytes = 0
	state.pendingWorkerBytes = 0
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

func (s *Service) snapshotMediaRelayStateLocked(sessionID string) *MediaRelayStateSnapshot {
	state := s.mediaRelays[sessionID]
	if state == nil {
		return nil
	}
	return &MediaRelayStateSnapshot{
		ViewerConnected:        state.viewer != nil,
		WorkerConnected:        state.worker != nil,
		PendingViewerFrames:    len(state.pendingViewer),
		PendingWorkerFrames:    len(state.pendingWorker),
		PendingViewerBytes:     state.pendingViewerBytes,
		PendingWorkerBytes:     state.pendingWorkerBytes,
		MaxPendingViewerFrames: state.maxPendingViewerFrames,
		MaxPendingWorkerFrames: state.maxPendingWorkerFrames,
		DroppedViewerFrames:    state.droppedViewerFrames,
		DroppedWorkerFrames:    state.droppedWorkerFrames,
		ViewerConnectEvents:    state.viewerConnectEvents,
		WorkerConnectEvents:    state.workerConnectEvents,
		ViewerDisconnectEvents: state.viewerDisconnectEvents,
		WorkerDisconnectEvents: state.workerDisconnectEvents,
		FramesToViewer:         state.framesToViewer,
		FramesToWorker:         state.framesToWorker,
		BytesToViewer:          state.bytesToViewer,
		BytesToWorker:          state.bytesToWorker,
		LastFrameRelayedAt:     cloneTimePointer(state.lastFrameRelayedAt),
		Terminated:             state.terminated,
		TerminationReason:      state.terminationReason,
	}
}

func parseMediaRoute(path string) (mediaRoute, error) {
	trimmed := strings.TrimSuffix(path, "/")
	parts := strings.Split(trimmed, "/")
	if len(parts) != 5 || parts[1] != "gateway" || parts[2] != "media" {
		return mediaRoute{}, errors.New("invalid media relay path")
	}
	if parts[4] != "viewer" && parts[4] != "worker" {
		return mediaRoute{}, errors.New("invalid media relay role")
	}
	sessionID, err := url.PathUnescape(parts[3])
	if err != nil || sessionID == "" {
		return mediaRoute{}, errors.New("invalid media relay session id")
	}
	return mediaRoute{
		SessionID: sessionID,
		Role:      parts[4],
	}, nil
}
