package mediagateway

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
)

const (
	pionRelayMaxPendingDataMessages = 512
	pionRelayPointerBufferHighBytes = 16 * 1024
	pionRelayGatherTimeout          = 5 * time.Second
	pionRelayPLIInterval            = time.Second
	pionRelayInitialPLIDuration     = 4 * time.Second
)

type queuedDataMessage struct {
	payload  []byte
	isString bool
}

type pionRelaySession struct {
	service *Service

	sessionID   string
	viewerToken string
	workerToken string

	mu       sync.Mutex
	workerPC *webrtc.PeerConnection
	viewerPC *webrtc.PeerConnection

	videoTrack        *webrtc.TrackLocalStaticRTP
	audioTrack        *webrtc.TrackLocalStaticRTP
	viewerVideoSender *webrtc.RTPSender
	viewerAudioSender *webrtc.RTPSender

	workerChannels  map[string]*webrtc.DataChannel
	viewerChannels  map[string]*webrtc.DataChannel
	pendingToWorker map[string][]queuedDataMessage
	pendingToViewer map[string][]queuedDataMessage

	workerPeerState string
	viewerPeerState string
	workerICEState  string
	viewerICEState  string
	workerTracks    int
	viewerTracks    int
	workerVideoSSRC uint32

	rtpPacketsToViewer     int64
	rtpBytesToViewer       int64
	rtcpPacketsToWorker    int64
	rtcpFeedbackByType     map[string]int64
	dataMessagesToWorker   int64
	dataMessagesToViewer   int64
	pointerDroppedMessages int64
	controlDroppedMessages int64
	lastRTPRelayedAt       time.Time
	lastRTCPForwardedAt    time.Time
	lastDataForwardedAt    time.Time

	terminated        bool
	terminationReason string
}

func (s *Service) getOrCreatePionRelaySession(record SessionRecord) (*pionRelaySession, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if relay := s.webrtcRelays[record.Response.SessionID]; relay != nil {
		return relay, nil
	}

	videoTrack, err := webrtc.NewTrackLocalStaticRTP(
		webrtc.RTPCodecCapability{
			MimeType:     webrtc.MimeTypeVP8,
			ClockRate:    90000,
			RTCPFeedback: videoRTCPFeedback(),
		},
		"video",
		"desktop",
	)
	if err != nil {
		return nil, err
	}
	audioTrack, err := webrtc.NewTrackLocalStaticRTP(
		webrtc.RTPCodecCapability{
			MimeType:  webrtc.MimeTypeOpus,
			ClockRate: 48000,
			Channels:  2,
		},
		"audio",
		"desktop",
	)
	if err != nil {
		return nil, err
	}

	relay := &pionRelaySession{
		service:            s,
		sessionID:          record.Response.SessionID,
		viewerToken:        record.Request.ViewerToken,
		workerToken:        record.Request.WorkerToken,
		videoTrack:         videoTrack,
		audioTrack:         audioTrack,
		workerChannels:     map[string]*webrtc.DataChannel{},
		viewerChannels:     map[string]*webrtc.DataChannel{},
		pendingToWorker:    map[string][]queuedDataMessage{},
		pendingToViewer:    map[string][]queuedDataMessage{},
		rtcpFeedbackByType: map[string]int64{},
	}
	s.webrtcRelays[record.Response.SessionID] = relay
	return relay, nil
}

func (p *pionRelaySession) handleOffer(role string, sdp string) (string, error) {
	switch role {
	case "worker":
		return p.handleWorkerOffer(sdp)
	case "viewer":
		return p.handleViewerOffer(sdp)
	default:
		return "", &apiError{status: 404, message: "invalid webrtc relay role"}
	}
}

func (p *pionRelaySession) handleWorkerOffer(sdp string) (string, error) {
	pc, err := p.newWorkerPeer()
	if err != nil {
		return "", err
	}
	p.mu.Lock()
	oldWorkerPC := p.workerPC
	p.workerPC = pc
	p.workerPeerState = pc.ConnectionState().String()
	p.workerICEState = pc.ICEConnectionState().String()
	p.mu.Unlock()
	if oldWorkerPC != nil {
		_ = oldWorkerPC.Close()
	}
	return p.answerOffer(pc, sdp)
}

