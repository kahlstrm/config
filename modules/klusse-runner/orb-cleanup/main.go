// Command orb-cleanup removes the klusse runner's stopped Docker orbs once their work is safe
// elsewhere, and the project snapshots no orb uses.
//
// `orb-cleanup record ORB` runs in a pause job, before the orb stops: it records the git facts
// of the orb's checkouts in ORB_FACTS. `orb-cleanup run`, hourly, drops a stopped orb whose
// facts say every commit is on a remote and nothing is changed, untracked or stashed (safe):
// once it has been archived and idle for a day, once it has been stopped for 7 days, or early,
// oldest first, while the disk is over 80 % full. An orb without facts recorded since it last
// started, such as one stopped by a VM restart, is checked from a copy of its home, without
// starting it. Unsafe orbs are kept, as are running ones: rescuing unpushed work is not built
// yet, so over 90 % it reports the unsafe orbs it keeps and fails. Until STATE_DIRECTORY holds
// a file `enforce`, it only logs what it would remove.
package main

import (
	"bufio"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	day           = 24 * time.Hour
	archivedAfter = day
	settledAfter  = 7 * day
	rescueAfter   = 30 * day
	imagesAfter   = 3 * day
	pressureHigh  = 80.0
	pressureFull  = 90.0
	// Under pressure too, so a pause that saves a project snapshot after stopping has ended.
	pressureAfter   = time.Hour
	home            = "/home/user"
	recordTimeout   = 2 * time.Minute
	checkTimeout    = 10 * time.Minute
	metadataTimeout = 15 * time.Second
)

//go:embed check.sh
var checkScript string

// Home directories of tools, which neither copies nor searches include.
var caches = []string{".cache", ".npm", ".bun", ".local/share/pnpm", "go/pkg", ".cargo", ".rustup"}

type repo struct {
	Path      string `json:"path"`
	Branch    string `json:"branch"`
	Head      string `json:"head"`
	Unpushed  int    `json:"unpushed"`
	Changed   int    `json:"changed"`
	Untracked int    `json:"untracked"`
	Ignored   int    `json:"ignored"`
	Stashes   int    `json:"stashes"`
}

type facts struct {
	Recorded time.Time `json:"recorded"`
	// "pause" when the pause job recorded them in the running orb, "copy" when cleanup read a
	// copy of the stopped orb's home.
	Source string   `json:"source"`
	Repos  []repo   `json:"repos"`
	Doubts []string `json:"doubts,omitempty"`
}

// unsafe says why the orb holds work that is nowhere else, or "" when it holds none. Ignored
// files are recorded but do not count: they are mostly build output.
func (f *facts) unsafe() string {
	if f == nil {
		return "no git facts"
	}
	var reasons []string
	reasons = append(reasons, f.Doubts...)
	for _, r := range f.Repos {
		for _, count := range []struct {
			n    int
			what string
		}{{r.Unpushed, "commits on no remote"}, {r.Changed, "changed files"}, {r.Untracked, "untracked files"}, {r.Stashes, "stashes"}} {
			if count.n > 0 {
				reasons = append(reasons, fmt.Sprintf("%s: %d %s", r.Path, count.n, count.what))
			}
		}
	}
	return strings.Join(reasons, "; ")
}

// parseCheck reads check.sh's output.
func parseCheck(output string) ([]repo, []string, error) {
	repos, doubts := []repo{}, []string{}
	done := false
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := scanner.Text()
		if done {
			return nil, nil, fmt.Errorf("output after done: %q", line)
		}
		fields := strings.Split(line, "\t")
		switch {
		case line == "done":
			done = true
		case fields[0] == "doubt" && len(fields) == 3:
			doubts = append(doubts, fields[1]+": "+fields[2])
		case fields[0] == "repo" && len(fields) == 9:
			r := repo{Path: fields[1], Branch: fields[2], Head: fields[3]}
			for i, count := range []*int{&r.Unpushed, &r.Changed, &r.Untracked, &r.Ignored, &r.Stashes} {
				n, err := strconv.Atoi(fields[4+i])
				if err != nil {
					return nil, nil, fmt.Errorf("bad count in %q", line)
				}
				*count = n
			}
			repos = append(repos, r)
		default:
			return nil, nil, fmt.Errorf("unexpected line %q", line)
		}
	}
	if !done {
		return nil, nil, errors.New("the check stopped before it finished")
	}
	return repos, doubts, nil
}

type thread struct {
	Archived bool      `json:"archived"`
	Updated  time.Time `json:"updatedAt"`
}

