package main

import (
	"log"
	"net/http"
	"os"
	"path/filepath"

	"dsf-lab-builder/internal/api"
	"dsf-lab-builder/internal/env"
)

func main() {
	// All paths default to siblings of wherever the binary is run from.
	// Override with env vars if needed (e.g. running binary from a different directory).
	cwd, _ := os.Getwd()

	workspace := envOr("WORKSPACE", filepath.Join(cwd, "workspace"))
	scriptsDir := envOr("SCRIPTS_DIR", filepath.Join(cwd, "scripts"))
	staticDir := envOr("STATIC_DIR", filepath.Join(cwd, "static"))
	port := envOr("PORT", "8080")

	cfg := &env.Config{
		Workspace:  workspace,
		ScriptsDir: scriptsDir,
		MaxSlots:   5,
	}

	mux := http.NewServeMux()
	h := &api.Handler{Cfg: cfg}
	h.Register(mux)
	mux.Handle("/", http.FileServer(http.Dir(staticDir)))

	log.Printf("DSF Lab Builder  http://localhost:%s", port)
	log.Printf("  workspace : %s", workspace)
	log.Printf("  scripts   : %s", scriptsDir)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatal(err)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
