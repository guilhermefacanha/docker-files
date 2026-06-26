package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"dsf-lab-builder/internal/docker"
	"dsf-lab-builder/internal/env"
	"dsf-lab-builder/internal/runner"
)

type Handler struct {
	Cfg *env.Config
}

func (h *Handler) Register(mux *http.ServeMux) {
	// Env lifecycle
	mux.HandleFunc("GET /api/envs", h.listEnvs)
	mux.HandleFunc("POST /api/envs", h.deployEnv)
	mux.HandleFunc("GET /api/envs/{id}", h.getEnv)
	mux.HandleFunc("DELETE /api/envs/{id}", h.deleteEnv)

	// RDS — literal sub-paths registered before wildcard to take precedence
	mux.HandleFunc("GET /api/envs/{id}/rds/suggest", h.suggestRDS)   // ?engine=X
	mux.HandleFunc("GET /api/envs/{id}/rds/detail", h.getRDSDetail)  // ?instance=X
	mux.HandleFunc("POST /api/envs/{id}/rds", h.createRDS)

	// FAM
	mux.HandleFunc("POST /api/envs/{id}/fam", h.createFAM)

	// Tests
	mux.HandleFunc("POST /api/envs/{id}/test/rds/{engine}", h.testRDS)
	mux.HandleFunc("POST /api/envs/{id}/test/fam", h.testFAM)

	// FAM background generator
	mux.HandleFunc("POST /api/envs/{id}/generator/fam/start", h.startFAMGenerator)
	mux.HandleFunc("POST /api/envs/{id}/generator/fam/stop", h.stopFAMGenerator)
	mux.HandleFunc("GET /api/envs/{id}/generator/fam/logs", h.getFAMGeneratorLogs)

	// RDS background generator (per instance)
	mux.HandleFunc("POST /api/envs/{id}/generator/rds/start", h.startRDSGenerator)
	mux.HandleFunc("POST /api/envs/{id}/generator/rds/stop", h.stopRDSGenerator)
	mux.HandleFunc("GET /api/envs/{id}/generator/rds/logs", h.getRDSGeneratorLogs)

	// Asset export
	mux.HandleFunc("GET /api/envs/{id}/export", h.exportAssets)

	// Job streaming
	mux.HandleFunc("GET /api/jobs/{id}", h.getJob)
	mux.HandleFunc("GET /api/jobs/{id}/stream", h.streamJob)
}

// ── env lifecycle ─────────────────────────────────────────────────────────────

func (h *Handler) listEnvs(w http.ResponseWriter, r *http.Request) {
	envs, err := docker.ListEnvs()
	if err != nil {
		writeError(w, 500, err.Error())
		return
	}
	writeJSON(w, envs)
}

func (h *Handler) deployEnv(w http.ResponseWriter, r *http.Request) {
	slot, err := env.DetectNextSlot(h.Cfg)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	job := env.Deploy(slot, h.Cfg)
	writeJSON(w, map[string]string{"jobId": job.ID})
}

func (h *Handler) getEnv(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	envs, err := docker.ListEnvs()
	if err != nil {
		writeError(w, 500, err.Error())
		return
	}
	for _, e := range envs {
		if e.ID == id {
			detail, err := env.GetDetail(e, h.Cfg)
			if err != nil {
				writeError(w, 500, err.Error())
				return
			}
			// Annotate RDS instances with generator running state
			for i := range detail.RDBS {
				detail.RDBS[i].GeneratorRunning = env.IsRDSGenRunning(env.RDSGenKey(id, detail.RDBS[i].ID))
			}
			writeJSON(w, detail)
			return
		}
	}
	writeError(w, 404, "env not found: "+id)
}

func (h *Handler) deleteEnv(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	slot := slotFromID(id)
	if slot == 0 {
		writeError(w, 400, "cannot delete the default env")
		return
	}
	job := env.Destroy(slot, h.Cfg)
	writeJSON(w, map[string]string{"jobId": job.ID})
}

// ── resource operations ───────────────────────────────────────────────────────

