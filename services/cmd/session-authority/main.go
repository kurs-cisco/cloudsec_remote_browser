package main

import (
	"log"
	"net/http"
	"os"

	"cloudsec_remote_browser/services/internal/sessionauthority"
)

func main() {
	addr := os.Getenv("SESSION_AUTHORITY_ADDR")
	if addr == "" {
		addr = ":18081"
	}

	handler := sessionauthority.NewService(sessionauthority.LoadConfigFromEnv()).Handler()

	log.Printf("session-authority listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, handler))
}
