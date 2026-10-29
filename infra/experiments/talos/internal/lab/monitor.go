package lab

import (
	"cmp"
	"context"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"
)

// Sample is one check of a signal, such as the API, the LoadBalancer address
// or a prober's DNS lookup, at an offset from the monitor's start.
type Sample struct {
	At     time.Duration
	Signal string
	OK     bool
}

// Step is a named window of a scenario.
type Step struct {
	Name     string
	From, To time.Duration
}

// Monitor collects samples during a scenario and reports, per step, how long
// each signal went without a successful check.
type Monitor struct {
	mu      sync.Mutex
	start   time.Time
	samples []Sample
	steps   []Step
	log     io.Writer
	// Blocked marks signals that should never succeed, such as a policed
	// pod's external connections; the table counts their successes instead.
	Blocked func(signal string) bool
}

func NewMonitor(log io.Writer) *Monitor {
	return &Monitor{start: time.Now(), log: log, Blocked: func(string) bool { return false }}
}

func (m *Monitor) now() time.Duration { return time.Since(m.start) }

func (m *Monitor) Record(signal string, ok bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	sample := Sample{At: m.now(), Signal: signal, OK: ok}
	m.samples = append(m.samples, sample)
	fmt.Fprintf(m.log, "%8.2f %s %t\n", sample.At.Seconds(), signal, ok)
}

// ServeHTTP takes probers' reports: /report?namespace=&node=&target=&ok=1.
func (m *Monitor) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if r.URL.Path != "/report" || q.Get("target") == "" {
		http.NotFound(w, r)
		return
	}
	m.Record(ProberSignal(q.Get("namespace"), q.Get("node"), q.Get("target")), q.Get("ok") == "1")
}

func ProberSignal(namespace, node, target string) string {
	return namespace + "/" + strings.TrimPrefix(node, "talos-lab-") + "/" + target
}

// Poll records check's result every interval until ctx ends.
func (m *Monitor) Poll(ctx context.Context, signal string, interval time.Duration, check func(context.Context) bool) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		checkCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		ok := check(checkCtx)
		cancel()
		if ctx.Err() != nil {
			return
		}
		m.Record(signal, ok)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// Step ends the current step and starts the next.
func (m *Monitor) Step(name string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	if n := len(m.steps); n > 0 && m.steps[n-1].To == 0 {
		m.steps[n-1].To = now
	}
	m.steps = append(m.steps, Step{Name: name, From: now})
	fmt.Fprintf(m.log, "%8.2f == step %s\n", now.Seconds(), name)
}

// End closes the current step.
func (m *Monitor) End() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if n := len(m.steps); n > 0 && m.steps[n-1].To == 0 {
		m.steps[n-1].To = m.now()
	}
}

// Stat summarises a signal in a window. Outage is the longest stretch without
// a successful sample, so it includes up to one sampling interval.
type Stat struct {
	OK, Failed int
	Outage     time.Duration
}

// Summarize returns each signal's stat in [from, to].
func Summarize(samples []Sample, from, to time.Duration) map[string]Stat {
	stats := map[string]Stat{}
	last := map[string]time.Duration{}
	for _, s := range samples {
		if _, seen := last[s.Signal]; !seen {
			last[s.Signal] = from
			stats[s.Signal] = Stat{}
		}
		if s.At < from || s.At > to {
			continue
		}
		stat := stats[s.Signal]
		if !s.OK {
			stat.Failed++
			stats[s.Signal] = stat
			continue
		}
		stat.OK++
		stat.Outage = max(stat.Outage, s.At-last[s.Signal])
		last[s.Signal] = s.At
		stats[s.Signal] = stat
	}
	for signal, stat := range stats {
		stat.Outage = max(stat.Outage, to-last[signal])
		stats[signal] = stat
	}
	return stats
}

// Window returns a step's stats.
func (m *Monitor) Window(name string) (map[string]Stat, Step, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, step := range m.steps {
		if step.Name == name {
			to := step.To
			if to == 0 {
				to = m.now()
			}
			return Summarize(m.samples, step.From, to), step, nil
		}
	}
	return nil, Step{}, fmt.Errorf("no step %q", name)
}

// Span returns each signal's stat from the start of one step to the end of
// another, so an outage that crosses steps counts once.
func (m *Monitor) Span(first, last string) (map[string]Stat, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	from, to := time.Duration(-1), time.Duration(-1)
	for _, step := range m.steps {
		if step.Name == first {
			from = step.From
		}
		if step.Name == last {
			to = cmp.Or(step.To, m.now())
		}
	}
	if from < 0 || to < 0 {
		return nil, fmt.Errorf("no steps %q to %q", first, last)
	}
	return Summarize(m.samples, from, to), nil
}

// Recent returns each signal's stat over the last d.
func (m *Monitor) Recent(d time.Duration) map[string]Stat {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	return Summarize(m.samples, now-d, now)
}

// Table shows, for every signal and step, the longest outage in seconds, or
// for blocked signals how many checks succeeded.
func (m *Monitor) Table() string {
	m.mu.Lock()
	steps := slices.Clone(m.steps)
	samples := slices.Clone(m.samples)
	now := m.now()
	m.mu.Unlock()
	signals := []string{}
	for _, s := range samples {
		if !slices.Contains(signals, s.Signal) {
			signals = append(signals, s.Signal)
		}
	}
	slices.Sort(signals)
	b := &strings.Builder{}
	fmt.Fprintf(b, "%-34s", "longest outage (s) / leaks")
	for _, step := range steps {
		fmt.Fprintf(b, " %14s", step.Name)
	}
	fmt.Fprintf(b, "\n%-34s", "step duration (s)")
	stats := make([]map[string]Stat, len(steps))
	for i, step := range steps {
		if step.To == 0 {
			step.To = now
		}
		stats[i] = Summarize(samples, step.From, step.To)
		fmt.Fprintf(b, " %14.1f", (step.To - step.From).Seconds())
	}
	for _, signal := range signals {
		fmt.Fprintf(b, "\n%-34s", signal)
		for i := range steps {
			stat := stats[i][signal]
			cell := fmt.Sprintf("%.1f", stat.Outage.Seconds())
			if m.Blocked(signal) {
				cell = fmt.Sprintf("leak %d/%d", stat.OK, stat.OK+stat.Failed)
			}
			fmt.Fprintf(b, " %14s", cell)
		}
	}
	return b.String()
}
