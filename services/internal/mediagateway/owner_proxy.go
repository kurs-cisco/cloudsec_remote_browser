package mediagateway

import (
	"bytes"
	"io"
	"net/http"
	"strings"

	"cloudsec_remote_browser/services/internal/httpx"
)

const gatewayForwardedHeader = "X-RBI-Gateway-Forwarded"

func (s *Service) shouldProxyToOwner(owner gatewayInstance) bool {
	return owner.BaseURL != "" && !s.isLocalGatewayOwner(owner)
}

func (s *Service) proxyOwnerRequest(w http.ResponseWriter, r *http.Request, owner gatewayInstance, body []byte) bool {
	if !s.shouldProxyToOwner(owner) {
		return false
	}
	if r.Header.Get(gatewayForwardedHeader) == "1" {
		httpx.WriteError(w, http.StatusBadGateway, serviceName, "gateway owner routing loop detected")
		return true
	}

	target := strings.TrimRight(owner.BaseURL, "/") + r.URL.RequestURI()
	req, err := http.NewRequestWithContext(r.Context(), r.Method, target, bytes.NewReader(body))
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, serviceName, "gateway owner request invalid")
		return true
	}
	req.Header = r.Header.Clone()
	req.Header.Del("Host")
	req.Header.Set(gatewayForwardedHeader, "1")

	timeout := s.cfg.ForwardRequestTimeout
	if timeout <= 0 {
		timeout = defaultGatewayForwardTimeout
	}
	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, serviceName, "gateway owner unavailable")
		return true
	}
	defer resp.Body.Close()

	for key, values := range resp.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, io.LimitReader(resp.Body, 4*1024*1024))
	return true
}
