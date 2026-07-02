package env

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"dsf-lab-builder/internal/docker"
	"dsf-lab-builder/internal/runner"
)

// Config holds the paths the manager needs. All are real host-side paths since
// the binary runs natively — no container/host translation required.
type Config struct {
	Workspace     string // e.g. ./workspace  (env copies live here as workspace/env1, env2, ...)
	ScriptsDir    string // e.g. ./scripts    (bundled AWS floci template, read-only)
	GCPScriptsDir string // e.g. ./scripts/gcp (bundled GCP floci template, read-only)
	MaxSlots      int    // 5
}

type Detail struct {
	docker.EnvSummary
	RDBS             []RDSInstance `json:"rds"`
	Buckets          []string      `json:"buckets"`
	FAM              *FAMInfo      `json:"fam,omitempty"`
	GeneratorRunning bool          `json:"generatorRunning"`
}

type RDSInstance struct {
	ID               string `json:"id"`
	Engine           string `json:"engine"`
	Status           string `json:"status"`
	Endpoint         string `json:"endpoint"`
	GeneratorRunning bool   `json:"generatorRunning"`
}

// RDSDetail is the full info panel data for one RDS instance (mirrors FAMInfo for the UI).
type RDSDetail struct {
	ID                 string `json:"id"`
	Engine             string `json:"engine"`
	EngineVersion      string `json:"engineVersion"`
	Status             string `json:"status"`
	Host               string `json:"host"`
	Port               int    `json:"port"`
	Endpoint           string `json:"endpoint"`
	MasterUser         string `json:"masterUser"`
	MasterPass         string `json:"masterPass"`
	AuditMgrUser       string `json:"auditMgrUser"`
	AuditMgrPass       string `json:"auditMgrPass"`
	DBName             string `json:"dbName"`
	InstanceClass      string `json:"instanceClass"`
	ParamGroup         string `json:"paramGroup"`
	ARN                string `json:"arn"`
	CloudWatchLogGroup string `json:"cloudWatchLogGroup"`
	CloudWatchARN      string `json:"cloudWatchArn"`
	FlociEndpoint      string `json:"flociEndpoint"`
	GeneratorRunning   bool   `json:"generatorRunning"`
}

type FAMInfo struct {
	UserName     string `json:"userName"`
	UserARN      string `json:"userArn"`
	SourceBucket string `json:"sourceBucket"`
	LogBucket    string `json:"logBucket"`
	TrailName    string `json:"trailName"`
	TrailLogging bool   `json:"trailLogging"`
	EndpointURL  string `json:"endpointUrl"`
	AccountID    string `json:"accountId"`
	KeyID        string `json:"keyId,omitempty"`
	SecretKey    string `json:"secretKey,omitempty"`
}

// Generators tracks running data generator processes keyed by env ID.
var Generators = map[string]*os.Process{}

// DetectNextSlot finds the lowest free slot in 1..MaxSlots.
func DetectNextSlot(cfg *Config) (int, error) {
	used, err := docker.GetUsedPorts()
	if err != nil {
		return 0, err
	}
	for n := 1; n <= cfg.MaxSlots; n++ {
		if used[4566+n] {
			continue
		}
		conflict := false
		for p := 7001 + n*100; p <= 7099+n*100; p++ {
			if used[p] {
				conflict = true
				break
			}
		}
		if !conflict {
			return n, nil
		}
	}
	return 0, fmt.Errorf("all slots 1-%d are in use", cfg.MaxSlots)
}