type orb struct {
	ID       string
	Name     string
	Started  time.Time
	Finished time.Time
	Size     int64
	Facts    *facts
}

func days(d time.Duration) string {
	if d >= day {
		return fmt.Sprintf("%d days", int(d/day))
	}
	return fmt.Sprintf("%d hours", int(d/time.Hour))
}

// rule decides whether a stopped orb is dropped now, and why. t is the thread's metadata, or
// nil when it is unknown.
func rule(o orb, now time.Time, t *thread) (bool, string) {
	stopped := now.Sub(o.Finished)
	if reason := o.Facts.unsafe(); reason != "" {
		if stopped >= rescueAfter {
			return false, fmt.Sprintf("stopped %s, kept until unpushed work can be rescued: %s", days(stopped), reason)
		}
		return false, fmt.Sprintf("stopped %s, unsafe: %s", days(stopped), reason)
	}
	if stopped >= settledAfter {
		return true, fmt.Sprintf("safe, stopped %s", days(stopped))
	}
	// Without updatedAt, how long the thread has been idle is unknown.
	if t != nil && t.Archived && !t.Updated.IsZero() && stopped >= archivedAfter && now.Sub(t.Updated) >= archivedAfter {
		return true, fmt.Sprintf("safe, archived, stopped %s", days(stopped))
	}
	return false, fmt.Sprintf("safe, stopped %s", days(stopped))
}

type cleaner struct {
	facts, label, image, dockerRoot, state, ampURL, key string
	dry                                                 bool
	now                                                 time.Time
	client                                              *http.Client
	metadataFailed                                      bool
}

func logf(format string, args ...any) { fmt.Printf(format+"\n", args...) }

func docker(args ...string) (string, error) {
	out, err := exec.Command("docker", args...).Output()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return "", fmt.Errorf("docker %s: %v: %s", args[0], err, strings.TrimSpace(string(exit.Stderr)))
	}
	return string(out), err
}

// runCheck runs check.sh with command's arguments before its own.
func runCheck(timeout time.Duration, homeDir, mode string, command ...string) ([]repo, []string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	args := append(append(command[1:], "sh", "-s", "--", homeDir, mode), caches...)
	cmd := exec.CommandContext(ctx, command[0], args...)
	cmd.Stdin = strings.NewReader(checkScript)
	cmd.Stderr = os.Stderr
	cmd.WaitDelay = 5 * time.Second
	out, err := cmd.Output()
	if err != nil {
		return nil, nil, fmt.Errorf("the check failed: %w", err)
	}
	return parseCheck(string(out))
}

func factsPath(dir, name string) string { return filepath.Join(dir, name+".json") }

func writeFacts(dir, name string, f facts) error {
	data, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	temporary := factsPath(dir, name) + ".new"
	if err := os.WriteFile(temporary, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, factsPath(dir, name))
}

// readFacts returns the orb's facts if they were recorded since it last started.
func readFacts(dir, name string, started time.Time) *facts {
	data, err := os.ReadFile(factsPath(dir, name))
	if err != nil {
		return nil
	}
	var f facts
	if json.Unmarshal(data, &f) != nil || !f.Recorded.After(started) {
		return nil
	}
	return &f
}

// record checks a running orb's checkouts as the image's user. Without a result it removes
// older facts, so cleanup checks the stopped orb instead.
func record(dir, name string) error {
	repos, doubts, err := runCheck(recordTimeout, home, "orb", "docker", "exec", "-i", name)
	if err != nil {
		os.Remove(factsPath(dir, name))
		return fmt.Errorf("could not record %s's git facts: %w", name, err)
	}
	return writeFacts(dir, name, facts{Recorded: time.Now().UTC(), Source: "pause", Repos: repos, Doubts: doubts})
}

