package main

import (
	"log"
	"net/http"
	"os"

	"cloudsec_remote_browser/services/internal/mediagateway"
)

func main() {
	addr := os.Getenv("MEDIA_GATEWAY_ADDR")
	if addr == "" {
		addr = ":18082"
	}

	handler := mediagateway.NewService(mediagateway.LoadConfigFromEnv()).Handler()

	log.Printf("media-gateway listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, handler))
}
