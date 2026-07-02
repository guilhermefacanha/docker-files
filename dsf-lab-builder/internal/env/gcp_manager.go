package env

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"dsf-lab-builder/internal/docker"
	"dsf-lab-builder/internal/runner"
)

// ── Types ──────────────────────────────────────────────────────────────────────

type GCPDetail struct {
	docker.EnvSummary
	CloudSQL []CloudSQLInstance `json:"cloudSQL"`
}

type CloudSQLInstance struct {
	ID       string `json:"id"`
	Engine   string `json:"engine"`
	Status   string `json:"status"`
	Endpoint string `json:"endpoint"`
}

type CloudSQLDetail struct {
	ID             string `json:"id"`
	Engine         string `json:"engine"`
	EngineVersion  string `json:"engineVersion"`
	Status         string `json:"status"`
	Host           string `json:"host"`
	Port           int    `json:"port"`
	Endpoint       string `json:"endpoint"`
	ProxyHost      string `json:"proxyHost"`
	ProxyPort      int    `json:"proxyPort"`
	MasterUser     string `json:"masterUser"`
	MasterPass     string `json:"masterPass"`
	AuditUser      string `json:"auditUser"`
	AuditPass      string `json:"auditPass"`
	ProjectID      string `json:"projectId"`
	Region         string `json:"region"`
	TopicName      string `json:"topicName"`
	SubscriptionID string `json:"subscriptionId"`
	LogSinkName    string `json:"logSinkName"`
	ServiceAccount string `json:"serviceAccount"`
	FlociEndpoint  string `json:"flociEndpoint"`
}

// ── Slot detection ────────────────────────────────────────────────────────────

