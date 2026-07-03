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

type AZDetail struct {
	docker.EnvSummary
	Databases []AZDatabase `json:"databases"`
}

type AZDatabase struct {
	ID       string `json:"id"`
	Engine   string `json:"engine"`
	Status   string `json:"status"`
	Endpoint string `json:"endpoint"`
}

type AZDatabaseDetail struct {
	ID              string `json:"id"`
	Engine          string `json:"engine"`
	EngineVersion   string `json:"engineVersion"`
	Status          string `json:"status"`
	Host            string `json:"host"`
	Port            int    `json:"port"`
	Endpoint        string `json:"endpoint"`
	ProxyHost       string `json:"proxyHost"`
	ProxyPort       int    `json:"proxyPort"`
	MasterUser      string `json:"masterUser"`
	MasterPass      string `json:"masterPass"`
	AuditUser       string `json:"auditUser"`
	AuditPass       string `json:"auditPass"`
	SubscriptionID  string `json:"subscriptionId"`
	ResourceGroup   string `json:"resourceGroup"`
	EventHubNS      string `json:"eventHubNamespace"`
	EventHubName    string `json:"eventHubName"`
	DiagSettingName string `json:"diagnosticSettingName"`
	FlociEndpoint   string `json:"flociEndpoint"`
}

// ── Slot detection ────────────────────────────────────────────────────────────