func (h *Handler) createRDS(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var body struct {
		Engine     string `json:"engine"`
		InstanceID string `json:"instanceId"` // empty = auto-select; set after confirmation dialog
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Engine == "" {
		writeError(w, 400, `body must be {"engine":"postgres|mysql|mariadb","instanceId":"..."}`)
		return
	}
	e, err := findEnv(id)
	if err != nil {
		writeError(w, 404, err.Error())
		return
	}

	// When no instanceId is provided, check for existing instances of this engine.
	// If any exist, return 409 with confirmation data so the frontend can ask the user.
	if body.InstanceID == "" {
		existing, suggested, err := env.SuggestNextRDS(e, body.Engine)
		if err != nil {
			writeError(w, 500, err.Error())
			return
		}
		if len(existing) > 0 {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusConflict)
			json.NewEncoder(w).Encode(map[string]interface{}{
				"confirm":   true,
				"existing":  existing,
				"suggested": suggested,
			})
			return
		}
		body.InstanceID = suggested
	}

	job, err := env.CreateRDS(e, body.Engine, body.InstanceID, h.Cfg)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	writeJSON(w, map[string]string{"jobId": job.ID, "instanceId": body.InstanceID})
}

func (h *Handler) suggestRDS(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	engine := r.URL.Query().Get("engine")
	if engine == "" {
		writeError(w, 400, "engine query param required")
		return
	}
	e, err := findEnv(id)
	if err != nil {
		writeError(w, 404, err.Error())
		return
	}
	existing, suggested, err := env.SuggestNextRDS(e, engine)
	if err != nil {
		writeError(w, 500, err.Error())
		return
	}
	writeJSON(w, map[string]interface{}{"existing": existing, "suggested": suggested})
}

func (h *Handler) getRDSDetail(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	instanceID := r.URL.Query().Get("instance")
	if instanceID == "" {
		writeError(w, 400, "instance query param required")
		return
	}
	e, err := findEnv(id)
	if err != nil {
		writeError(w, 404, err.Error())
		return
	}
	detail, err := env.GetRDSDetail(e, instanceID, h.Cfg)
	if err != nil {
		writeError(w, 500, err.Error())
		return
	}
	writeJSON(w, detail)
}

func (h *Handler) createFAM(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	e, err := findEnv(id)
	if err != nil {
		writeError(w, 404, err.Error())
		return
	}
	job, err := env.CreateFAM(e, h.Cfg)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	writeJSON(w, map[string]string{"jobId": job.ID})
}

func (h *Handler) testRDS(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	engine := r.PathValue("engine")
	// Optional instanceId in body — forwards which specific instance to test
	var body struct {
		InstanceID string `json:"instanceId"`
	}
	json.NewDecoder(r.Body).Decode(&body) //nolint — body is optional
	e, err := findEnv(id)
	if err != nil {
		writeError(w, 404, err.Error())
		return
	}
	job, err := env.TestRDS(e, engine, body.InstanceID, h.Cfg)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	writeJSON(w, map[string]string{"jobId": job.ID})
}

func (h *Handler) testFAM(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	e, err := findEnv(id)
	if err != nil {
		writeError(w, 404, err.Error())
		return
	}
	job, err := env.TestFAM(e, h.Cfg)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	writeJSON(w, map[string]string{"jobId": job.ID})
}

// ── FAM generator ─────────────────────────────────────────────────────────────

