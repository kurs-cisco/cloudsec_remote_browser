package httpx

import (
	"encoding/json"
	"net/http"
)

type ErrorResponse struct {
	Error   string `json:"error"`
	Service string `json:"service"`
}

func WriteJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func WriteError(w http.ResponseWriter, status int, service, message string) {
	WriteJSON(w, status, ErrorResponse{
		Error:   message,
		Service: service,
	})
}

func MethodNotAllowed(w http.ResponseWriter, service string, allow ...string) {
	if len(allow) > 0 {
		w.Header().Set("Allow", allow[0])
	}
	WriteError(w, http.StatusMethodNotAllowed, service, "method not allowed")
}