func DetectNextAZSlot(cfg *Config) (int, error) {
	used, err := docker.GetUsedPorts()
	if err != nil {
		return 0, err
	}
	for n := 1; n <= cfg.MaxSlots; n++ {
		if used[6000+n] {
			continue
		}
		conflict := false
		for p := 9000 + n*100 + 1; p <= 9000+n*100+99; p++ {
			if used[p] {
				conflict = true
				break
			}
		}
		if !conflict {
			return n, nil
		}
	}
	return 0, fmt.Errorf("all Azure slots 1-%d are in use", cfg.MaxSlots)
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

func DeployAZ(slot int, cfg *Config) *runner.Job {
	projectName := fmt.Sprintf("floci-az%d", slot)
	envDir := azEnvDirPath(slot, cfg)

	script := fmt.Sprintf(`set -e
echo "=== Copying Azure scripts to %s ==="
mkdir -p "%s"
cp -r "%s/." "%s"

echo "=== Writing .env for Azure slot %d ==="
cat > "%s/.env" << 'ENVEOF'
%sENVEOF

echo "=== Starting docker compose for %s ==="
DOCKER_BUILDKIT=0 docker compose \
  -f "%s/docker-compose.yml" \
  --project-directory "%s" \
  --project-name "%s" \
  --env-file "%s/.env" \
  up -d --build

echo "=== Done! %s is up ==="
`,
		envDir,
		envDir,
		cfg.AzureScriptsDir, envDir,
		slot,
		envDir, buildAZEnvFile(slot),
		projectName,
		envDir, envDir, projectName, envDir,
		projectName,
	)

	cmd := exec.Command("bash", "-c", script)
	return runner.Start("deploy-azure", projectName, cmd)
}

func DestroyAZ(slot int, cfg *Config) *runner.Job {
	projectName := fmt.Sprintf("floci-az%d", slot)
	envDir := azEnvDirPath(slot, cfg)

	script := fmt.Sprintf(`set -e
echo "=== Stopping %s ==="
docker compose \
  -f "%s/docker-compose.yml" \
  --project-directory "%s" \
  --project-name "%s" \
  down --volumes --remove-orphans 2>/dev/null || true

echo "=== Removing Azure env directory ==="
rm -rf "%s"
echo "=== Done ==="
`,
		projectName,
		envDir, envDir, projectName,
		envDir,
	)

	cmd := exec.Command("bash", "-c", script)
	return runner.Start("destroy-azure", projectName, cmd)
}

// ── Detail ────────────────────────────────────────────────────────────────────

func GetAZDetail(e docker.EnvSummary, cfg *Config) (*AZDetail, error) {
	d := &AZDetail{EnvSummary: e}
	if e.Status != "running" || e.FlociPort == 0 {
		return d, nil
	}

	endpoint := fmt.Sprintf("http://localhost:%d", e.FlociPort)
	sub := e.AccountID

	dbs, _ := listAZDatabases(endpoint, sub, "dsf-lab-rg")
	d.Databases = dbs
	return d, nil
}

func listAZDatabases(endpoint, sub, rg string) ([]AZDatabase, error) {
	var out []AZDatabase

	engines := []struct {
		engine   string
		provider string
		kind     string
		portNum  int
		stateKey string
	}{
		{"mysql", "Microsoft.DBforMySQL", "flexibleServers", 3306, "state"},
		{"mariadb", "Microsoft.DBforMariaDB", "servers", 3306, "userVisibleState"},
		{"postgres", "Microsoft.DBforPostgreSQL", "flexibleServers", 5432, "state"},
	}

	for _, e := range engines {
		url := fmt.Sprintf("%s/subscriptions/%s/resourceGroups/%s/providers/%s/%s?api-version=2023-01-01",
			endpoint, sub, rg, e.provider, e.kind)
		resp, err := http.Get(url) //nolint:gosec
		if err != nil {
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		var result struct {
			Value []struct {
				Name       string `json:"name"`
				Properties struct {
					State           string `json:"state"`
					UserVisibleState string `json:"userVisibleState"`
					FullyQualifiedDomainName string `json:"fullyQualifiedDomainName"`
				} `json:"properties"`
			} `json:"value"`
		}
		if json.Unmarshal(body, &result) != nil {
			continue
		}
		for _, item := range result.Value {
			state := item.Properties.State
			if state == "" {
				state = item.Properties.UserVisibleState
			}
			fqdn := item.Properties.FullyQualifiedDomainName
			ep := ""
			if fqdn != "" {
				ep = fmt.Sprintf("%s:%d", fqdn, e.portNum)
			}
			out = append(out, AZDatabase{
				ID:       item.Name,
				Engine:   e.engine,
				Status:   state,
				Endpoint: ep,
			})
		}
	}
	return out, nil
}

// ── Database CRUD ─────────────────────────────────────────────────────────────

func CreateAZDatabase(e docker.EnvSummary, engine, instanceID string, cfg *Config) (*runner.Job, error) {
	scripts := map[string]string{
		"mysql":    "service-az-mysql-dsf-setup.sh",
		"mariadb":  "service-az-mariadb-dsf-setup.sh",
		"postgres": "service-az-postgres-dsf-setup.sh",
	}
	script, ok := scripts[engine]
	if !ok {
		return nil, fmt.Errorf("unsupported engine: %s", engine)
	}
	slot := docker.AzSlotFromID(e.ID)
	if slot == 0 {
		return nil, fmt.Errorf("invalid Azure env ID: %s", e.ID)
	}
	dir := azEnvDirPath(slot, cfg)
	envFile := filepath.Join(dir, ".env")

	cmd := exec.Command("bash", "-c", fmt.Sprintf(
		`set -e
source "%s"
export FLOCI_AZ_ENDPOINT AZ_SUBSCRIPTION_ID AZ_RESOURCE_GROUP AZ_LOCATION
export AZ_EVENTHUB_NAMESPACE AZ_EVENTHUB_NAME
export DB_SERVER_NAME="%s"
bash "%s/%s"`,
		envFile, instanceID, dir, script))
	cmd.Dir = dir
	return runner.Start("create-azdb-"+engine, e.ID, cmd), nil
}

func TestAZDatabase(e docker.EnvSummary, engine, instanceID string, cfg *Config) (*runner.Job, error) {
	slot := docker.AzSlotFromID(e.ID)
	if slot == 0 {
		return nil, fmt.Errorf("invalid Azure env ID: %s", e.ID)
	}
	dir := azEnvDirPath(slot, cfg)
	envFile := filepath.Join(dir, ".env")

	cmd := exec.Command("bash", "-c", fmt.Sprintf(
		`set -e
source "%s"
export FLOCI_AZ_ENDPOINT AZ_SUBSCRIPTION_ID AZ_RESOURCE_GROUP
export AZ_EVENTHUB_NAMESPACE AZ_EVENTHUB_NAME
export ENGINE="%s"
export DB_SERVER_NAME="%s"
bash "%s/service-az-test-traffic.sh"`,
		envFile, engine, instanceID, dir))
	cmd.Dir = dir
	return runner.Start("test-azdb-"+engine, e.ID, cmd), nil
}

func SuggestNextAZDatabase(e docker.EnvSummary, engine string) (existing []string, suggested string, err error) {
	if e.FlociPort == 0 {
		return nil, "", fmt.Errorf("Azure env not running")
	}
	endpoint := fmt.Sprintf("http://localhost:%d", e.FlociPort)
	dbs, err := listAZDatabases(endpoint, e.AccountID, "dsf-lab-rg")
	if err != nil {
		return nil, "", err
	}

	prefix := azDBPrefix(engine, e.ID)
	for _, db := range dbs {
		if db.Engine == engine && strings.HasPrefix(db.ID, prefix) {
			existing = append(existing, db.ID)
		}
	}
	suggested = nextAZInstanceID(prefix, existing)
	return existing, suggested, nil
}

func GetAZDatabaseDetail(e docker.EnvSummary, instanceID, engine string, cfg *Config) (*AZDatabaseDetail, error) {
	if e.FlociPort == 0 {
		return nil, fmt.Errorf("Azure env not running")
	}
	endpoint := fmt.Sprintf("http://localhost:%d", e.FlociPort)
	sub := e.AccountID
	rg := "dsf-lab-rg"

	provider, kind, port := azProviderInfo(engine)
	url := fmt.Sprintf("%s/subscriptions/%s/resourceGroups/%s/providers/%s/%s/%s?api-version=2023-01-01",
		endpoint, sub, rg, provider, kind, instanceID)
	resp, err := http.Get(url) //nolint:gosec
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	var inst struct {
		Name       string `json:"name"`
		Properties struct {
			State                    string `json:"state"`
			UserVisibleState          string `json:"userVisibleState"`
			Version                  string `json:"version"`
			AdministratorLogin       string `json:"administratorLogin"`
			FullyQualifiedDomainName string `json:"fullyQualifiedDomainName"`
		} `json:"properties"`
	}
	if err := json.Unmarshal(body, &inst); err != nil || inst.Name == "" {
		return nil, fmt.Errorf("database %s not found", instanceID)
	}

	state := inst.Properties.State
	if state == "" {
		state = inst.Properties.UserVisibleState
	}

	slot := docker.AzSlotFromID(e.ID)
	ns := fmt.Sprintf("dsf-eventhub-az%d", slot)

	proxyHost, proxyPort := azDBProxyPort(instanceID, engine)

	return &AZDatabaseDetail{
		ID:              instanceID,
		Engine:          engine,
		EngineVersion:   inst.Properties.Version,
		Status:          state,
		Host:            inst.Properties.FullyQualifiedDomainName,
		Port:            port,
		Endpoint:        fmt.Sprintf("%s:%d", inst.Properties.FullyQualifiedDomainName, port),
		ProxyHost:       proxyHost,
		ProxyPort:       proxyPort,
		MasterUser:      coalesce(inst.Properties.AdministratorLogin, "admin"),
		MasterPass:      "secret123",
		AuditUser:       "auditmgr",
		AuditPass:       "AuditMgr$ecret1",
		SubscriptionID:  sub,
		ResourceGroup:   rg,
		EventHubNS:      ns,
		EventHubName:    "dsf-audit-logs",
		DiagSettingName: "dsf-audit",
		FlociEndpoint:   endpoint,
	}, nil
}

// ── helpers ───────────────────────────────────────────────────────────────────

func azEnvDirPath(slot int, cfg *Config) string {
	return filepath.Join(cfg.Workspace, fmt.Sprintf("az-env%d", slot))
}

func buildAZEnvFile(slot int) string {
	azPort := 6000 + slot
	dbBase := 9000 + slot*100 + 1
	dbEnd := 9000 + slot*100 + 99
	sub := docker.AzSubscriptionID(slot)
	network := fmt.Sprintf("floci-az%d_default", slot)
	ns := fmt.Sprintf("dsf-eventhub-az%d", slot)
	suffix := fmt.Sprintf("-az%d", slot)

	return fmt.Sprintf(`FLOCI_AZ_PORT=%d
FLOCI_AZ_NETWORK=%s
DB_PROXY_BASE_PORT=%d
DB_PROXY_MAX_PORT=%d
AZ_SUBSCRIPTION_ID=%s
AZ_RESOURCE_GROUP=dsf-lab-rg
AZ_LOCATION=eastus
AZ_EVENTHUB_NAMESPACE=%s
AZ_EVENTHUB_NAME=dsf-audit-logs
FLOCI_AZ_ENDPOINT=http://localhost:%d
ENV_SUFFIX=%s
`,
		azPort,
		network,
		dbBase, dbEnd,
		sub,
		ns,
		azPort,
		suffix,
	)
}

func azProviderInfo(engine string) (provider, kind string, port int) {
	switch engine {
	case "mysql":
		return "Microsoft.DBforMySQL", "flexibleServers", 3306
	case "mariadb":
		return "Microsoft.DBforMariaDB", "servers", 3306
	default:
		return "Microsoft.DBforPostgreSQL", "flexibleServers", 5432
	}
}

func azDBPrefix(engine, envID string) string {
	names := map[string]string{
		"mysql":    "mymysql",
		"mariadb":  "mymariadb",
		"postgres": "mypostgres",
	}
	name := names[engine]
	if name == "" {
		name = "my" + engine
	}
	slot := docker.AzSlotFromID(envID)
	return fmt.Sprintf("%s-az%d-dsf", name, slot)
}

func nextAZInstanceID(base string, existing []string) string {
	if len(existing) == 0 {
		return base
	}
	max := 1
	for _, id := range existing {
		if id == base {
			// slot 1
		} else if strings.HasPrefix(id, base+"-") {
			if n, err := strconv.Atoi(id[len(base)+1:]); err == nil && n > max {
				max = n
			}
		}
	}
	return fmt.Sprintf("%s-%d", base, max+1)
}

func azDBProxyPort(instanceID, engine string) (string, int) {
	prefix := "azdb-proxy-" + engine + "-"
	name := prefix + instanceID
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