func (p *pionRelaySession) handleViewerOffer(sdp string) (string, error) {
	pc, err := p.newViewerPeer()
	if err != nil {
		return "", err
	}
	p.mu.Lock()
	oldViewerPC := p.viewerPC
	p.viewerPC = pc
	p.viewerPeerState = pc.ConnectionState().String()
	p.viewerICEState = pc.ICEConnectionState().String()
	p.mu.Unlock()
	if oldViewerPC != nil {
		_ = oldViewerPC.Close()
	}
	return p.answerOffer(pc, sdp)
}

func (p *pionRelaySession) handleICE(role string, candidate webrtc.ICECandidateInit) error {
	p.mu.Lock()
	var pc *webrtc.PeerConnection
	if role == "worker" {
		pc = p.workerPC
	} else {
		pc = p.viewerPC
	}
	p.mu.Unlock()
	if pc == nil {
		return &apiError{status: 409, message: "webrtc peer is not ready for trickle ice"}
	}
	return pc.AddICECandidate(candidate)
}

func (p *pionRelaySession) newWorkerPeer() (*webrtc.PeerConnection, error) {
	api, err := p.service.newPionAPI()
	if err != nil {
		return nil, err
	}
	pc, err := api.NewPeerConnection(p.service.pionConfiguration())
	if err != nil {
		return nil, err
	}
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		_ = pc.Close()
		return nil, err
	}
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio, webrtc.RTPTransceiverInit{
		Direction: webrtc.RTPTransceiverDirectionRecvonly,
	}); err != nil {
		_ = pc.Close()
		return nil, err
	}
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		p.handlePeerConnectionStateChange("worker", pc, state)
	})
	pc.OnICEConnectionStateChange(func(state webrtc.ICEConnectionState) {
		p.handlePeerICEConnectionStateChange("worker", pc, state)
	})
	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		p.registerWorkerDataChannel(dc)
	})
	pc.OnTrack(func(track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		p.registerWorkerTrack(track, receiver)
	})
	return pc, nil
}

func (p *pionRelaySession) newViewerPeer() (*webrtc.PeerConnection, error) {
	api, err := p.service.newPionAPI()
	if err != nil {
		return nil, err
	}
	pc, err := api.NewPeerConnection(p.service.pionConfiguration())
	if err != nil {
		return nil, err
	}

	videoSender, err := pc.AddTrack(p.videoTrack)
	if err != nil {
		_ = pc.Close()
		return nil, err
	}
	audioSender, err := pc.AddTrack(p.audioTrack)
	if err != nil {
		_ = pc.Close()
		return nil, err
	}
	p.mu.Lock()
	p.viewerVideoSender = videoSender
	p.viewerAudioSender = audioSender
	p.viewerTracks = 2
	p.mu.Unlock()
	go p.drainViewerRTCP(videoSender, "video")
	go p.drainViewerRTCP(audioSender, "audio")

	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		p.handlePeerConnectionStateChange("viewer", pc, state)
	})
	pc.OnICEConnectionStateChange(func(state webrtc.ICEConnectionState) {
		p.handlePeerICEConnectionStateChange("viewer", pc, state)
	})
	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		p.registerViewerDataChannel(dc)
	})
	return pc, nil
}

func (p *pionRelaySession) handlePeerConnectionStateChange(role string, pc *webrtc.PeerConnection, state webrtc.PeerConnectionState) {
	if !p.notePeerStateIfCurrent(role, pc, state.String(), false) {
		return
	}
	if isTerminalPeerConnectionState(state) {
		p.close(role + " peer " + state.String())
	}
}

func (p *pionRelaySession) handlePeerICEConnectionStateChange(role string, pc *webrtc.PeerConnection, state webrtc.ICEConnectionState) {
	if !p.notePeerStateIfCurrent(role, pc, state.String(), true) {
		return
	}
	if isTerminalICEConnectionState(state) {
		p.close(role + " ice " + state.String())
	}
}

