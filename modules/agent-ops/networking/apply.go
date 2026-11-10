package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"kahlstrm/config/ops-networking/routeros"
)

// The routers' REST endpoints, as in local-networking's provider.tf, and their entries in the
// layer's secret.
var routerHosts = map[string]struct{ URL, Secret string }{
	"kuberack":   {"https://kuberack.networking.kalski.xyz", "kuberack_rb5009"},
	"stationary": {"https://stationary.networking.kalski.xyz", "stationary_rb5009"},
}

// githubAPI is GitHub's REST API; the repository is public, so reads need no credential.
var githubAPI = "https://api.github.com"

func getJSON(ctx context.Context, uri string, out any) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, uri, nil)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	response, err := (&http.Client{Timeout: 30 * time.Second}).Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: %s", request.URL.Path, response.Status)
	}
	return json.NewDecoder(response.Body).Decode(out)
}

type pull struct {
	MergedAt       *time.Time `json:"merged_at"`
	MergeCommitSHA string     `json:"merge_commit_sha"`
	Base           struct {
		Ref string `json:"ref"`
	} `json:"base"`
}

// prLabels returns the PR's current labels that a person added, not an app: labels mark a
// PR for what the apply refuses by default, and agents' GitHub Apps may add labels too.
func prLabels(ctx context.Context, pr int) ([]string, error) {
	var issue struct {
		Labels []struct{ Name string } `json:"labels"`
	}
	base := fmt.Sprintf("%s/repos/%s/issues/%d", githubAPI, repository, pr)
	if err := getJSON(ctx, base, &issue); err != nil {
		return nil, err
	}
	byPerson := map[string]bool{}
	for page := 1; ; page++ {
		var events []struct {
			Event string `json:"event"`
			Actor struct {
				Type string `json:"type"`
			} `json:"actor"`
			Label struct{ Name string } `json:"label"`
		}
		if err := getJSON(ctx, fmt.Sprintf("%s/events?per_page=100&page=%d", base, page), &events); err != nil {
			return nil, err
		}
		for _, e := range events {
			if e.Event == "labeled" {
				byPerson[e.Label.Name] = e.Actor.Type == "User"
			}
		}
		if len(events) < 100 {
			break
		}
	}
	var labels []string
	for _, l := range issue.Labels {
		if byPerson[l.Name] {
			labels = append(labels, l.Name)
		}
	}
	return labels, nil
}

func git(ctx context.Context, dir string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return strings.TrimSpace(string(out)), nil
}

// checkout returns the local-networking directory and commit of the current checkout, which
// must be clean and at origin/main as last fetched.
func checkout(ctx context.Context) (string, string, error) {
	top, err := git(ctx, ".", "rev-parse", "--show-toplevel")
	if err != nil {
		return "", "", err
	}
	if status, err := git(ctx, top, "status", "--porcelain"); err != nil {
		return "", "", err
	} else if status != "" {
		return "", "", errors.New("the checkout has uncommitted changes")
	}
	head, err := git(ctx, top, "rev-parse", "HEAD")
	if err != nil {
		return "", "", err
	}
	main, err := git(ctx, top, "rev-parse", "origin/main")
	if err != nil {
		return "", "", err
	}
	if head != main {
		return "", "", errors.New("check out origin/main after `git fetch origin main`; plans run only on merged main")
	}
	return filepath.Join(top, "infra/local-networking"), head, nil
}

// How terraform handles a command's output.
const (
	quiet  = iota // shown only when the command fails
	shown         // streamed
	secret        // stdout never shown, since it holds unmasked values; stderr when it fails
)

