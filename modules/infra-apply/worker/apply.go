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

	"kahlstrm/config/infra-apply-worker/routeros"
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

// mergedPRs returns the PRs merged into main whose commits change the layer or the shared
// modules since the last clean apply, or, without one, the last such commit's PR. These are
// the PRs whose labels count for the plan.
func mergedPRs(ctx context.Context, top, head string) ([]int, error) {
	args := []string{"log", "--format=%H", "-1", head}
	if data, err := os.ReadFile(appliedPath()); err == nil {
		base := strings.TrimSpace(string(data))
		if _, err := git(ctx, top, "merge-base", "--is-ancestor", base, head); err == nil {
			args = []string{"log", "--format=%H", base + ".." + head}
		}
	}
	out, err := git(ctx, top, append(args, "--", "infra/"+layer, "infra/modules")...)
	if err != nil {
		return nil, err
	}
	seen := map[int]bool{}
	var prs []int
	for _, sha := range strings.Fields(out) {
		var pulls []struct {
			Number         int        `json:"number"`
			MergedAt       *time.Time `json:"merged_at"`
			MergeCommitSHA string     `json:"merge_commit_sha"`
			Base           struct {
				Ref string `json:"ref"`
			} `json:"base"`
		}
		if err := getJSON(ctx, fmt.Sprintf("%s/repos/%s/commits/%s/pulls", githubAPI, repository, sha), &pulls); err != nil {
			return nil, err
		}
		for _, p := range pulls {
			if p.MergedAt != nil && p.Base.Ref == "main" && p.MergeCommitSHA == sha && !seen[p.Number] {
				seen[p.Number] = true
				prs = append(prs, p.Number)
			}
		}
	}
	sort.Ints(prs)
	return prs, nil
}

// prLabels returns the current labels of the PRs. The agent that opens a PR adds a label to
// declare what the apply refuses by default, so who added it does not matter.
func prLabels(ctx context.Context, prs []int) ([]string, error) {
	var labels []string
	for _, pr := range prs {
		var issue struct {
			Labels []struct{ Name string } `json:"labels"`
		}
		if err := getJSON(ctx, fmt.Sprintf("%s/repos/%s/issues/%d", githubAPI, repository, pr), &issue); err != nil {
			return nil, err
		}
		for _, l := range issue.Labels {
			if !slices.Contains(labels, l.Name) {
				labels = append(labels, l.Name)
			}
		}
	}
	return labels, nil
}

// prList formats PR numbers for messages.
func prList(prs []int) string {
	if len(prs) == 0 {
		return "no merged PR"
	}
	names := make([]string, len(prs))
	for i, pr := range prs {
		names[i] = fmt.Sprintf("#%d", pr)
	}
	return strings.Join(names, ", ")
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

// update clones the repository into the layer's checkout once, then checks out main as just
// fetched. The checkout is this layer's own: nobody else writes to it, so the plan runs only
// code merged to main. A clone that was interrupted is started again.
func update(ctx context.Context) error {
	dir := checkoutDirectory()
	if _, err := os.Stat(filepath.Join(dir, ".git", "HEAD")); errors.Is(err, os.ErrNotExist) {
		temporary := dir + ".new"
		if err := errors.Join(os.RemoveAll(temporary), os.RemoveAll(dir)); err != nil {
			return err
		}
		cmd := exec.CommandContext(ctx, "git", "clone", "--quiet", "--no-checkout", "https://github.com/"+repository, temporary)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("git clone: %w: %s", err, strings.TrimSpace(string(out)))
		}
		if err := os.Rename(temporary, dir); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	return fetch(ctx)
}

// fetch updates origin/main, checks it out and removes what an interrupted run left behind.
func fetch(ctx context.Context) error {
	for _, args := range [][]string{
		{"fetch", "--quiet", "origin", "main"},
		{"checkout", "--quiet", "--force", "--detach", "origin/main"},
		// Terraform's providers and module cache are ignored files; keep them between runs.
		{"clean", "--quiet", "--force", "-d"},
	} {
		if _, err := git(ctx, checkoutDirectory(), args...); err != nil {
			return err
		}
	}
	return nil
}

// checkout returns the layer's directory and commit in the checkout, which must be clean and
// at origin/main as last fetched.
func checkout(ctx context.Context) (string, string, error) {
	top := checkoutDirectory()
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
		return "", "", fmt.Errorf("the checkout is not at origin/main; run infra-apply plan %s again", layer)
	}
	return filepath.Join(top, "infra", layer), head, nil
}