func (p *pionRelaySession) notePeerStateIfCurrent(role string, pc *webrtc.PeerConnection, state string, ice bool) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.terminated {
		return false
	}
	switch role {
	case "worker":
		if pc != nil && p.workerPC != pc {
			return false
		}
		if ice {
			p.workerICEState = state
		} else {
			p.workerPeerState = state
		}
		return true
	case "viewer":
		if pc != nil && p.viewerPC != pc {
			return false
		}
		if ice {
			p.viewerICEState = state
		} else {
			p.viewerPeerState = state
		}
		return true
	default:
		return false
	}
}

func isTerminalPeerConnectionState(state webrtc.PeerConnectionState) bool {
	switch state {
	case webrtc.PeerConnectionStateDisconnected,
		webrtc.PeerConnectionStateFailed,
		webrtc.PeerConnectionStateClosed:
		return true
	default:
		return false
	}
}

func isTerminalICEConnectionState(state webrtc.ICEConnectionState) bool {
	switch state {
	case webrtc.ICEConnectionStateDisconnected,
		webrtc.ICEConnectionStateFailed,
		webrtc.ICEConnectionStateClosed:
		return true
	default:
		return false
	}
}

func (p *pionRelaySession) answerOffer(pc *webrtc.PeerConnection, sdp string) (string, error) {
	if err := pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP:  sdp,
	}); err != nil {
		return "", err
	}
	gatherComplete := webrtc.GatheringCompletePromise(pc)
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return "", err
	}
	if err := pc.SetLocalDescription(answer); err != nil {
		return "", err
	}

	select {
	case <-gatherComplete:
	case <-time.After(pionRelayGatherTimeout):
	}
	local := pc.LocalDescription()
	if local == nil || strings.TrimSpace(local.SDP) == "" {
		return "", errors.New("gateway did not produce an SDP answer")
	}
	return local.SDP, nil
}

func (p *pionRelaySession) registerWorkerTrack(track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
	mimeType := strings.ToLower(track.Codec().MimeType)
	if track.Kind() == webrtc.RTPCodecTypeVideo && mimeType != strings.ToLower(webrtc.MimeTypeVP8) {
		p.close("unsupported worker video codec: " + track.Codec().MimeType)
		return
	}
	if track.Kind() == webrtc.RTPCodecTypeAudio && mimeType != strings.ToLower(webrtc.MimeTypeOpus) {
		p.close("unsupported worker audio codec: " + track.Codec().MimeType)
		return
	}

	p.mu.Lock()
	p.workerTracks++
	if track.Kind() == webrtc.RTPCodecTypeVideo {
		p.workerVideoSSRC = uint32(track.SSRC())
	}
	p.mu.Unlock()

	go p.drainWorkerRTCP(receiver)
	if track.Kind() == webrtc.RTPCodecTypeVideo {
		go p.sendInitialPLI(uint32(track.SSRC()))
	}
	go p.forwardWorkerRTP(track)
}

func (p *pionRelaySession) forwardWorkerRTP(track *webrtc.TrackRemote) {
	for {
		packet, _, err := track.ReadRTP()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				p.close("worker rtp read failed: " + err.Error())
			}
			return
		}
		packet.Header.Extensions = nil
		packet.Header.Extension = false

		var writeErr error
		if track.Kind() == webrtc.RTPCodecTypeVideo {
			writeErr = p.videoTrack.WriteRTP(packet)
		} else if track.Kind() == webrtc.RTPCodecTypeAudio {
			writeErr = p.audioTrack.WriteRTP(packet)
		}
		if writeErr != nil {
			continue
		}
		p.mu.Lock()
		p.rtpPacketsToViewer++
		p.rtpBytesToViewer += int64(packet.MarshalSize())
		p.lastRTPRelayedAt = time.Now().UTC()
		p.mu.Unlock()
	}
}

func (p *pionRelaySession) drainWorkerRTCP(receiver *webrtc.RTPReceiver) {
	for {
		if _, _, err := receiver.ReadRTCP(); err != nil {
			return
		}
	}
}