// terraform runs Terraform with the runner's GCP key and returns its stdout and exit code.
// Exit code 2 is no error when the arguments include -detailed-exitcode.
func terraform(ctx context.Context, dir string, output int, args ...string) ([]byte, int, error) {
	cmd := exec.CommandContext(ctx, "terraform", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GOOGLE_APPLICATION_CREDENTIALS="+keyFile(), "TF_IN_AUTOMATION=1", "TF_INPUT=0")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if output == shown {
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	}
	err := cmd.Run()
	code := cmd.ProcessState.ExitCode()
	if err != nil && code == 2 && slices.Contains(args, "-detailed-exitcode") {
		return stdout.Bytes(), code, nil
	}
	if err != nil {
		if output == quiet {
			os.Stdout.Write(stdout.Bytes())
		}
		if output != shown {
			os.Stderr.Write(stderr.Bytes())
		}
		return nil, code, fmt.Errorf("terraform %s: %w", args[0], err)
	}
	return stdout.Bytes(), code, nil
}

// releaseStaleLock removes a state lock this runner left behind, such as when a deployment
// of ops restarted it mid-apply. Its own flock shows that no run of it holds the lock now.
// A lock held by anyone else stops the run.
func releaseStaleLock(ctx context.Context, g *gcp, dir string) error {
	data, generation, err := g.object(ctx, stateBucket, "local-networking/default.tflock")
	if errors.Is(err, errNotFound) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read the state lock: %w", err)
	}
	// The GCS backend's lock ID is the lock object's generation, not the ID in its JSON.
	var info struct{ Who, Operation, Created string }
	if err := json.Unmarshal(data, &info); err != nil {
		return fmt.Errorf("state lock: %w", err)
	}
	me, err := user.Current()
	if err != nil {
		return err
	}
	host, err := os.Hostname()
	if err != nil {
		return err
	}
	if info.Who != me.Username+"@"+host {
		return fmt.Errorf("the state is locked by %s (%s since %s); wait for it or ask a maintainer", info.Who, info.Operation, info.Created)
	}
	fmt.Printf("Releasing this runner's stale state lock from %s (%s).\n", info.Created, info.Operation)
	_, _, err = terraform(ctx, dir, quiet, "force-unlock", "-force", generation)
	return err
}

func showPlan(ctx context.Context, dir string) ([]change, error) {
	// The JSON holds unmasked secrets: it stays in this process.
	data, _, err := terraform(ctx, dir, secret, "show", "-json", planPath())
	if err != nil {
		return nil, err
	}
	return parsePlan(data)
}

func planCommand(ctx context.Context, pr int) error {
	var p pull
	if err := getJSON(ctx, fmt.Sprintf("%s/repos/%s/pulls/%d", githubAPI, repository, pr), &p); err != nil {
		return err
	}
	if p.MergedAt == nil || p.Base.Ref != "main" {
		return fmt.Errorf("PR #%d is not merged into main", pr)
	}
	dir, commit, err := checkout(ctx)
	if err != nil {
		return err
	}
	if _, err := git(ctx, dir, "merge-base", "--is-ancestor", p.MergeCommitSHA, "HEAD"); err != nil {
		return fmt.Errorf("PR #%d's merge commit is not in the checkout: %w", pr, err)
	}
	labels, err := prLabels(ctx, pr)
	if err != nil {
		return err
	}
	g, err := newGCP(ctx, keyFile())
	if err != nil {
		return err
	}
	os.Remove(metaPath())
	os.Remove(planPath())
	if _, _, err := terraform(ctx, dir, quiet, "init", "-input=false"); err != nil {
		return err
	}
	if err := releaseStaleLock(ctx, g, dir); err != nil {
		return err
	}
	// Exit code 2 means the plan changes something, if only an output, which consumers such
	// as ops-home-assistant read from the state.
	_, code, err := terraform(ctx, dir, quiet, "plan", "-input=false", "-lock-timeout=60s", "-detailed-exitcode", "-out="+planPath())
	if err != nil {
		return err
	}
	changes, err := showPlan(ctx, dir)
	if err != nil {
		return err
	}
	meta, _ := json.Marshal(planMeta{PR: pr, Commit: commit, Dir: dir})
	if err := os.WriteFile(metaPath(), meta, 0600); err != nil {
		return err
	}
	fmt.Print(summary(fmt.Sprintf("### local-networking plan for #%d at %.12s", pr, commit), changes, labels))
	if code == 0 {
		os.Remove(metaPath())
		os.Remove(planPath())
		fmt.Println("\nNothing to apply.")
	} else if missing := blocked(changes, labels); len(missing) > 0 {
		fmt.Printf("\nThe apply will refuse this plan until a maintainer adds %s to #%d and plans again.\n", strings.Join(missing, " and "), pr)
	} else {
		fmt.Println("\nPost this summary to the PR and the requesting thread, then run `ops-networking apply`.")
	}
	return nil
}

