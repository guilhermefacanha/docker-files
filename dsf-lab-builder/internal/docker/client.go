package docker

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
	"strconv"
	"strings"
)

type EnvSummary struct {
	ID           string `json:"id"`
	Slot         int    `json:"slot"`
	Status       string `json:"status"`
	FlociPort    int    `json:"flociPort"`
	RDSPortRange string `json:"rdsPortRange"`
	AccountID    string `json:"accountId"`
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
		flociLine *psLine
		anyState  string
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
		if labelVal(c.Labels, "com.docker.compose.service") == "floci" {
			pd.flociLine = &c
		}
	}

	var envs []EnvSummary
	for project, pd := range projects {
		env := EnvSummary{
			ID:      project,
			Slot:    slotFromProject(project),
			Status:  normalizeState(pd.anyState),
			Network: project + "_default",
		}
		env.AccountID = accountID(env.Slot)
		if pd.flociLine != nil {
			env.FlociPort = flociPort(pd.flociLine.Ports)
			env.RDSPortRange = rdsRange(pd.flociLine.Ports)
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
	return false
}

func slotFromProject(p string) int {
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