func (p *pionRelaySession) drainViewerRTCP(sender *webrtc.RTPSender, kind string) {
	for {
		packets, _, err := sender.ReadRTCP()
		if err != nil {
			return
		}
		packets = p.rewriteViewerRTCP(kind, packets)
		if len(packets) == 0 {
			continue
		}
		p.mu.Lock()
		workerPC := p.workerPC
		p.mu.Unlock()
		if workerPC != nil {
			if err := workerPC.WriteRTCP(packets); err == nil {
				p.noteRTCPForwarded(packets)
			}
		}
	}
}

func (p *pionRelaySession) rewriteViewerRTCP(kind string, packets []rtcp.Packet) []rtcp.Packet {
	if kind != "video" {
		return packets
	}
	p.mu.Lock()
	workerSSRC := p.workerVideoSSRC
	p.mu.Unlock()
	if workerSSRC == 0 {
		return nil
	}
	for _, packet := range packets {
		switch pkt := packet.(type) {
		case *rtcp.PictureLossIndication:
			pkt.MediaSSRC = workerSSRC
		case *rtcp.FullIntraRequest:
			pkt.MediaSSRC = workerSSRC
			for i := range pkt.FIR {
				pkt.FIR[i].SSRC = workerSSRC
			}
		case *rtcp.TransportLayerNack:
			pkt.MediaSSRC = workerSSRC
		}
	}
	return packets
}

func (p *pionRelaySession) sendInitialPLI(ssrc uint32) {
	deadline := time.Now().Add(pionRelayInitialPLIDuration)
	ticker := time.NewTicker(pionRelayPLIInterval)
	defer ticker.Stop()
	for {
		if p.isTerminated() {
			return
		}
		p.sendPLI(ssrc)
		if time.Now().After(deadline) {
			return
		}
		<-ticker.C
	}
}

func (p *pionRelaySession) sendPLI(ssrc uint32) {
	p.mu.Lock()
	workerPC := p.workerPC
	p.mu.Unlock()
	if workerPC == nil || ssrc == 0 {
		return
	}
	packets := []rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: ssrc}}
	if err := workerPC.WriteRTCP(packets); err == nil {
		p.noteRTCPForwarded(packets)
	}
}

func (p *pionRelaySession) registerWorkerDataChannel(dc *webrtc.DataChannel) {
	label := dc.Label()
	p.mu.Lock()
	p.workerChannels[label] = dc
	p.mu.Unlock()
	dc.SetBufferedAmountLowThreshold(pionRelayPointerBufferHighBytes / 2)
	dc.OnOpen(func() {
		p.flushPendingToWorker(label)
	})
	dc.OnBufferedAmountLow(func() {
		p.flushPendingToWorker(label)
	})
	dc.OnMessage(func(msg webrtc.DataChannelMessage) {
		p.forwardDataToViewer(label, queuedDataMessage{
			payload:  append([]byte(nil), msg.Data...),
			isString: msg.IsString,
		})
	})
	if dc.ReadyState() == webrtc.DataChannelStateOpen {
		p.flushPendingToWorker(label)
	}
}

func (p *pionRelaySession) registerViewerDataChannel(dc *webrtc.DataChannel) {
	label := dc.Label()
	p.mu.Lock()
	p.viewerChannels[label] = dc
	p.mu.Unlock()
	dc.SetBufferedAmountLowThreshold(pionRelayPointerBufferHighBytes / 2)
	dc.OnOpen(func() {
		p.flushPendingToViewer(label)
	})
	dc.OnBufferedAmountLow(func() {
		p.flushPendingToViewer(label)
	})
	dc.OnMessage(func(msg webrtc.DataChannelMessage) {
		p.forwardDataToWorker(label, queuedDataMessage{
			payload:  append([]byte(nil), msg.Data...),
			isString: msg.IsString,
		})
	})
	if dc.ReadyState() == webrtc.DataChannelStateOpen {
		p.flushPendingToViewer(label)
	}
}

