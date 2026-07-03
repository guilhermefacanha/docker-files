package docker

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
	"strconv"
	"strings"
)

// GCPSlotFromID returns the numeric slot for a GCP compose project name, e.g. "floci-gcp2" → 2.
func GCPSlotFromID(id string) int {
	if !strings.HasPrefix(id, "floci-gcp") {
		return 0
	}
	n, _ := strconv.Atoi(id[len("floci-gcp"):])
	return n
}

func gcpProjectID(slot int) string {
	return fmt.Sprintf("floci-gcp-lab-%d", slot)
}

// AzSlotFromID returns the numeric slot for an Azure compose project name, e.g. "floci-az1" → 1.
func AzSlotFromID(id string) int {
	if !strings.HasPrefix(id, "floci-az") {
		return 0
	}
	n, _ := strconv.Atoi(id[len("floci-az"):])
	return n
}

// AzSubscriptionID returns the Azure subscription ID for a given slot.
func AzSubscriptionID(slot int) string {
	return fmt.Sprintf("00000000-0000-0000-0000-%012d", slot)
}

type EnvSummary struct {
	ID           string `json:"id"`
	Cloud        string `json:"cloud"` // "aws", "gcp", or "azure"
	Slot         int    `json:"slot"`
	Status       string `json:"status"`
	FlociPort    int    `json:"flociPort"`
	RDSPortRange string `json:"rdsPortRange"` // also used as Cloud SQL port range for GCP
	AccountID    string `json:"accountId"`    // AWS account ID or GCP project ID
	Network      string `json:"network"`
}

type psLine struct {
	ID     string `json:"ID"`
	State  string `json:"State"`
	Ports  string `json:"Ports"`
	Labels string `json:"Labels"`
}

func ListEnvs() ([]EnvSummary, error) {
	out, err := exec.Command("docker", "ps", "-a", "--format", "{{json .}}").Output()
	if err != nil {
		return nil, fmt.Errorf("docker ps: %w", err)
	}

	type projectData struct {
		flociLine    *psLine
		flociService string // "floci" for AWS, "floci-gcp" for GCP
		anyState     string
	}
	projects := map[string]*projectData{}

	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		var c psLine
		if err := json.Unmarshal([]byte(line), &c); err != nil {
			continue
		}
		project := labelVal(c.Labels, "com.docker.compose.project")
		if !isFlociProject(project) {
			continue
		}
		if _, ok := projects[project]; !ok {
			projects[project] = &projectData{}
		}
		pd := projects[project]
		if pd.anyState == "" || c.State == "running" {
			pd.anyState = c.State
		}
		svc := labelVal(c.Labels, "com.docker.compose.service")
		if svc == "floci" || svc == "floci-gcp" || svc == "floci-az" {
			pd.flociLine = &c
			pd.flociService = svc
		}
	}

	var envs []EnvSummary
	for project, pd := range projects {
		cloud := "aws"
		if strings.HasPrefix(project, "floci-gcp") {
			cloud = "gcp"
		} else if strings.HasPrefix(project, "floci-az") {
			cloud = "azure"
		}
		env := EnvSummary{
			ID:      project,
			Cloud:   cloud,
			Slot:    slotFromProject(project),
			Status:  normalizeState(pd.anyState),
			Network: project + "_default",
		}
		switch cloud {
		case "gcp":
			env.AccountID = gcpProjectID(env.Slot)
		case "azure":
			env.AccountID = AzSubscriptionID(env.Slot)
		default:
			env.AccountID = accountID(env.Slot)
		}
		if pd.flociLine != nil {
			switch pd.flociService {
			case "floci-gcp":
				env.FlociPort = gcpPort(pd.flociLine.Ports)
				env.RDSPortRange = rdsRange(pd.flociLine.Ports)
			case "floci-az":
				env.FlociPort = azPort(pd.flociLine.Ports)
				env.RDSPortRange = rdsRange(pd.flociLine.Ports)
			default:
				env.FlociPort = flociPort(pd.flociLine.Ports)
				env.RDSPortRange = rdsRange(pd.flociLine.Ports)
			}
			env.Status = normalizeState(pd.flociLine.State)
		}
		envs = append(envs, env)
	}
	sort.Slice(envs, func(i, j int) bool { return envs[i].Slot < envs[j].Slot })
	return envs, nil
}