// copyCheck checks a stopped orb from a copy of its home, which `docker cp` merges from every
// layer, and keeps the result until the orb starts again.
func (c *cleaner) copyCheck(name string) *facts {
	scratch := filepath.Join(c.state, "copy")
	os.RemoveAll(scratch)
	defer os.RemoveAll(scratch)
	f := &facts{Recorded: c.now, Source: "copy"}
	err := func() error {
		if err := os.MkdirAll(scratch, 0o700); err != nil {
			return err
		}
		ctx, cancel := context.WithTimeout(context.Background(), checkTimeout)
		defer cancel()
		cp := exec.CommandContext(ctx, "docker", "cp", name+":"+home, "-")
		args := []string{"--extract", "--directory", scratch, "--no-same-owner", "--exclude=node_modules", "--anchored"}
		for _, cache := range caches {
			args = append(args, "--exclude=user/"+cache)
		}
		extract := exec.CommandContext(ctx, "tar", args...)
		pipe, err := cp.StdoutPipe()
		if err != nil {
			return err
		}
		extract.Stdin = pipe
		cp.Stderr, extract.Stderr = os.Stderr, os.Stderr
		if err := cp.Start(); err != nil {
			return err
		}
		extractErr := extract.Run()
		if err := cp.Wait(); err != nil {
			return fmt.Errorf("docker cp: %w", err)
		}
		if extractErr != nil {
			return fmt.Errorf("tar: %w", extractErr)
		}
		// As root, on files the copy gave to root.
		copied := filepath.Join(scratch, filepath.Base(home))
		f.Repos, f.Doubts, err = runCheck(checkTimeout, copied, "copy", "env")
		// Named by their paths in the orb.
		inOrb := func(path string) string {
			if rest, ok := strings.CutPrefix(path, copied); ok {
				return home + rest
			}
			return path
		}
		for i := range f.Repos {
			f.Repos[i].Path = inOrb(f.Repos[i].Path)
		}
		for i := range f.Doubts {
			f.Doubts[i] = inOrb(f.Doubts[i])
		}
		return err
	}()
	if err != nil {
		// Not kept: the next run tries again.
		return &facts{Recorded: c.now, Source: "copy", Doubts: []string{"copy check failed: " + err.Error()}}
	}
	if err := writeFacts(c.facts, name, *f); err != nil {
		logf("could not keep %s's git facts: %v", name, err)
	}
	return f
}

// metadata asks Amp about the orb's thread. Any failure means unknown; a 404 also means a
// thread the key cannot read, so it is not taken as deleted: Amp sends `delete` for that.
func (c *cleaner) metadata(name string) *thread {
	id, ok := strings.CutPrefix(name, "amp-")
	if !ok || c.key == "" {
		return nil
	}
	request, err := http.NewRequest(http.MethodGet, c.ampURL+"/api/v2/threads/"+url.PathEscape("T-"+id)+"/metadata", nil)
	if err != nil {
		return nil
	}
	request.Header.Set("Authorization", "Bearer "+c.key)
	request.Header.Set("Accept", "application/json")
	response, err := c.client.Do(request)
	if err != nil {
		c.metadataFailure(err.Error())
		return nil
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		c.metadataFailure(fmt.Sprintf("T-%s: HTTP %d", id, response.StatusCode))
		return nil
	}
	var t thread
	if err := json.NewDecoder(response.Body).Decode(&t); err != nil {
		c.metadataFailure(err.Error())
		return nil
	}
	return &t
}

func (c *cleaner) metadataFailure(reason string) {
	if !c.metadataFailed {
		logf("archived check unavailable, the rules run without it: %s", reason)
		c.metadataFailed = true
	}
}

type container struct {
	ID    string `json:"Id"`
	Name  string `json:"Name"`
	Image string `json:"Image"`
	State struct {
		Status     string    `json:"Status"`
		StartedAt  time.Time `json:"StartedAt"`
		FinishedAt time.Time `json:"FinishedAt"`
	} `json:"State"`
	SizeRw int64 `json:"SizeRw"`
}

func inspect(size bool, ids ...string) ([]container, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	args := []string{"container", "inspect"}
	if size {
		args = append(args, "--size")
	}
	out, err := docker(append(args, ids...)...)
	if err != nil {
		return nil, err
	}
	var containers []container
	if err := json.Unmarshal([]byte(out), &containers); err != nil {
		return nil, err
	}
	for i := range containers {
		containers[i].Name = strings.TrimPrefix(containers[i].Name, "/")
	}
	return containers, nil
}

func containers(size bool, filters ...string) ([]container, error) {
	out, err := docker(append([]string{"ps", "--all", "--quiet", "--no-trunc"}, filters...)...)
	if err != nil {
		return nil, err
	}
	return inspect(size, strings.Fields(out)...)
}

// usage returns how full a filesystem is, in percent, as df counts it, and its usable size.
func usage(path string) (float64, float64, error) {
	var s syscall.Statfs_t
	if err := syscall.Statfs(path, &s); err != nil {
		return 0, 0, err
	}
	used := float64(s.Blocks-s.Bfree) * float64(s.Bsize)
	usable := used + float64(s.Bavail)*float64(s.Bsize)
	return 100 * used / usable, usable, nil
}