func (p *pionRelaySession) forwardDataToWorker(label string, msg queuedDataMessage) {
	p.mu.Lock()
	target := p.workerChannels[label]
	if canSendDataChannel(target) && !(isPointerChannel(label) && target.BufferedAmount() > pionRelayPointerBufferHighBytes) {
		p.mu.Unlock()
		if err := sendDataChannelMessage(target, msg); err == nil {
			p.mu.Lock()
			p.dataMessagesToWorker++
			p.lastDataForwardedAt = time.Now().UTC()
			p.mu.Unlock()
		}
		return
	}
	p.enqueueDataMessageLocked(p.pendingToWorker, label, msg, true)
	p.mu.Unlock()
}

func (p *pionRelaySession) forwardDataToViewer(label string, msg queuedDataMessage) {
	p.mu.Lock()
	target := p.viewerChannels[label]
	if canSendDataChannel(target) {
		p.mu.Unlock()
		if err := sendDataChannelMessage(target, msg); err == nil {
			p.mu.Lock()
			p.dataMessagesToViewer++
			p.lastDataForwardedAt = time.Now().UTC()
			p.mu.Unlock()
		}
		return
	}
	p.enqueueDataMessageLocked(p.pendingToViewer, label, msg, false)
	p.mu.Unlock()
}

func (p *pionRelaySession) enqueueDataMessageLocked(
	queue map[string][]queuedDataMessage,
	label string,
	msg queuedDataMessage,
	viewerToWorker bool,
) {
	if isPointerChannel(label) {
		if len(queue[label]) > 0 {
			p.pointerDroppedMessages += int64(len(queue[label]))
		}
		queue[label] = []queuedDataMessage{msg}
		return
	}
	queue[label] = append(queue[label], msg)
	for len(queue[label]) > pionRelayMaxPendingDataMessages {
		queue[label] = queue[label][1:]
		if viewerToWorker {
			p.controlDroppedMessages++
		}
	}
}

func (p *pionRelaySession) flushPendingToWorker(label string) {
	p.flushPending(label, true)
}

func (p *pionRelaySession) flushPendingToViewer(label string) {
	p.flushPending(label, false)
}

func (p *pionRelaySession) flushPending(label string, toWorker bool) {
	for {
		p.mu.Lock()
		var target *webrtc.DataChannel
		var queue map[string][]queuedDataMessage
		if toWorker {
			target = p.workerChannels[label]
			queue = p.pendingToWorker
		} else {
			target = p.viewerChannels[label]
			queue = p.pendingToViewer
		}
		if !canSendDataChannel(target) || len(queue[label]) == 0 {
			p.mu.Unlock()
			return
		}
		msg := queue[label][0]
		queue[label] = queue[label][1:]
		p.mu.Unlock()

		if err := sendDataChannelMessage(target, msg); err != nil {
			p.mu.Lock()
			queue[label] = append([]queuedDataMessage{msg}, queue[label]...)
			p.mu.Unlock()
			return
		}
		p.mu.Lock()
		if toWorker {
			p.dataMessagesToWorker++
		} else {
			p.dataMessagesToViewer++
		}
		p.lastDataForwardedAt = time.Now().UTC()
		p.mu.Unlock()
	}
}

func (p *pionRelaySession) close(reason string) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		reason = "webrtc relay closed"
	}
	p.mu.Lock()
	if p.terminated {
		p.mu.Unlock()
		return
	}
	p.terminated = true
	p.terminationReason = reason
	workerPC := p.workerPC
	viewerPC := p.viewerPC
	workerChannels := cloneDataChannels(p.workerChannels)
	viewerChannels := cloneDataChannels(p.viewerChannels)
	p.workerPC = nil
	p.viewerPC = nil
	p.viewerVideoSender = nil
	p.viewerAudioSender = nil
	p.workerChannels = map[string]*webrtc.DataChannel{}
	p.viewerChannels = map[string]*webrtc.DataChannel{}
	p.pendingToWorker = map[string][]queuedDataMessage{}
	p.pendingToViewer = map[string][]queuedDataMessage{}
	p.workerVideoSSRC = 0
	p.mu.Unlock()

	for _, dc := range workerChannels {
		_ = dc.Close()
	}
	for _, dc := range viewerChannels {
		_ = dc.Close()
	}
	if workerPC != nil {
		_ = workerPC.Close()
	}
	if viewerPC != nil {
		_ = viewerPC.Close()
	}
	if p.service != nil {
		p.service.cleanupWebRTCRelaySession(p.sessionID, reason)
	}
}

