package env

// azure_generator.go — continuous SQL traffic generator for Azure Database instances.
// Connects via the socat host-port proxy started by the setup script.
// Reuses the same rdsGen engine (database/sql) — only the key and connection details differ.

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

var (
	azGens   = map[string]*rdsGen{}
	azGensMu sync.Mutex
)

func AZGenKey(envID, instanceID string) string { return "az:" + envID + ":" + instanceID }

func StartAZGen(envID, instanceID, engine string, proxyPort int, cfg *Config) error {
	key := AZGenKey(envID, instanceID)

	logDir := filepath.Join(cfg.Workspace, "az-gen-logs")
	os.MkdirAll(logDir, 0755) //nolint:errcheck
	f, err := os.Create(filepath.Join(logDir, "azdb-gen-"+instanceID+".log"))
	if err != nil {
		return fmt.Errorf("create log: %w", err)
	}

	azGensMu.Lock()
	defer azGensMu.Unlock()
	if _, ok := azGens[key]; ok {
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
	azGens[key] = g
	go g.run(engine, "localhost", fmt.Sprintf("%d", proxyPort))
	return nil
}

func StopAZGen(key string) error {
	azGensMu.Lock()
	g, ok := azGens[key]
	if !ok {
		azGensMu.Unlock()
		return fmt.Errorf("no Azure generator running for %s", key)
	}
	delete(azGens, key)
	azGensMu.Unlock()
	close(g.stop)
	return nil
}

func GetAZGenStatus(key string, n int) (lines []string, running bool, stats RDSGenStats) {
	azGensMu.Lock()
	g, running := azGens[key]
	azGensMu.Unlock()
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

func IsAZGenRunning(key string) bool {
	azGensMu.Lock()
	defer azGensMu.Unlock()
	_, ok := azGens[key]
	return ok
}