// drop removes a stopped orb, unless it started since it was judged.
func (c *cleaner) drop(o orb, why string) bool {
	if c.dry {
		logf("would drop %s: %s", o.Name, why)
		return true
	}
	// Under dispatch's lock, so no job starts the orb between the check and the removal.
	lock, err := os.OpenFile(filepath.Join(c.facts, o.Name+".lock"), os.O_CREATE|os.O_RDONLY, 0o644)
	if err != nil {
		logf("keep %s: %v", o.Name, err)
		return false
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		logf("keep %s: %v", o.Name, err)
		return false
	}
	// By ID, so an orb deleted and spawned again under the name is not removed.
	now, err := inspect(false, o.ID)
	if err != nil || len(now) != 1 || now[0].State.Status != "exited" || !now[0].State.StartedAt.Equal(o.Started) {
		logf("keep %s: it changed since it was checked", o.Name)
		return false
	}
	// Without --force, so an orb that starts now is not removed.
	if _, err := docker("rm", "--volumes", o.ID); err != nil {
		logf("could not drop %s: %v", o.Name, err)
		return false
	}
	os.Remove(factsPath(c.facts, o.Name))
	logf("dropped %s: %s", o.Name, why)
	return true
}

// ensureFacts makes sure a safe verdict comes from the stopped orb's files, checked in this
// run: a pause read the tree while the orb ran, and a remote branch an earlier check found
// may be gone. Facts that show the orb unsafe spare it the copy.
func (c *cleaner) ensureFacts(o *orb) {
	fresh := o.Facts != nil && o.Facts.Source == "copy" && o.Facts.Recorded.Equal(c.now)
	if o.Facts == nil || (!fresh && o.Facts.unsafe() == "") {
		o.Facts = c.copyCheck(o.Name)
	}
}

// pruneImages removes project snapshots and untagged images that no container uses and that
// are older than 3 days, never the image new orbs start from.
func (c *cleaner) pruneImages() {
	all, err := containers(false)
	if err != nil {
		logf("could not list containers for images: %v", err)
		return
	}
	used := map[string]bool{}
	for _, ct := range all {
		used[ct.Image] = true
	}
	if base, err := docker("image", "inspect", "--format", "{{.Id}}", c.image); err == nil {
		used[strings.TrimSpace(base)] = true
	}
	var ids []string
	for _, filter := range []string{"label=" + c.label + "-snapshot", "dangling=true"} {
		out, err := docker("image", "ls", "--quiet", "--no-trunc", "--filter", filter)
		if err != nil {
			logf("could not list images: %v", err)
			return
		}
		ids = append(ids, strings.Fields(out)...)
	}
	if len(ids) == 0 {
		return
	}
	out, err := docker(append([]string{"image", "inspect"}, ids...)...)
	if err != nil {
		logf("could not inspect images: %v", err)
		return
	}
	var images []struct {
		ID       string    `json:"Id"`
		Created  time.Time `json:"Created"`
		RepoTags []string  `json:"RepoTags"`
	}
	if err := json.Unmarshal([]byte(out), &images); err != nil {
		logf("could not read images: %v", err)
		return
	}
	seen := map[string]bool{}
	for _, image := range images {
		if seen[image.ID] || used[image.ID] || c.now.Sub(image.Created) < imagesAfter {
			continue
		}
		seen[image.ID] = true
		name := strings.Join(image.RepoTags, ", ")
		if name == "" {
			name = image.ID
		}
		if c.dry {
			logf("would remove image %s", name)
			continue
		}
		references := image.RepoTags
		if len(references) == 0 {
			references = []string{image.ID}
		}
		if _, err := docker(append([]string{"image", "rm"}, references...)...); err != nil {
			logf("could not remove image %s: %v", name, err)
			continue
		}
		logf("removed image %s", name)
	}
}

