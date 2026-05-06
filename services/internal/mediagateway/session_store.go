package mediagateway

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

type gatewayInstance struct {
	ID      string `json:"id"`
	BaseURL string `json:"baseUrl"`
}

type gatewayStoredSession struct {
	Record   SessionRecord   `json:"record"`
	Owner    gatewayInstance `json:"owner"`
	StoredAt time.Time       `json:"storedAt"`
}

type gatewaySessionStore interface {
	SaveSession(ctx context.Context, record SessionRecord, owner gatewayInstance) error
	GetSession(ctx context.Context, sessionID string) (SessionRecord, gatewayInstance, bool, error)
	DeleteSession(ctx context.Context, sessionID string) error
}

type redisGatewaySessionStore struct {
	client *redis.Client
	prefix string
	ttl    time.Duration
}

func newRedisGatewaySessionStore(redisURL string, useTLS bool, keyPrefix string, ttl time.Duration) gatewaySessionStore {
	options, err := redis.ParseURL(redisURL)
	if err != nil {
		options = &redis.Options{Addr: redisURL}
	}
	if useTLS && options.TLSConfig == nil {
		options.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	}
	if ttl <= 0 {
		ttl = defaultGatewaySessionStoreTTL
	}
	return &redisGatewaySessionStore{
		client: redis.NewClient(options),
		prefix: strings.Trim(strings.TrimSpace(keyPrefix), ":"),
		ttl:    ttl,
	}
}

func (s *redisGatewaySessionStore) SaveSession(ctx context.Context, record SessionRecord, owner gatewayInstance) error {
	if record.Request.SessionID == "" {
		return errors.New("missing session id")
	}
	payload, err := json.Marshal(gatewayStoredSession{
		Record:   record,
		Owner:    owner,
		StoredAt: time.Now().UTC(),
	})
	if err != nil {
		return err
	}
	return s.client.Set(ctx, s.sessionKey(record.Request.SessionID), payload, s.ttl).Err()
}

func (s *redisGatewaySessionStore) GetSession(ctx context.Context, sessionID string) (SessionRecord, gatewayInstance, bool, error) {
	raw, err := s.client.Get(ctx, s.sessionKey(sessionID)).Bytes()
	if errors.Is(err, redis.Nil) {
		return SessionRecord{}, gatewayInstance{}, false, nil
	}
	if err != nil {
		return SessionRecord{}, gatewayInstance{}, false, err
	}
	var stored gatewayStoredSession
	if err := json.Unmarshal(raw, &stored); err != nil {
		return SessionRecord{}, gatewayInstance{}, false, err
	}
	return stored.Record, stored.Owner, true, nil
}

func (s *redisGatewaySessionStore) DeleteSession(ctx context.Context, sessionID string) error {
	return s.client.Del(ctx, s.sessionKey(sessionID)).Err()
}

func (s *redisGatewaySessionStore) sessionKey(sessionID string) string {
	prefix := s.prefix
	if prefix == "" {
		prefix = "cloudsec-rbi"
	}
	return prefix + ":media-gateway:sessions:" + sessionID
}

func (s *Service) storeSession(ctx context.Context, record SessionRecord) error {
	if s.sessionStore == nil {
		return nil
	}
	return s.sessionStore.SaveSession(ctx, record, s.instance)
}

func (s *Service) getStoredSession(ctx context.Context, sessionID string) (SessionRecord, gatewayInstance, bool) {
	if s.sessionStore == nil {
		return SessionRecord{}, gatewayInstance{}, false
	}
	record, owner, ok, err := s.sessionStore.GetSession(ctx, sessionID)
	if err != nil || !ok {
		return SessionRecord{}, gatewayInstance{}, false
	}
	return record, owner, true
}

func (s *Service) deleteStoredSession(ctx context.Context, sessionID string) {
	if s.sessionStore == nil {
		return
	}
	_ = s.sessionStore.DeleteSession(ctx, sessionID)
}

func (s *Service) getSessionWithOwner(ctx context.Context, sessionID string) (SessionRecord, gatewayInstance, bool) {
	s.mu.RLock()
	record, ok := s.sessions[sessionID]
	if ok {
		record.SignalState = s.snapshotSignalStateLocked(sessionID)
		record.MediaRelayState = s.snapshotMediaRelayStateLocked(sessionID)
		record.WebRTCRelayState = s.snapshotWebRTCRelayStateLocked(sessionID)
	}
	s.mu.RUnlock()
	if ok {
		return record, s.instance, true
	}

	record, owner, ok := s.getStoredSession(ctx, sessionID)
	if !ok {
		return SessionRecord{}, gatewayInstance{}, false
	}
	if s.isLocalGatewayOwner(owner) {
		s.ensureLocalSessionRecord(record)
		return record, s.instance, true
	}
	return record, owner, true
}

func (s *Service) ensureLocalSessionRecord(record SessionRecord) {
	if record.Request.SessionID == "" {
		return
	}
	s.mu.Lock()
	if _, ok := s.sessions[record.Request.SessionID]; !ok {
		s.sessions[record.Request.SessionID] = record
	}
	s.mu.Unlock()
}

func (s *Service) isLocalGatewayOwner(owner gatewayInstance) bool {
	if owner.ID != "" && s.instance.ID != "" && owner.ID == s.instance.ID {
		return true
	}
	if owner.BaseURL != "" && s.instance.BaseURL != "" &&
		strings.EqualFold(strings.TrimRight(owner.BaseURL, "/"), strings.TrimRight(s.instance.BaseURL, "/")) {
		return true
	}
	return owner.ID == "" && owner.BaseURL == ""
}

func defaultGatewayInstanceBaseURL() string {
	port := gatewayListenPort()
	if podIP := strings.TrimSpace(os.Getenv("POD_IP")); podIP != "" {
		return "http://" + net.JoinHostPort(podIP, port)
	}
	if hostIP := firstNonLoopbackIPv4(); hostIP != "" {
		return "http://" + net.JoinHostPort(hostIP, port)
	}
	return "http://" + net.JoinHostPort("127.0.0.1", port)
}

func gatewayListenPort() string {
	addr := strings.TrimSpace(os.Getenv("MEDIA_GATEWAY_ADDR"))
	if addr == "" {
		return "18082"
	}
	if strings.HasPrefix(addr, ":") {
		return strings.TrimPrefix(addr, ":")
	}
	if parsed, err := url.Parse("tcp://" + addr); err == nil && parsed.Port() != "" {
		return parsed.Port()
	}
	if _, port, err := net.SplitHostPort(addr); err == nil && port != "" {
		return port
	}
	return "18082"
}

func firstNonLoopbackIPv4() string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch value := addr.(type) {
			case *net.IPNet:
				ip = value.IP
			case *net.IPAddr:
				ip = value.IP
			}
			if ip == nil || ip.IsLoopback() {
				continue
			}
			if ipv4 := ip.To4(); ipv4 != nil {
				return ipv4.String()
			}
		}
	}
	return ""
}