// deadline gives a router's restore time to cover the apply: 5 minutes, plus 15 seconds per
// change on it, at most 15 minutes.
func deadline(changes int) time.Duration {
	return min(5*time.Minute+time.Duration(changes)*15*time.Second, 15*time.Minute)
}

func applyCommand(ctx context.Context) error {
	meta, err := readMeta()
	if err != nil {
		return err
	}
	dir, commit, err := checkout(ctx)
	if err != nil {
		return err
	}
	if dir != meta.Dir || commit != meta.Commit {
		return fmt.Errorf("the checkout moved from %.12s since the plan; plan again", meta.Commit)
	}
	changes, err := showPlan(ctx, dir)
	if err != nil {
		return err
	}
	// Labels are read again, so removing one stops an apply planned with it.
	labels, err := prLabels(ctx, meta.PR)
	if err != nil {
		return err
	}
	if missing := blocked(changes, labels); len(missing) > 0 {
		return fmt.Errorf("refused: PR #%d lacks %s for this plan; see its summary", meta.PR, strings.Join(missing, " and "))
	}
	g, err := newGCP(ctx, keyFile())
	if err != nil {
		return err
	}
	touched := routers(changes)
	armed, err := arm(ctx, g, touched)
	if err != nil {
		return err
	}
	earliest := time.Time{}
	for _, a := range armed {
		if earliest.IsZero() || a.local.Before(earliest) {
			earliest = a.local
		}
	}
	applyCtx := ctx
	if !earliest.IsZero() {
		var cancel context.CancelFunc
		// Stop before the first restore fires, rather than race it.
		applyCtx, cancel = context.WithDeadline(ctx, earliest.Add(-30*time.Second))
		defer cancel()
	}
	_, _, applyErr := terraform(applyCtx, dir, shown, "apply", "-input=false", "-lock-timeout=60s", planPath())
	os.Remove(planPath())
	os.Remove(metaPath())
	checkErr := settle(ctx, armed)
	return errors.Join(applyErr, checkErr)
}

type armedRouter struct {
	name   string
	router *routeros.Router
	fires  time.Time // in the router's clock
	local  time.Time // in ours
}

// arm checks each router the plan touches and schedules its restore. A router that restored
// itself after an earlier apply is reported first; its leftover backup is replaced.
func arm(ctx context.Context, g *gcp, touched map[string]int) ([]armedRouter, error) {
	if len(touched) == 0 {
		return nil, nil
	}
	data, _, err := g.accessSecret(ctx, project, "local-networking")
	if err != nil {
		return nil, fmt.Errorf("read the router credentials: %w", err)
	}
	var config map[string]struct{ Username, Password string }
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, errors.New("the local-networking secret is not the expected JSON")
	}
	names := make([]string, 0, len(touched))
	for name := range touched {
		names = append(names, name)
	}
	sort.Strings(names)
	var armed []armedRouter
	fail := func(err error) ([]armedRouter, error) {
		for _, a := range armed {
			err = errors.Join(err, a.router.Disarm(context.WithoutCancel(ctx)))
		}
		return nil, err
	}
	for _, name := range names {
		host, ok := routerHosts[name]
		if !ok {
			return fail(fmt.Errorf("the plan changes router %q, which has no dead-man switch here", name))
		}
		credentials := config[host.Secret]
		r := &routeros.Router{Base: host.URL, User: credentials.Username, Password: credentials.Password}
		if restored, err := r.Restored(ctx); err != nil {
			return fail(fmt.Errorf("%s: %w", name, err))
		} else if restored {
			fmt.Printf("\n**%s RESTORED ITSELF after an earlier apply** (its backup is still there). Its configuration predates that apply, so the state has drift: fix forward with a new plan.\n\n", strings.ToUpper(name))
		}
		if err := r.Healthy(ctx); err != nil {
			return fail(fmt.Errorf("%s is unhealthy before the apply, so a restore could not be told apart: %w", name, err))
		}
		delay := deadline(touched[name])
		fires, err := r.Arm(ctx, delay)
		if err != nil {
			return fail(fmt.Errorf("%s: arm: %w", name, err))
		}
		armed = append(armed, armedRouter{name: name, router: r, fires: fires, local: time.Now().Add(delay)})
		fmt.Printf("%s: a backup restores itself at %s router time unless the apply passes its checks.\n", name, fires.Format("15:04:05"))
	}
	return armed, nil
}