func (c *cleaner) run() error {
	stopped, err := containers(c.dry, "--filter", "label="+c.label, "--filter", "status=exited")
	if err != nil {
		return err
	}
	all, err := containers(false)
	if err != nil {
		return err
	}
	known := map[string]bool{}
	for _, ct := range all {
		known[ct.Name] = true
	}
	// Facts of orbs that are gone.
	entries, _ := os.ReadDir(c.facts)
	for _, entry := range entries {
		if name, ok := strings.CutSuffix(entry.Name(), ".json"); ok && !known[name] {
			os.Remove(filepath.Join(c.facts, entry.Name()))
		}
	}

	orbs := make([]orb, 0, len(stopped))
	for _, ct := range stopped {
		orbs = append(orbs, orb{
			ID: ct.ID, Name: ct.Name, Started: ct.State.StartedAt, Finished: ct.State.FinishedAt, Size: ct.SizeRw,
			Facts: readFacts(c.facts, ct.Name, ct.State.StartedAt),
		})
	}
	sort.Slice(orbs, func(i, j int) bool { return orbs[i].Finished.Before(orbs[j].Finished) })

	mode := "enforcing"
	if c.dry {
		mode = "dry run, nothing is removed"
	}
	logf("checking %d stopped orbs (%s)", len(orbs), mode)
	dropped := map[string]bool{}
	for i := range orbs {
		o := &orbs[i]
		if c.now.Sub(o.Finished) < archivedAfter {
			// No rule drops it yet, so it is not checked from a copy.
			logf("keep %s: stopped %s", o.Name, days(c.now.Sub(o.Finished)))
			continue
		}
		// Older facts decide whether a rule would drop the orb; only then is it checked again.
		if o.Facts == nil {
			c.ensureFacts(o)
		}
		var t *thread
		if o.Facts.unsafe() == "" && c.now.Sub(o.Finished) < settledAfter {
			t = c.metadata(o.Name)
		}
		drop, why := rule(*o, c.now, t)
		if drop {
			c.ensureFacts(o)
			drop, why = rule(*o, c.now, t)
		}
		if !drop {
			logf("keep %s: %s", o.Name, why)
		} else if c.drop(*o, why) {
			dropped[o.Name] = true
		}
	}
	c.pruneImages()

	full, usable, err := usage(c.dockerRoot)
	if err != nil {
		return err
	}
	// A dry run frees nothing, so it estimates from the sizes of the orbs' own files.
	estimate := func(o orb) {
		full -= 100 * float64(o.Size) / usable
	}
	if c.dry {
		for _, o := range orbs {
			if dropped[o.Name] {
				estimate(o)
			}
		}
	}
	if full > pressureHigh {
		logf("disk %.0f %% used, dropping safe orbs early, oldest first", full)
		for i := range orbs {
			if full <= pressureHigh {
				break
			}
			o := &orbs[i]
			if dropped[o.Name] || c.now.Sub(o.Finished) < pressureAfter {
				continue
			}
			c.ensureFacts(o)
			if o.Facts.unsafe() != "" || !c.drop(*o, fmt.Sprintf("safe, disk %.0f %% used", full)) {
				continue
			}
			dropped[o.Name] = true
			if c.dry {
				estimate(*o)
			} else if full, _, err = usage(c.dockerRoot); err != nil {
				return err
			}
		}
		if len(dropped) > 0 && !c.dry {
			c.pruneImages()
			if full, _, err = usage(c.dockerRoot); err != nil {
				return err
			}
		}
	}
	if full > pressureFull {
		var kept []string
		for _, o := range orbs {
			if !dropped[o.Name] && o.Facts.unsafe() != "" {
				kept = append(kept, o.Name)
			}
		}
		return fmt.Errorf("ALERT: orb disk %.0f %% used; stopped orbs with unpushed work are kept, since rescue is not built: %s", full, strings.Join(kept, " "))
	}
	return nil
}

func main() {
	if len(os.Args) == 3 && os.Args[1] == "record" {
		if err := record(os.Getenv("ORB_FACTS"), os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) != 2 || os.Args[1] != "run" {
		fmt.Fprintln(os.Stderr, "usage: orb-cleanup record ORB | orb-cleanup run")
		os.Exit(2)
	}
	state := os.Getenv("STATE_DIRECTORY")
	_, err := os.Stat(filepath.Join(state, "enforce"))
	c := &cleaner{
		facts:      os.Getenv("ORB_FACTS"),
		label:      os.Getenv("ORB_LABEL"),
		image:      os.Getenv("ORB_IMAGE"),
		dockerRoot: os.Getenv("ORB_DOCKER_ROOT"),
		state:      state,
		ampURL:     strings.TrimSuffix(os.Getenv("AMP_URL"), "/"),
		dry:        errors.Is(err, fs.ErrNotExist),
		now:        time.Now().UTC(),
		client:     &http.Client{Timeout: metadataTimeout},
	}
	if key, err := os.ReadFile(filepath.Join(os.Getenv("CREDENTIALS_DIRECTORY"), "amp-access-key")); err == nil {
		c.key = strings.TrimSpace(string(key))
	}
	if err := c.run(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}