func (h *Handler) startFAMGenerator(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	e, err := findEnv(id)
	if err != nil {
		writeError(w, 404, err.Error())
		return
	}
	if err := env.StartGenerator(e, h.Cfg); err != nil {
		writeError(w, 400, err.Error())
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (h *Handler) stopFAMGenerator(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := env.StopGenerator(id); err != nil {
		writeError(w, 400, err.Error())
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (h *Handler) getFAMGeneratorLogs(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	lines, _ := env.GeneratorLogs(id, 100, h.Cfg)
	_, running := env.Generators[id]
	writeJSON(w, map[string]interface{}{"lines": lines, "running": running})
}

// ── RDS generator ─────────────────────────────────────────────────────────────

func (h *Handler) startRDSGenerator(w http.ResponseWriter, r *http.Request) {
	envID := r.PathValue("id")
	var body struct {
		InstanceID string `json:"instanceId"`
		Engine     string `json:"engine"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.InstanceID == "" {
		writeError(w, 400, `body must be {"instanceId":"...","engine":"postgres|mysql|mariadb"}`)
		return
	}

	// Resolve the RDS endpoint from the live env
	e, err := findEnv(envID)
	if err != nil {
		writeError(w, 404, err.Error())
		return
	}
	detail, err := env.GetDetail(e, h.Cfg)
	if err != nil {
		writeError(w, 500, err.Error())
		return
	}
	var host, port string
	for _, rds := range detail.RDBS {
		if rds.ID == body.InstanceID {
			parts := strings.SplitN(rds.Endpoint, ":", 2)
			if len(parts) == 2 {
				host, port = parts[0], parts[1]
			}
			if body.Engine == "" {
				body.Engine = rds.Engine
			}
			break
		}
	}
	if host == "" {
		writeError(w, 404, "RDS instance not found or endpoint missing: "+body.InstanceID)
		return
	}

	if err := env.StartRDSGen(envID, body.InstanceID, body.Engine, host, port, h.Cfg); err != nil {
		writeError(w, 400, err.Error())
		return
	}
	writeJSON(w, map[string]string{"ok": "true", "key": env.RDSGenKey(envID, body.InstanceID)})
}

func (h *Handler) stopRDSGenerator(w http.ResponseWriter, r *http.Request) {
	envID := r.PathValue("id")
	var body struct {
		InstanceID string `json:"instanceId"`
	}
	json.NewDecoder(r.Body).Decode(&body)
	key := env.RDSGenKey(envID, body.InstanceID)
	if err := env.StopRDSGen(key); err != nil {
		writeError(w, 400, err.Error())
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (h *Handler) getRDSGeneratorLogs(w http.ResponseWriter, r *http.Request) {
	envID := r.PathValue("id")
	instanceID := r.URL.Query().Get("instance")
	key := env.RDSGenKey(envID, instanceID)
	lines, running, stats := env.GetRDSGenStatus(key, 100)
	writeJSON(w, map[string]interface{}{"lines": lines, "running": running, "stats": stats})
}

// ── asset export ──────────────────────────────────────────────────────────────

func (h *Handler) exportAssets(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	serverIP := r.URL.Query().Get("serverIP")
	gatewayName := r.URL.Query().Get("gatewayName")

	e, err := findEnv(id)
	if err != nil {
		writeError(w, 404, err.Error())
		return
	}
	data, err := env.ExportAssetsXLSX(e, serverIP, gatewayName, h.Cfg)
	if err != nil {
		writeError(w, 500, err.Error())
		return
	}
	filename := id + "-dsf-assets.xlsx"
	w.Header().Set("Content-Type", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
	w.Header().Set("Content-Disposition", `attachment; filename="`+filename+`"`)
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(data)))
	w.Write(data)
}

// ── jobs ──────────────────────────────────────────────────────────────────────

func (h *Handler) getJob(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	j := runner.Get(id)
	if j == nil {
		writeError(w, 404, "job not found")
		return
	}
	writeJSON(w, j)
}

func (h *Handler) streamJob(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	j := runner.Get(id)
	if j == nil {
		writeError(w, 404, "job not found")
		return
	}
	j.Stream(w, r)
}

// ── helpers ───────────────────────────────────────────────────────────────────

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func findEnv(id string) (docker.EnvSummary, error) {
	envs, err := docker.ListEnvs()
	if err != nil {
		return docker.EnvSummary{}, err
	}
	for _, e := range envs {
		if e.ID == id {
			return e, nil
		}
	}
	return docker.EnvSummary{}, fmt.Errorf("env not found: %s", id)
}

func slotFromID(id string) int {
	if !strings.HasPrefix(id, "floci-env") {
		return 0
	}
	n := 0
	for _, c := range id[len("floci-env"):] {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}