func GetUsedPorts() (map[int]bool, error) {
	out, err := exec.Command("docker", "ps", "--format", "{{.Ports}}").Output()
	if err != nil {
		return nil, fmt.Errorf("docker ps ports: %w", err)
	}
	used := map[int]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		for _, part := range strings.Split(line, ",") {
			part = strings.TrimSpace(part)
			if !strings.Contains(part, "->") {
				continue
			}
			host := strings.Split(part, "->")[0]
			host = strings.TrimPrefix(host, "0.0.0.0:")
			host = strings.TrimPrefix(host, "::")
			if strings.Contains(host, "-") {
				bounds := strings.SplitN(host, "-", 2)
				start, _ := strconv.Atoi(bounds[0])
				end, _ := strconv.Atoi(bounds[1])
				for p := start; p <= end; p++ {
					used[p] = true
				}
			} else {
				if p, err := strconv.Atoi(host); err == nil && p > 0 {
					used[p] = true
				}
			}
		}
	}
	return used, nil
}

func isFlociProject(p string) bool {
	if p == "floci-local-aws" {
		return true
	}
	if strings.HasPrefix(p, "floci-env") {
		rest := p[len("floci-env"):]
		n, err := strconv.Atoi(rest)
		return err == nil && n >= 1 && n <= 5
	}
	if strings.HasPrefix(p, "floci-gcp") {
		rest := p[len("floci-gcp"):]
		n, err := strconv.Atoi(rest)
		return err == nil && n >= 1 && n <= 5
	}
	if strings.HasPrefix(p, "floci-az") {
		rest := p[len("floci-az"):]
		n, err := strconv.Atoi(rest)
		return err == nil && n >= 1 && n <= 5
	}
	return false
}

func slotFromProject(p string) int {
	if strings.HasPrefix(p, "floci-gcp") {
		return GCPSlotFromID(p)
	}
	if strings.HasPrefix(p, "floci-az") {
		return AzSlotFromID(p)
	}
	return SlotFromID(p)
}

// SlotFromID returns the numeric slot for a compose project name (exported for manager).
func SlotFromID(id string) int {
	if !strings.HasPrefix(id, "floci-env") {
		return 0
	}
	n, _ := strconv.Atoi(id[len("floci-env"):])
	return n
}

func accountID(slot int) string {
	if slot == 0 {
		return "000000000000"
	}
	return strings.Repeat(strconv.Itoa(slot), 12)
}

func flociPort(ports string) int {
	for _, part := range strings.Split(ports, ",") {
		part = strings.TrimSpace(part)
		if strings.Contains(part, "->4566/tcp") {
			host := strings.Split(part, "->")[0]
			host = strings.TrimPrefix(host, "0.0.0.0:")
			host = strings.TrimPrefix(host, "::")
			p, _ := strconv.Atoi(host)
			return p
		}
	}
	return 0
}

func gcpPort(ports string) int {
	for _, part := range strings.Split(ports, ",") {
		part = strings.TrimSpace(part)
		if strings.Contains(part, "->4588/tcp") {
			host := strings.Split(part, "->")[0]
			host = strings.TrimPrefix(host, "0.0.0.0:")
			host = strings.TrimPrefix(host, "::")
			p, _ := strconv.Atoi(host)
			return p
		}
	}
	return 0
}

func azPort(ports string) int {
	for _, part := range strings.Split(ports, ",") {
		part = strings.TrimSpace(part)
		if strings.Contains(part, "->4577/tcp") {
			host := strings.Split(part, "->")[0]
			host = strings.TrimPrefix(host, "0.0.0.0:")
			host = strings.TrimPrefix(host, "::")
			p, _ := strconv.Atoi(host)
			return p
		}
	}
	return 0
}

func rdsRange(ports string) string {
	for _, part := range strings.Split(ports, ",") {
		part = strings.TrimSpace(part)
		if !strings.Contains(part, "->") {
			continue
		}
		host := strings.Split(part, "->")[0]
		host = strings.TrimPrefix(host, "0.0.0.0:")
		host = strings.TrimPrefix(host, "::")
		if strings.Contains(host, "-") {
			return host
		}
	}
	return ""
}

func normalizeState(s string) string {
	switch strings.ToLower(s) {
	case "running":
		return "running"
	case "exited", "dead", "removing":
		return "stopped"
	default:
		if s == "" {
			return "unknown"
		}
		return s
	}
}

func labelVal(labels, key string) string {
	for _, kv := range strings.Split(labels, ",") {
		parts := strings.SplitN(strings.TrimSpace(kv), "=", 2)
		if len(parts) == 2 && strings.TrimSpace(parts[0]) == key {
			return strings.TrimSpace(parts[1])
		}
	}
	return ""
}
