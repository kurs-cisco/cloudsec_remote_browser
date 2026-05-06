package main

import (
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"

	"cloudsec_remote_browser/services/internal/clipboardbroker"
)

func main() {
	addr := getenv("CLIPBOARD_BROKER_ADDR", ":8094")
	service := clipboardbroker.NewService(clipboardbroker.Config{
		MaxTextBytes:      getenvInt64("CLIPBOARD_BROKER_MAX_TEXT_BYTES", 16*1024),
		AllowedDirections: csv("CLIPBOARD_BROKER_ALLOWED_DIRECTIONS"),
		AllowedFormats:    csv("CLIPBOARD_BROKER_ALLOWED_FORMATS"),
		TTLSeconds:        int(getenvInt64("CLIPBOARD_BROKER_TTL_SECONDS", 120)),
		FallbackProvider:  getenv("RBI_FALLBACK_PROVIDER", "menlo"),
	})
	log.Printf("starting clipboard broker on %s", addr)
	if err := http.ListenAndServe(addr, service.Handler()); err != nil {
		log.Fatal(err)
	}
}

func getenv(key string, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func getenvInt64(key string, fallback int64) int64 {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed <= 0 {
		return fallback
	}
	return parsed
}

func csv(key string) []string {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return nil
	}
	items := strings.Split(raw, ",")
	out := make([]string, 0, len(items))
	for _, item := range items {
		if trimmed := strings.TrimSpace(item); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}