func (p *pionRelaySession) isTerminated() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.terminated
}

func (p *pionRelaySession) noteRTCPForwarded(packets []rtcp.Packet) {
	now := time.Now().UTC()
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.rtcpFeedbackByType == nil {
		p.rtcpFeedbackByType = map[string]int64{}
	}
	p.rtcpPacketsToWorker += int64(len(packets))
	for _, packet := range packets {
		p.rtcpFeedbackByType[rtcpFeedbackType(packet)]++
	}
	p.lastRTCPForwardedAt = now
}

func (s *Service) terminateWebRTCRelaySession(sessionID string, reason string) {
	s.mu.RLock()
	relay := s.webrtcRelays[sessionID]
	s.mu.RUnlock()
	if relay != nil {
		relay.close(reason)
	}
}

func (s *Service) cleanupWebRTCRelaySession(sessionID string, reason string) {
	s.terminateSignalSession(sessionID, reason)
	s.terminateMediaRelaySession(sessionID, reason)
	s.deleteStoredSession(context.Background(), sessionID)
	go func() {
		_ = s.notifyRuntimeEvent(sessionID, "gateway", 0, "media-terminated", "", reason)
	}()
}

func (p *pionRelaySession) snapshot() *WebRTCRelayStateSnapshot {
	p.mu.Lock()
	defer p.mu.Unlock()
	return &WebRTCRelayStateSnapshot{
		WorkerPeerState:        p.workerPeerState,
		ViewerPeerState:        p.viewerPeerState,
		WorkerICEState:         p.workerICEState,
		ViewerICEState:         p.viewerICEState,
		WorkerTracks:           p.workerTracks,
		ViewerTracks:           p.viewerTracks,
		RTPPacketsToViewer:     p.rtpPacketsToViewer,
		RTPBytesToViewer:       p.rtpBytesToViewer,
		RTCPPacketsToWorker:    p.rtcpPacketsToWorker,
		RTCPFeedbackByType:     cloneStringInt64Map(p.rtcpFeedbackByType),
		DataMessagesToWorker:   p.dataMessagesToWorker,
		DataMessagesToViewer:   p.dataMessagesToViewer,
		PointerDroppedMessages: p.pointerDroppedMessages,
		ControlDroppedMessages: p.controlDroppedMessages,
		PendingPointerMessages: len(p.pendingToWorker[inputPointerChannelName]),
		PendingControlMessages: len(p.pendingToWorker[inputControlChannelName]),
		WorkerDataChannels:     sortedDataChannelLabels(p.workerChannels),
		ViewerDataChannels:     sortedDataChannelLabels(p.viewerChannels),
		LastRTPRelayedAt:       cloneTimePointer(p.lastRTPRelayedAt),
		LastRTCPForwardedAt:    cloneTimePointer(p.lastRTCPForwardedAt),
		LastDataForwardedAt:    cloneTimePointer(p.lastDataForwardedAt),
		Terminated:             p.terminated,
		TerminationReason:      p.terminationReason,
	}
}

func (s *Service) newPionAPI() (*webrtc.API, error) {
	mediaEngine := &webrtc.MediaEngine{}
	if err := mediaEngine.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:     webrtc.MimeTypeVP8,
			ClockRate:    90000,
			RTCPFeedback: videoRTCPFeedback(),
		},
		PayloadType: 96,
	}, webrtc.RTPCodecTypeVideo); err != nil {
		return nil, err
	}
	if err := mediaEngine.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:     webrtc.MimeTypeOpus,
			ClockRate:    48000,
			Channels:     2,
			SDPFmtpLine:  "minptime=10;useinbandfec=1",
			RTCPFeedback: nil,
		},
		PayloadType: 111,
	}, webrtc.RTPCodecTypeAudio); err != nil {
		return nil, err
	}
	registry := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(mediaEngine, registry); err != nil {
		return nil, err
	}
	return webrtc.NewAPI(webrtc.WithMediaEngine(mediaEngine), webrtc.WithInterceptorRegistry(registry)), nil
}