// How terraform handles a command's output.
const (
	quiet  = iota // shown only when the command fails
	shown         // streamed
	secret        // stdout never shown, since it holds unmasked values; stderr when it fails
)

// terraform runs Terraform with the layer's GCP key and returns its stdout and exit code.
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

// releaseStaleLock removes a state lock this worker left behind, such as when a reboot of the
// host killed it mid-apply. Its own flock shows that no run of it holds the lock now.
// A lock held by anyone else stops the run.
func releaseStaleLock(ctx context.Context, g *gcp, dir string) error {
	data, generation, err := g.object(ctx, stateBucket, layer+"/default.tflock")
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
	fmt.Printf("Releasing this layer's stale state lock from %s (%s).\n", info.Created, info.Operation)
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

func planCommand(ctx context.Context) error {
	if err := update(ctx); err != nil {
		return err
	}
	dir, commit, err := checkout(ctx)
	if err != nil {
		return err
	}
	prs, err := mergedPRs(ctx, checkoutDirectory(), commit)
	if err != nil {
		return err
	}
	labels, err := prLabels(ctx, prs)
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
	// Exit code 2 means the plan changes something, if only an output, which other layers
	// read from the state.
	_, code, err := terraform(ctx, dir, quiet, "plan", "-input=false", "-lock-timeout=60s", "-detailed-exitcode", "-out="+planPath())
	if err != nil {
		return err
	}
	changes, err := showPlan(ctx, dir)
	if err != nil {
		return err
	}
	meta, _ := json.Marshal(planMeta{Commit: commit, PRs: prs})
	if err := os.WriteFile(metaPath(), meta, 0600); err != nil {
		return err
	}
	fmt.Print(summary(fmt.Sprintf("### %s plan at %.12s, covering %s", layer, commit, prList(prs)), changes, labels))
	if code == 0 {
		os.Remove(metaPath())
		os.Remove(planPath())
		fmt.Println("\nNothing to apply.")
	} else if missing := blocked(changes, labels); len(missing) > 0 {
		fmt.Printf("\nThe apply will refuse this plan until one of %s declares it with %s, naming what changes in its description; then plan again.\n", prList(prs), strings.Join(missing, " and "))
	} else {
		fmt.Printf("\nPost this summary to the PRs and the requesting thread, then run `infra-apply apply %s`.\n", layer)
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
	// Main is fetched again: the saved plan applies only to the commit it was made from.
	if err := fetch(ctx); err != nil {
		return err
	}
	dir, commit, err := checkout(ctx)
	if err != nil {
		return err
	}
	if commit != meta.Commit {
		return fmt.Errorf("main moved from %.12s to %.12s since the plan; run infra-apply plan %s again", meta.Commit, commit, layer)
	}
	changes, err := showPlan(ctx, dir)
	if err != nil {
		return err
	}
	// Labels are read again, so removing one stops an apply planned with it.
	labels, err := prLabels(ctx, meta.PRs)
	if err != nil {
		return err
	}
	if missing := blocked(changes, labels); len(missing) > 0 {
		return fmt.Errorf("refused: %s lack %s for this plan; see its summary", prList(meta.PRs), strings.Join(missing, " and "))
	}
	g, err := newGCP(ctx, keyFile())
	if err != nil {
		return err
	}
	// An apply that was killed leaves its lock; the saved plan then fails as stale, and the
	// next plan starts clean.
	if err := releaseStaleLock(ctx, g, dir); err != nil {
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
	if applyErr == nil && checkErr == nil {
		if err := place(appliedPath(), []byte(commit+"\n"), 0600); err != nil {
			return err
		}
	}
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
