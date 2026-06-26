package runner

import (
	"bufio"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"sync/atomic"
)

// Job is a background command whose output streams via SSE.
type Job struct {
	ID     string   `json:"id"`
	Type   string   `json:"type"`
	EnvID  string   `json:"envId"`
	Status string   `json:"status"` // running | done | error
	Lines  []string `json:"lines"`

	mu      sync.Mutex
	waiters []chan struct{}
}

var (
	mu      sync.Mutex
	jobs    = map[string]*Job{}
	counter atomic.Int64
)

func nextID() string {
	return fmt.Sprintf("%d", counter.Add(1))
}

// Start launches cmd, streams combined stdout+stderr into the job, and returns immediately.
func Start(jobType, envID string, cmd *exec.Cmd) *Job {
	j := &Job{
		ID:     nextID(),
		Type:   jobType,
		EnvID:  envID,
		Status: "running",
	}
	mu.Lock()
	jobs[j.ID] = j
	mu.Unlock()

	go func() {
		pr, pw, err := os.Pipe()
		if err != nil {
			j.appendLine("[ERROR] pipe: " + err.Error())
			j.finish(true)
			return
		}
		cmd.Stdout = pw
		cmd.Stderr = pw

		if err := cmd.Start(); err != nil {
			pw.Close()
			pr.Close()
			j.appendLine("[ERROR] start: " + err.Error())
			j.finish(true)
			return
		}
		pw.Close() // close write end so scanner sees EOF when process exits

		scanner := bufio.NewScanner(pr)
		for scanner.Scan() {
			j.appendLine(scanner.Text())
		}
		pr.Close()

		isErr := cmd.Wait() != nil
		j.finish(isErr)
	}()

	return j
}

// Get retrieves a job by ID.
func Get(id string) *Job {
	mu.Lock()
	defer mu.Unlock()
	return jobs[id]
}

// Stream writes SSE events to w, blocking until the job completes or the client disconnects.
func (j *Job) Stream(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	ch := make(chan struct{}, 1)
	j.subscribe(ch)
	defer j.unsubscribe(ch)

	sent := 0
	for {
		j.mu.Lock()
		newLines := j.Lines[sent:]
		status := j.Status
		j.mu.Unlock()

		for _, l := range newLines {
			fmt.Fprintf(w, "data: %s\n\n", l)
			sent++
		}
		flusher.Flush()

		if status != "running" {
			if status == "error" {
				fmt.Fprintf(w, "data: [ERROR]\n\n")
			} else {
				fmt.Fprintf(w, "data: [DONE]\n\n")
			}
			flusher.Flush()
			return
		}

		select {
		case <-ch:
		case <-r.Context().Done():
			return
		}
	}
}

func (j *Job) appendLine(line string) {
	j.mu.Lock()
	j.Lines = append(j.Lines, line)
	ws := append([]chan struct{}(nil), j.waiters...)
	j.mu.Unlock()
	for _, ch := range ws {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

func (j *Job) finish(isErr bool) {
	j.mu.Lock()
	if isErr {
		j.Status = "error"
	} else {
		j.Status = "done"
	}
	ws := append([]chan struct{}(nil), j.waiters...)
	j.mu.Unlock()
	for _, ch := range ws {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

func (j *Job) subscribe(ch chan struct{}) {
	j.mu.Lock()
	j.waiters = append(j.waiters, ch)
	j.mu.Unlock()
}

func (j *Job) unsubscribe(ch chan struct{}) {
	j.mu.Lock()
	ws := j.waiters[:0]
	for _, w := range j.waiters {
		if w != ch {
			ws = append(ws, w)
		}
	}
	j.waiters = ws
	j.mu.Unlock()
}