// Deploy copies the script template to workspace/envN, writes .env, starts docker compose.
// Running natively means --project-directory is a real host path — build context and
// bind mounts (./data) all resolve correctly without any workarounds.
func Deploy(slot int, cfg *Config) *runner.Job {
	projectName := fmt.Sprintf("floci-env%d", slot)
	envDir := envDirPath(slot, cfg)

	script := fmt.Sprintf(`set -e
echo "=== Copying scripts to %s ==="
mkdir -p "%s"
cp -r "%s/." "%s"

echo "=== Writing .env for slot %d ==="
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
		cfg.ScriptsDir, envDir,
		slot,
		envDir, buildEnvFile(slot),
		projectName,
		envDir, envDir, projectName, envDir,
		projectName,
	)

	cmd := exec.Command("bash", "-c", script)
	return runner.Start("deploy", projectName, cmd)
}

// Destroy tears down the compose stack and removes the env directory.
func Destroy(slot int, cfg *Config) *runner.Job {
	projectName := fmt.Sprintf("floci-env%d", slot)
	envDir := envDirPath(slot, cfg)

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
	return runner.Start("destroy", projectName, cmd)
}

// GetDetail queries the running localstack instance for RDS / S3 / FAM info.
func GetDetail(e docker.EnvSummary, cfg *Config) (*Detail, error) {
	d := &Detail{EnvSummary: e}
	if e.Status != "running" || e.FlociPort == 0 {
		return d, nil
	}

	// Binary runs on the host — localstack is reachable at localhost:PORT
	endpoint := fmt.Sprintf("http://localhost:%d", e.FlociPort)
	awsEnv := awsEnvVars(endpoint)

	// RDS instances
	rdsOut, _ := runAWS(awsEnv,
		"rds", "describe-db-instances",
		"--query", "DBInstances[*].{id:DBInstanceIdentifier,engine:Engine,status:DBInstanceStatus,addr:Endpoint.Address,port:Endpoint.Port}",
		"--output", "json")
	if rdsOut != "" {
		var rows []struct {
			ID     string `json:"id"`
			Engine string `json:"engine"`
			Status string `json:"status"`
			Addr   string `json:"addr"`
			Port   int    `json:"port"`
		}
		if json.Unmarshal([]byte(rdsOut), &rows) == nil {
			for _, r := range rows {
				d.RDBS = append(d.RDBS, RDSInstance{
					ID:       r.ID,
					Engine:   r.Engine,
					Status:   r.Status,
					Endpoint: fmt.Sprintf("%s:%d", r.Addr, r.Port),
				})
			}
		}
	}

	// S3 buckets
	s3Out, _ := runAWS(awsEnv, "s3api", "list-buckets",
		"--query", "Buckets[*].Name", "--output", "json")
	if s3Out != "" {
		var buckets []string
		if json.Unmarshal([]byte(s3Out), &buckets) == nil {
			d.Buckets = buckets
		}
	}

	// FAM info from .env file
	slot := docker.SlotFromID(e.ID)
	if slot > 0 {
		fam := readFAMFromEnvFile(envDirPath(slot, cfg), endpoint, e.AccountID)
		if fam != nil {
			if fam.TrailName != "" {
				out, err := runAWS(awsEnv, "cloudtrail", "get-trail-status",
					"--name", fam.TrailName, "--query", "IsLogging", "--output", "text")
				if err == nil {
					fam.TrailLogging = strings.EqualFold(strings.TrimSpace(out), "true")
				}
			}
			d.FAM = fam
		}
	}

	_, d.GeneratorRunning = Generators[e.ID]
	return d, nil
}

// CreateRDS runs the engine-specific setup script for the given instanceID.
// instanceID must be non-empty; use SuggestNextRDS to obtain one.
func CreateRDS(e docker.EnvSummary, engine, instanceID string, cfg *Config) (*runner.Job, error) {
	scripts := map[string]string{
		"postgres": "service-rds-postgres-dsf-setup.sh",
		"mysql":    "service-rds-mysql-dsf-setup.sh",
		"mariadb":  "service-rds-mariadb-dsf-setup.sh",
	}
	script, ok := scripts[engine]
	if !ok {
		return nil, fmt.Errorf("unsupported engine: %s", engine)
	}
	slot := docker.SlotFromID(e.ID)
	if slot == 0 {
		return nil, fmt.Errorf("cannot manage the default env via builder")
	}
	dir := envDirPath(slot, cfg)
	rdsDir := filepath.Join(dir, "rds")
	envFile := filepath.Join(dir, ".env")

	cmd := exec.Command("bash", "-c", fmt.Sprintf(
		`set -e
source "%s"
export AWS_ENDPOINT_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
export DB_INSTANCE_ID="%s"
bash "%s/%s"`,
		envFile, instanceID, rdsDir, script))
	cmd.Dir = rdsDir
	return runner.Start("create-rds-"+engine, e.ID, cmd), nil
}

// SuggestNextRDS returns existing instance IDs for the given engine and the next suggested ID.
func SuggestNextRDS(e docker.EnvSummary, engine string) (existing []string, suggested string, err error) {
	if e.FlociPort == 0 {
		return nil, "", fmt.Errorf("env not running")
	}
	endpoint := fmt.Sprintf("http://localhost:%d", e.FlociPort)
	out, _ := runAWS(awsEnvVars(endpoint),
		"rds", "describe-db-instances",
		"--query", "DBInstances[*].DBInstanceIdentifier",
		"--output", "json")

	var all []string
	json.Unmarshal([]byte(out), &all) //nolint — empty on error, handled below

	prefix := rdsInstancePrefix(engine, e.ID)
	for _, id := range all {
		if strings.HasPrefix(id, prefix) {
			existing = append(existing, id)
		}
	}
	suggested = nextRDSInstanceID(prefix, existing)
	return existing, suggested, nil
}

// GetRDSDetail queries localstack for full details about one RDS instance.
func GetRDSDetail(e docker.EnvSummary, instanceID string, cfg *Config) (*RDSDetail, error) {
	if e.FlociPort == 0 {
		return nil, fmt.Errorf("env not running")
	}
	endpoint := fmt.Sprintf("http://localhost:%d", e.FlociPort)
	awsEnv := awsEnvVars(endpoint)

	out, err := runAWS(awsEnv, "rds", "describe-db-instances",
		"--db-instance-identifier", instanceID,
		"--output", "json")
	if err != nil {
		return nil, fmt.Errorf("describe-db-instances: %w", err)
	}

	var result struct {
		DBInstances []struct {
			Engine           string `json:"Engine"`
			EngineVersion    string `json:"EngineVersion"`
			DBInstanceStatus string `json:"DBInstanceStatus"`
			MasterUsername   string `json:"MasterUsername"`
			DBInstanceClass  string `json:"DBInstanceClass"`
			Endpoint         struct {
				Address string `json:"Address"`
				Port    int    `json:"Port"`
			} `json:"Endpoint"`
			DBParameterGroups []struct {
				DBParameterGroupName string `json:"DBParameterGroupName"`
			} `json:"DBParameterGroups"`
		} `json:"DBInstances"`
	}
	if err := json.Unmarshal([]byte(out), &result); err != nil || len(result.DBInstances) == 0 {
		return nil, fmt.Errorf("instance %s not found", instanceID)
	}

	inst := result.DBInstances[0]
	logGroup := fmt.Sprintf("/aws/rds/instance/%s/%s", instanceID, cwLogType(inst.Engine))
	paramGroup := ""
	if len(inst.DBParameterGroups) > 0 {
		paramGroup = inst.DBParameterGroups[0].DBParameterGroupName
	}

	return &RDSDetail{
		ID:                 instanceID,
		Engine:             inst.Engine,
		EngineVersion:      inst.EngineVersion,
		Status:             inst.DBInstanceStatus,
		Host:               inst.Endpoint.Address,
		Port:               inst.Endpoint.Port,
		Endpoint:           fmt.Sprintf("%s:%d", inst.Endpoint.Address, inst.Endpoint.Port),
		MasterUser:         coalesce(inst.MasterUsername, "admin"),
		MasterPass:         "secret123",
		AuditMgrUser:       "auditmgr",
		AuditMgrPass:       "AuditMgr$ecret1",
		DBName:             rdsDefaultDB(inst.Engine),
		InstanceClass:      inst.DBInstanceClass,
		ParamGroup:         paramGroup,
		ARN:                fmt.Sprintf("arn:aws:rds:us-east-1:%s:db:%s", e.AccountID, instanceID),
		CloudWatchLogGroup: logGroup,
		CloudWatchARN:      fmt.Sprintf("arn:aws:logs:us-east-1:%s:log-group:%s", e.AccountID, logGroup),
		FlociEndpoint:      endpoint,
		GeneratorRunning:   IsRDSGenRunning(RDSGenKey(e.ID, instanceID)),
	}, nil
}

// CreateFAM runs the FAM setup pipeline (scripts 01 + 02 + onboarding info).
func CreateFAM(e docker.EnvSummary, cfg *Config) (*runner.Job, error) {
	slot := docker.SlotFromID(e.ID)
	if slot == 0 {
		return nil, fmt.Errorf("cannot manage the default env via builder")
	}
	dir := envDirPath(slot, cfg)
	famDir := filepath.Join(dir, "fam")
	envFile := filepath.Join(dir, ".env")

	script := fmt.Sprintf(`set -e
cd "%s"
source "%s"
echo "=== Step 1: Create FAM IAM user ==="
bash 01-create-fam-user.sh
echo "=== Step 2: Setup FAM resources ==="
bash 02-setup-fam-resources.sh
echo "=== Onboarding info ==="
bash 04-show-fam-asset-info.sh
`, famDir, envFile)

	cmd := exec.Command("bash", "-c", script)
	cmd.Dir = famDir
	return runner.Start("create-fam", e.ID, cmd), nil
}

// TestRDS runs the audit test script for the given engine and instance.
// instanceID is optional; if empty the script's own default is used.
func TestRDS(e docker.EnvSummary, engine, instanceID string, cfg *Config) (*runner.Job, error) {
	scripts := map[string]string{
		"postgres": "service-rds-postgres-test-audit-cloudwatch.sh",
		"mysql":    "service-rds-mysql-test-audit-cloudwatch.sh",
		"mariadb":  "service-rds-mariadb-test-audit-cloudwatch.sh",
	}
	script, ok := scripts[engine]
	if !ok {
		return nil, fmt.Errorf("unsupported engine: %s", engine)
	}
	slot := docker.SlotFromID(e.ID)
	if slot == 0 {
		return nil, fmt.Errorf("cannot manage the default env via builder")
	}
	dir := envDirPath(slot, cfg)
	rdsDir := filepath.Join(dir, "rds")
	envFile := filepath.Join(dir, ".env")

	instanceExport := ""
	if instanceID != "" {
		instanceExport = fmt.Sprintf(`export DB_INSTANCE_ID="%s"`, instanceID)
	}
	cmd := exec.Command("bash", "-c", fmt.Sprintf(
		`set -e
source "%s"
export AWS_ENDPOINT_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
%s
bash "%s/%s"`,
		envFile, instanceExport, rdsDir, script))
	cmd.Dir = rdsDir
	return runner.Start("test-rds-"+engine, e.ID, cmd), nil
}

// TestFAM runs fam/03-test-traffic.sh, then waits 65 s for CloudTrail to flush
// and checks the log-destination bucket so the result is immediately visible.
func TestFAM(e docker.EnvSummary, cfg *Config) (*runner.Job, error) {
	slot := docker.SlotFromID(e.ID)
	if slot == 0 {
		return nil, fmt.Errorf("cannot manage the default env via builder")
	}
	dir := envDirPath(slot, cfg)
	famDir := filepath.Join(dir, "fam")
	envFile := filepath.Join(dir, ".env")

	script := fmt.Sprintf(`set -e
cd "%s"
source "%s"
# source only sets vars in the current shell; export makes them visible to child processes
export AWS_ENDPOINT_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION \
       FAM_LOG_DESTINATION_BUCKET FAM_SOURCE_BUCKET FAM_USER_NAME FAM_TRAIL_NAME

bash 03-test-traffic.sh

echo ""
echo "=== Waiting 65s for CloudTrail flush (flushed every ~60s) ==="
sleep 10; echo "  ↳ 10s..."
sleep 10; echo "  ↳ 20s..."
sleep 10; echo "  ↳ 30s..."
sleep 10; echo "  ↳ 40s..."
sleep 10; echo "  ↳ 50s..."
sleep 10; echo "  ↳ 60s..."
sleep 5;  echo "  ↳ 65s — checking now..."
echo ""
echo "=== CloudTrail logs in s3://${FAM_LOG_DESTINATION_BUCKET} ==="
aws s3 ls "s3://${FAM_LOG_DESTINATION_BUCKET}/AWSLogs/" --recursive 2>&1 \
    || echo "(no logs yet — run the test a second time to generate more traffic)"
`, famDir, envFile)

	cmd := exec.Command("bash", "-c", script)
	cmd.Dir = famDir
	return runner.Start("test-fam", e.ID, cmd), nil
}

// StartGenerator spawns the python data generator in the background.
func StartGenerator(e docker.EnvSummary, cfg *Config) error {
	if _, running := Generators[e.ID]; running {
		return fmt.Errorf("generator already running for %s", e.ID)
	}
	slot := docker.SlotFromID(e.ID)
	if slot == 0 {
		return fmt.Errorf("cannot manage the default env via builder")
	}
	dir := envDirPath(slot, cfg)
	famDir := filepath.Join(dir, "fam")
	envFile := filepath.Join(dir, ".env")
	logFile := filepath.Join(famDir, "activity.log")

	f, err := os.Create(logFile)
	if err != nil {
		return fmt.Errorf("create activity.log: %w", err)
	}

	cmd := exec.Command("bash", "-c",
		fmt.Sprintf(`source "%s" && export $(grep -v '^#' "%s" | grep '=' | cut -d= -f1 | xargs) && [ -f data/actors.json ] || bash 05-create-actors.sh && exec python3 06-simulate-activity.py`, envFile, envFile))
	cmd.Dir = famDir
	cmd.Stdout = f
	cmd.Stderr = f

	if err := cmd.Start(); err != nil {
		f.Close()
		return fmt.Errorf("start generator: %w", err)
	}
	Generators[e.ID] = cmd.Process

	go func() {
		cmd.Wait()
		f.Close()
		delete(Generators, e.ID)
	}()
	return nil
}

// StopGenerator kills the data generator for an env.
func StopGenerator(envID string) error {
	proc, ok := Generators[envID]
	if !ok {
		return fmt.Errorf("no generator running for %s", envID)
	}
	if err := proc.Kill(); err != nil {
		return err
	}
	delete(Generators, envID)
	return nil
}

// GeneratorLogs returns the last n lines of activity.log.
func GeneratorLogs(envID string, n int, cfg *Config) ([]string, error) {
	slot := docker.SlotFromID(envID)
	if slot == 0 {
		return nil, nil
	}
	logFile := filepath.Join(envDirPath(slot, cfg), "fam", "activity.log")
	f, err := os.Open(logFile)
	if err != nil {
		return nil, nil
	}
	defer f.Close()

	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines, nil
}

// ── helpers ───────────────────────────────────────────────────────────────────

func envDirPath(slot int, cfg *Config) string {
	return filepath.Join(cfg.Workspace, fmt.Sprintf("env%d", slot))
}

// rdsInstancePrefix returns the base instance-ID prefix for an engine+env combination.
// e.g. "mypostgres-env1-dsf" for postgres in env floci-env1.
func rdsInstancePrefix(engine, envID string) string {
	nameMap := map[string]string{
		"postgres": "mypostgres",
		"mysql":    "mymysql",
		"mariadb":  "mymariadb",
	}
	name := nameMap[engine]
	if name == "" {
		name = "my" + engine
	}
	suffix := ""
	if slot := docker.SlotFromID(envID); slot > 0 {
		suffix = fmt.Sprintf("-env%d", slot)
	}
	return name + suffix + "-dsf"
}

// nextRDSInstanceID returns the suggested next ID given a base prefix and existing IDs.
// base itself → base-2, base + base-2 → base-3, etc.
func nextRDSInstanceID(base string, existing []string) string {
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

func cwLogType(engine string) string {
	if engine == "postgres" {
		return "postgresql"
	}
	return "audit"
}

func rdsDefaultDB(engine string) string {
	if engine == "postgres" {
		return "postgres"
	}
	return "dsf_lab"
}

func coalesce(s, fallback string) string {
	if s != "" {
		return s
	}
	return fallback
}

func buildEnvFile(slot int) string {
	n := slot
	flociPort := 4566 + n
	rdsStart := 7001 + n*100
	rdsEnd := 7099 + n*100
	accountID := strings.Repeat(strconv.Itoa(n), 12)
	network := fmt.Sprintf("floci-env%d_default", n)
	suffix := fmt.Sprintf("-env%d", n)

	// Binary runs on the host; scripts reach localstack at localhost:PORT
	return fmt.Sprintf(`FLOCI_HOST_PORT=%d
RDS_HOST_PORT_RANGE=%d-%d
FLOCI_NETWORK=%s
RDS_PROXY_BASE_PORT=%d
RDS_PROXY_MAX_PORT=%d
FLOCI_DEFAULT_ACCOUNT_ID=%s
ENV_SUFFIX=%s
FAM_USER_NAME=fam-user%s
FAM_SOURCE_BUCKET=fam-lab-source%s
FAM_LOG_DESTINATION_BUCKET=fam-lab-logs%s
FAM_TRAIL_NAME=fam-cloudtrail%s
AWS_ENDPOINT_URL=http://localhost:%d
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_DEFAULT_REGION=us-east-1
FAM_ACCOUNT_ID=%s
`,
		flociPort,
		rdsStart, rdsEnd,
		network,
		rdsStart, rdsEnd,
		accountID,
		suffix, suffix, suffix, suffix, suffix,
		flociPort,
		accountID,
	)
}

func awsEnvVars(endpoint string) []string {
	return []string{
		"AWS_ENDPOINT_URL=" + endpoint,
		"AWS_ACCESS_KEY_ID=test",
		"AWS_SECRET_ACCESS_KEY=test",
		"AWS_DEFAULT_REGION=us-east-1",
		"PATH=" + os.Getenv("PATH"),
	}
}

func runAWS(envVars []string, args ...string) (string, error) {
	cmd := exec.Command("aws", args...)
	cmd.Env = envVars
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

func readFAMFromEnvFile(envDir, endpoint, accountID string) *FAMInfo {
	f, err := os.Open(filepath.Join(envDir, ".env"))
	if err != nil {
		return nil
	}
	defer f.Close()

	vals := map[string]string{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if k, v, ok := strings.Cut(line, "="); ok {
			vals[k] = v
		}
	}

	fam := &FAMInfo{
		UserName:     vals["FAM_USER_NAME"],
		SourceBucket: vals["FAM_SOURCE_BUCKET"],
		LogBucket:    vals["FAM_LOG_DESTINATION_BUCKET"],
		TrailName:    vals["FAM_TRAIL_NAME"],
		EndpointURL:  endpoint,
		AccountID:    accountID,
	}
	if fam.UserName == "" {
		return nil
	}
	fam.UserARN = fmt.Sprintf("arn:aws:iam::%s:user/%s", accountID, fam.UserName)

	if cf, err := os.Open(filepath.Join(envDir, "fam", "data", "fam-user.env")); err == nil {
		defer cf.Close()
		cs := bufio.NewScanner(cf)
		for cs.Scan() {
			if k, v, ok := strings.Cut(cs.Text(), "="); ok {
				switch k {
				case "FAM_ACCESS_KEY_ID":
					fam.KeyID = v
				case "FAM_SECRET_ACCESS_KEY":
					fam.SecretKey = v
				}
			}
		}
	}
	return fam
}