// settle checks the armed routers after the apply, each on its own: it disarms one that is
// healthy while its restore is still pending, reports one whose restore already fired, and
// waits for the restore of one that stays unhealthy. No router waits on another's checks.
func settle(ctx context.Context, armed []armedRouter) error {
	ctx = context.WithoutCancel(ctx)
	failures := make([]error, len(armed))
	var wg sync.WaitGroup
	for i, a := range armed {
		wg.Add(1)
		go func() {
			defer wg.Done()
			failures[i] = settleOne(ctx, a)
		}()
	}
	wg.Wait()
	return errors.Join(failures...)
}

func settleOne(ctx context.Context, a armedRouter) error {
	// Checks stop 20 seconds before the restore, so a disarm never races it.
	check, cancel := context.WithDeadline(ctx, a.local.Add(-20*time.Second))
	err := a.router.Healthy(check)
	for err != nil && check.Err() == nil {
		select {
		case <-check.Done():
		case <-time.After(10 * time.Second):
			err = a.router.Healthy(check)
		}
	}
	pending := false
	if err == nil {
		pending, err = a.router.Pending(check)
		if err == nil && !pending {
			err = errors.New("its restore job is gone")
		}
	}
	if err == nil {
		err = a.router.Disarm(check)
		if err == nil {
			cancel()
			fmt.Printf("%s: healthy after the apply; restore cancelled and backup deleted.\n", a.name)
			return nil
		}
		// Disarm removes the job first: without it, nothing restores, and only the backup is left.
		if pending, pendingErr := a.router.Pending(ctx); pendingErr == nil && !pending {
			cancel()
			return fmt.Errorf("%s is healthy and its restore cancelled, but deleting its backup failed: %w", a.name, err)
		}
	}
	cancel()
	fmt.Printf("\n**%s DID NOT PASS ITS CHECKS IN TIME (%v). IT RESTORES ITS PREVIOUS CONFIGURATION AT %s ROUTER TIME AND REBOOTS, IF IT HAS NOT ALREADY.**\n", strings.ToUpper(a.name), err, a.fires.Format("15:04:05"))
	return fmt.Errorf("%s: restore %s", a.name, waitRestore(ctx, a))
}

func waitRestore(ctx context.Context, a armedRouter) string {
	time.Sleep(time.Until(a.local))
	for end := time.Now().Add(5 * time.Minute); time.Now().Before(end); time.Sleep(15 * time.Second) {
		check, cancel := context.WithTimeout(ctx, 20*time.Second)
		restored, err := a.router.Restored(check)
		healthy := err == nil && restored && a.router.Healthy(check) == nil
		cancel()
		if healthy {
			if err := a.router.Disarm(ctx); err != nil {
				return "done; deleting its backup failed: " + err.Error()
			}
			return "done: it runs its configuration from before the apply and is healthy; the state has drift, so fix forward with a new plan"
		}
	}
	return "not confirmed: the router is unreachable or unhealthy five minutes after the restore time; a maintainer must check it"
}