func (s *Service) pionConfiguration() webrtc.Configuration {
	servers := make([]webrtc.ICEServer, 0, len(s.cfg.ICEURLs))
	for _, url := range s.cfg.ICEURLs {
		normalized := strings.TrimSpace(url)
		if normalized == "" {
			continue
		}
		server := webrtc.ICEServer{URLs: []string{normalized}}
		if isTURNURL(normalized) {
			username, password := s.turnCredentials()
			if username == "" || password == "" {
				continue
			}
			server.Username = username
			server.Credential = password
		}
		servers = append(servers, server)
	}
	return webrtc.Configuration{ICEServers: servers}
}

func isTURNURL(rawURL string) bool {
	lower := strings.ToLower(strings.TrimSpace(rawURL))
	return strings.HasPrefix(lower, "turn:") || strings.HasPrefix(lower, "turns:")
}

func (s *Service) turnCredentials() (string, string) {
	if strings.TrimSpace(s.cfg.TURNUsername) != "" && strings.TrimSpace(s.cfg.TURNPassword) != "" {
		return strings.TrimSpace(s.cfg.TURNUsername), strings.TrimSpace(s.cfg.TURNPassword)
	}
	secret := strings.TrimSpace(s.cfg.TURNSharedSecret)
	if secret == "" {
		return "", ""
	}
	ttl := s.cfg.TURNCredentialTTL
	if ttl <= 0 {
		ttl = 300 * time.Second
	}
	username := fmt.Sprintf("%d:media-gateway.%s", time.Now().Add(ttl).Unix(), s.cfg.GatewayID)
	mac := hmac.New(sha1.New, []byte(secret))
	_, _ = mac.Write([]byte(username))
	return username, base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func videoRTCPFeedback() []webrtc.RTCPFeedback {
	return []webrtc.RTCPFeedback{
		{Type: "goog-remb"},
		{Type: "ccm", Parameter: "fir"},
		{Type: "nack"},
		{Type: "nack", Parameter: "pli"},
	}
}

func sendDataChannelMessage(dc *webrtc.DataChannel, msg queuedDataMessage) error {
	if !canSendDataChannel(dc) {
		return fmt.Errorf("data channel %q is not open", dc.Label())
	}
	if msg.isString {
		return dc.SendText(string(msg.payload))
	}
	return dc.Send(msg.payload)
}

func canSendDataChannel(dc *webrtc.DataChannel) bool {
	return dc != nil && dc.ReadyState() == webrtc.DataChannelStateOpen
}

func cloneDataChannels(source map[string]*webrtc.DataChannel) []*webrtc.DataChannel {
	channels := make([]*webrtc.DataChannel, 0, len(source))
	for _, channel := range source {
		if channel != nil {
			channels = append(channels, channel)
		}
	}
	return channels
}

func cloneStringInt64Map(source map[string]int64) map[string]int64 {
	if len(source) == 0 {
		return map[string]int64{}
	}
	clone := make(map[string]int64, len(source))
	for key, value := range source {
		clone[key] = value
	}
	return clone
}

func rtcpFeedbackType(packet rtcp.Packet) string {
	switch pkt := packet.(type) {
	case *rtcp.PictureLossIndication:
		return "pli"
	case *rtcp.FullIntraRequest:
		return "fir"
	case *rtcp.TransportLayerNack:
		return "nack"
	case *rtcp.ReceiverEstimatedMaximumBitrate:
		return "remb"
	default:
		if pkt == nil {
			return "unknown"
		}
		return strings.TrimSpace(fmt.Sprintf("%T", pkt))
	}
}

func isPointerChannel(label string) bool {
	return label == inputPointerChannelName
}

func sortedDataChannelLabels(channels map[string]*webrtc.DataChannel) []string {
	labels := make([]string, 0, len(channels))
	for label := range channels {
		labels = append(labels, label)
	}
	sort.Strings(labels)
	return labels
}
