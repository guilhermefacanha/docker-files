package main

import (
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"dsf-lab-builder/internal/api"
	"dsf-lab-builder/internal/env"
)

func main() {
	// All paths default to siblings of wherever the binary is run from.
	// Override with env vars if needed (e.g. running binary from a different directory).
	cwd, _ := os.Getwd()

	// If run from the parent directory (e.g. GoLand sets cwd to docker-files/),
	// fall back to the dsf-lab-builder subdirectory.
	root := cwd
	if !dirExists(filepath.Join(cwd, "static")) && dirExists(filepath.Join(cwd, "dsf-lab-builder", "static")) {
		root = filepath.Join(cwd, "dsf-lab-builder")
		log.Printf("  auto-root      : %s", root)
	}

	workspace := envOr("WORKSPACE", filepath.Join(root, "workspace"))
	scriptsDir := envOr("SCRIPTS_DIR", filepath.Join(root, "scripts"))
	gcpScriptsDir := envOr("GCP_SCRIPTS_DIR", filepath.Join(root, "scripts", "gcp"))
	azureScriptsDir := envOr("AZURE_SCRIPTS_DIR", filepath.Join(root, "scripts", "azure"))
	staticDir := envOr("STATIC_DIR", filepath.Join(root, "static"))
	port := envOr("PORT", "8080")
	contextPath := strings.Trim(envOr("CONTEXT_PATH", ""), "/")

	cfg := &env.Config{
		Workspace:       workspace,
		ScriptsDir:      scriptsDir,
		GCPScriptsDir:   gcpScriptsDir,
		AzureScriptsDir: azureScriptsDir,
		MaxSlots:        5,
	}

	sub := http.NewServeMux()
	h := &api.Handler{Cfg: cfg}
	h.Register(sub)
	sub.Handle("/", http.FileServer(http.Dir(staticDir)))

	mux := http.NewServeMux()
	urlPath := "/"
	if contextPath != "" {
		prefix := "/" + contextPath
		urlPath = prefix + "/"
		mux.Handle(prefix+"/", http.StripPrefix(prefix, sub))
		// Redirect bare prefix and root to prefix+/
		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, prefix+"/", http.StatusMovedPermanently)
		})
	} else {
		mux.Handle("/", sub)
	}
	log.Printf("DSF Lab Builder  http://localhost:%s%s", port, urlPath)
	log.Printf("  cwd            : %s", cwd)
	log.Printf("  workspace      : %s  (exists=%v)", workspace, dirExists(workspace))
	log.Printf("  scripts        : %s  (exists=%v)", scriptsDir, dirExists(scriptsDir))
	log.Printf("  gcp-scripts    : %s  (exists=%v)", gcpScriptsDir, dirExists(gcpScriptsDir))
	log.Printf("  azure-scripts  : %s  (exists=%v)", azureScriptsDir, dirExists(azureScriptsDir))
	log.Printf("  static         : %s  (exists=%v)", staticDir, dirExists(staticDir))
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

func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