// DetectNextGCPSlot finds the lowest free slot for a GCP env (ports 4689+, 8101+).
func DetectNextGCPSlot(cfg *Config) (int, error) {
	used, err := docker.GetUsedPorts()
	if err != nil {
		return 0, err
	}
	for n := 1; n <= cfg.MaxSlots; n++ {
		if used[4688+n] {
			continue
		}
		conflict := false
		for p := 8000 + n*100 + 1; p <= 8000+n*100+99; p++ {
			if used[p] {
				conflict = true
				break
			}
		}
		if !conflict {
			return n, nil
		}
	}
	return 0, fmt.Errorf("all GCP slots 1-%d are in use", cfg.MaxSlots)
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

func DeployGCP(slot int, cfg *Config) *runner.Job {
	projectName := fmt.Sprintf("floci-gcp%d", slot)
	envDir := gcpEnvDirPath(slot, cfg)

	script := fmt.Sprintf(`set -e
echo "=== Copying GCP scripts to %s ==="
mkdir -p "%s"
cp -r "%s/." "%s"

echo "=== Writing .env for GCP slot %d ==="
cat > "%s/.env" << 'ENVEOF'
%sENVEOF

echo "=== Starting docker compose for %s ==="
docker compose \
  -f "%s/docker-compose.yml" \
  --project-directory "%s" \
  --project-name "%s" \
  --env-file "%s/.env" \
  up -d --build

echo "=== Done! %s is up ==="
`,
		envDir,
		envDir,
		cfg.GCPScriptsDir, envDir,
		slot,
		envDir, buildGCPEnvFile(slot),
		projectName,
		envDir, envDir, projectName, envDir,
		projectName,
	)

	cmd := exec.Command("bash", "-c", script)
	return runner.Start("deploy-gcp", projectName, cmd)
}

func DestroyGCP(slot int, cfg *Config) *runner.Job {
	projectName := fmt.Sprintf("floci-gcp%d", slot)
	envDir := gcpEnvDirPath(slot, cfg)

	script := fmt.Sprintf(`set -e
echo "=== Stopping %s ==="
docker compose \
  -f "%s/docker-compose.yml" \
  --project-directory "%s" \
  --project-name "%s" \
  down --volumes --remove-orphans 2>/dev/null || true

echo "=== Removing env directory ==="
rm -rf "%s"
echo "=== Done ==="
`,
		projectName,
		envDir, envDir, projectName,
		envDir,
	)

	cmd := exec.Command("bash", "-c", script)
	return runner.Start("destroy-gcp", projectName, cmd)
}

// ── Detail ────────────────────────────────────────────────────────────────────

func GetGCPDetail(e docker.EnvSummary, cfg *Config) (*GCPDetail, error) {
	d := &GCPDetail{EnvSummary: e}
	if e.Status != "running" || e.FlociPort == 0 {
		return d, nil
	}

	endpoint := fmt.Sprintf("http://localhost:%d", e.FlociPort)
	projectID := e.AccountID // set to floci-gcp-lab-{slot} by docker client

	instances, _ := listCloudSQLInstances(endpoint, projectID)
	d.CloudSQL = instances
	return d, nil
}

func listCloudSQLInstances(endpoint, projectID string) ([]CloudSQLInstance, error) {
	url := fmt.Sprintf("%s/sql/v1beta4/projects/%s/instances", endpoint, projectID)
	resp, err := http.Get(url) //nolint:gosec
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	var result struct {
		Items []struct {
			Name            string `json:"name"`
			DatabaseVersion string `json:"databaseVersion"`
			State           string `json:"state"`
			IPAddresses     []struct {
				IPAddress string `json:"ipAddress"`
			} `json:"ipAddresses"`
		} `json:"items"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, err
	}

	var out []CloudSQLInstance
	for _, item := range result.Items {
		engine := cloudSQLEngine(item.DatabaseVersion)
		port := cloudSQLPort(engine)
		ip := ""
		if len(item.IPAddresses) > 0 {
			ip = item.IPAddresses[0].IPAddress
		}
		endpoint := ""
		if ip != "" {
			endpoint = fmt.Sprintf("%s:%d", ip, port)
		}
		out = append(out, CloudSQLInstance{
			ID:       item.Name,
			Engine:   engine,
			Status:   item.State,
			Endpoint: endpoint,
		})
	}
	return out, nil
}

// ── Cloud SQL CRUD ────────────────────────────────────────────────────────────

func TestCloudSQL(e docker.EnvSummary, engine, instanceID string, cfg *Config) (*runner.Job, error) {
	slot := docker.GCPSlotFromID(e.ID)
	if slot == 0 {
		return nil, fmt.Errorf("invalid GCP env ID: %s", e.ID)
	}
	dir := gcpEnvDirPath(slot, cfg)
	envFile := filepath.Join(dir, ".env")

	cmd := exec.Command("bash", "-c", fmt.Sprintf(
		`set -e
source "%s"
export GCP_ENDPOINT_URL GCP_PROJECT_ID GCP_REGION
export ENGINE="%s"
export CLOUDSQL_INSTANCE_NAME="%s"
bash "%s/service-cloudsql-test-traffic.sh"`,
		envFile, engine, instanceID, dir))
	cmd.Dir = dir
	return runner.Start("test-cloudsql-"+engine, e.ID, cmd), nil
}

func CreateCloudSQL(e docker.EnvSummary, engine, instanceID string, cfg *Config) (*runner.Job, error) {
	scripts := map[string]string{
		"postgres": "service-cloudsql-postgres-dsf-setup.sh",
	}
	script, ok := scripts[engine]
	if !ok {
		return nil, fmt.Errorf("unsupported engine: %s", engine)
	}
	slot := docker.GCPSlotFromID(e.ID)
	if slot == 0 {
		return nil, fmt.Errorf("invalid GCP env ID: %s", e.ID)
	}
	dir := gcpEnvDirPath(slot, cfg)
	envFile := filepath.Join(dir, ".env")

	cmd := exec.Command("bash", "-c", fmt.Sprintf(
		`set -e
source "%s"
export GCP_ENDPOINT_URL GCP_PROJECT_ID GCP_REGION
export CLOUDSQL_INSTANCE_NAME="%s"
bash "%s/%s"`,
		envFile, instanceID, dir, script))
	cmd.Dir = dir
	return runner.Start("create-cloudsql-"+engine, e.ID, cmd), nil
}

func SuggestNextCloudSQL(e docker.EnvSummary, engine string) (existing []string, suggested string, err error) {
	if e.FlociPort == 0 {
		return nil, "", fmt.Errorf("GCP env not running")
	}
	endpoint := fmt.Sprintf("http://localhost:%d", e.FlociPort)
	instances, err := listCloudSQLInstances(endpoint, e.AccountID)
	if err != nil {
		return nil, "", err
	}

	prefix := cloudSQLInstancePrefix(engine, e.ID)
	for _, inst := range instances {
		if strings.HasPrefix(inst.ID, prefix) {
			existing = append(existing, inst.ID)
		}
	}
	suggested = nextCloudSQLInstanceID(prefix, existing)
	return existing, suggested, nil
}

func GetCloudSQLDetail(e docker.EnvSummary, instanceID string, cfg *Config) (*CloudSQLDetail, error) {
	if e.FlociPort == 0 {
		return nil, fmt.Errorf("GCP env not running")
	}
	endpoint := fmt.Sprintf("http://localhost:%d", e.FlociPort)
	projectID := e.AccountID

	url := fmt.Sprintf("%s/sql/v1beta4/projects/%s/instances/%s", endpoint, projectID, instanceID)
	resp, err := http.Get(url) //nolint:gosec
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	var inst struct {
		Name            string `json:"name"`
		DatabaseVersion string `json:"databaseVersion"`
		State           string `json:"state"`
		Region          string `json:"region"`
		IPAddresses     []struct {
			IPAddress string `json:"ipAddress"`
		} `json:"ipAddresses"`
	}
	if err := json.Unmarshal(body, &inst); err != nil || inst.Name == "" {
		return nil, fmt.Errorf("instance %s not found", instanceID)
	}

	engine := cloudSQLEngine(inst.DatabaseVersion)
	port := cloudSQLPort(engine)
	ip := ""
	if len(inst.IPAddresses) > 0 {
		ip = inst.IPAddresses[0].IPAddress
	}

	topicName := instanceID + "-audit-topic"
	subID := instanceID + "-dsf-sub"
	proxyHost, proxyPort := cloudSQLProxyPort(instanceID)

	return &CloudSQLDetail{
		ID:             instanceID,
		Engine:         engine,
		EngineVersion:  inst.DatabaseVersion,
		Status:         inst.State,
		Host:           ip,
		Port:           port,
		Endpoint:       fmt.Sprintf("%s:%d", ip, port),
		ProxyHost:      proxyHost,
		ProxyPort:      proxyPort,
		MasterUser:     "admin",
		MasterPass:     "secret123",
		AuditUser:      "auditmgr",
		AuditPass:      "AuditMgr$ecret1",
		ProjectID:      projectID,
		Region:         coalesce(inst.Region, "us-central1"),
		TopicName:      fmt.Sprintf("projects/%s/topics/%s", projectID, topicName),
		SubscriptionID: fmt.Sprintf("projects/%s/subscriptions/%s", projectID, subID),
		LogSinkName:    "dsf-cloudsql-sink",
		ServiceAccount: fmt.Sprintf("dsf-gateway@%s.iam.gserviceaccount.com", projectID),
		FlociEndpoint:  endpoint,
	}, nil
}

// ── helpers ───────────────────────────────────────────────────────────────────

func gcpEnvDirPath(slot int, cfg *Config) string {
	return filepath.Join(cfg.Workspace, fmt.Sprintf("gcp-env%d", slot))
}

func buildGCPEnvFile(slot int) string {
	gcpPort := 4688 + slot
	sqlBase := 8000 + slot*100 + 1
	sqlEnd := 8000 + slot*100 + 99
	projectID := fmt.Sprintf("floci-gcp-lab-%d", slot)
	network := fmt.Sprintf("floci-gcp%d_default", slot)
	suffix := fmt.Sprintf("-gcp%d", slot)

	return fmt.Sprintf(`FLOCI_GCP_PORT=%d
CLOUDSQL_PORT_RANGE=%d-%d
CLOUDSQL_PROXY_BASE_PORT=%d
CLOUDSQL_PROXY_MAX_PORT=%d
FLOCI_GCP_NETWORK=%s
GCP_PROJECT_ID=%s
GCP_ENDPOINT_URL=http://localhost:%d
GCP_REGION=us-central1
ENV_SUFFIX=%s
`,
		gcpPort,
		sqlBase, sqlEnd,
		sqlBase, sqlEnd,
		network,
		projectID,
		gcpPort,
		suffix,
	)
}

// cloudSQLProxyPort inspects the running socat proxy container for this instance
// and returns ("localhost", port) if found, or ("", 0) if not running.
func cloudSQLProxyPort(instanceID string) (string, int) {
	name := "cloudsql-proxy-" + instanceID
	out, err := exec.Command("docker", "inspect",
		"--format", `{{range $p,$b := .NetworkSettings.Ports}}{{if $b}}{{(index $b 0).HostPort}}{{end}}{{end}}`,
		name).Output()
	if err != nil {
		return "", 0
	}
	portStr := strings.TrimSpace(string(out))
	if portStr == "" {
		return "", 0
	}
	p, err := strconv.Atoi(portStr)
	if err != nil {
		return "", 0
	}
	return "localhost", p
}

func cloudSQLEngine(dbVersion string) string {
	v := strings.ToLower(dbVersion)
	if strings.Contains(v, "postgres") {
		return "postgres"
	}
	if strings.Contains(v, "mysql") {
		return "mysql"
	}
	return strings.ToLower(dbVersion)
}

func cloudSQLPort(engine string) int {
	if engine == "postgres" {
		return 5432
	}
	return 3306
}

func cloudSQLMasterUser(engine string) string {
	if engine == "postgres" {
		return "postgres"
	}
	return "root"
}

func cloudSQLInstancePrefix(engine, envID string) string {
	nameMap := map[string]string{
		"postgres": "mypostgres",
	}
	name := nameMap[engine]
	if name == "" {
		name = "my" + engine
	}
	slot := docker.GCPSlotFromID(envID)
	return fmt.Sprintf("%s-gcp%d-dsf", name, slot)
}

func nextCloudSQLInstanceID(base string, existing []string) string {
	if len(existing) == 0 {
		return base
	}
	max := 1
	for _, id := range existing {
		if id == base {
			// counts as slot 1
		} else if strings.HasPrefix(id, base+"-") {
			if n, err := strconv.Atoi(id[len(base)+1:]); err == nil && n > max {
				max = n
			}
		}
	}
	return fmt.Sprintf("%s-%d", base, max+1)
}
