package env

// gcp_generator.go — continuous SQL traffic generator for GCP Cloud SQL instances.
// Connects via the socat host-port proxy started by the setup script.
// Reuses the same rdsGen engine (database/sql + lib/pq) — only the key and
// connection details differ.

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

var (
	gcpGens   = map[string]*rdsGen{}
	gcpGensMu sync.Mutex
)

func GCPGenKey(envID, instanceID string) string { return "gcp:" + envID + ":" + instanceID }

func StartGCPGen(envID, instanceID string, proxyPort int, cfg *Config) error {
	key := GCPGenKey(envID, instanceID)

	logDir := filepath.Join(cfg.Workspace, "gcp-gen-logs")
	os.MkdirAll(logDir, 0755)
	f, err := os.Create(filepath.Join(logDir, "cloudsql-gen-"+instanceID+".log"))
	if err != nil {
		return fmt.Errorf("create log: %w", err)
	}

	gcpGensMu.Lock()
	defer gcpGensMu.Unlock()
	if _, ok := gcpGens[key]; ok {
		f.Close()
		return fmt.Errorf("generator already running for %s", instanceID)
	}
	g := &rdsGen{
		stop:       make(chan struct{}),
		logFile:    f,
		instanceID: instanceID,
		masterUser: "admin",
		masterPass: "secret123",
	}
	gcpGens[key] = g
	go g.run("postgres", "localhost", fmt.Sprintf("%d", proxyPort))
	return nil
}

func StopGCPGen(key string) error {
	gcpGensMu.Lock()
	g, ok := gcpGens[key]
	if !ok {
		gcpGensMu.Unlock()
		return fmt.Errorf("no GCP generator running for %s", key)
	}
	delete(gcpGens, key)
	gcpGensMu.Unlock()
	close(g.stop)
	return nil
}

func GetGCPGenStatus(key string, n int) (lines []string, running bool, stats RDSGenStats) {
	gcpGensMu.Lock()
	g, running := gcpGens[key]
	gcpGensMu.Unlock()
	if !running || g == nil {
		return nil, false, RDSGenStats{}
	}
	g.mu.Lock()
	all := g.lines
	stats = g.stats
	g.mu.Unlock()
	if len(all) > n {
		all = all[len(all)-n:]
	}
	return append([]string(nil), all...), true, stats
}

func IsGCPGenRunning(key string) bool {
	gcpGensMu.Lock()
	defer gcpGensMu.Unlock()
	_, ok := gcpGens[key]
	return ok
}
