package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always"}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// clone makes a checkout at dir of a remote with one pushed commit, and names the remote by a
// network URL, as if it had been cloned from there.
func clone(t *testing.T, remote, dir string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(dir), 0o755)
	git(t, filepath.Dir(dir), "clone", "--quiet", remote, dir)
	git(t, dir, "remote", "set-url", "origin", "https://127.0.0.1:1/repo.git")
}

func check(t *testing.T, homeDir, mode string) ([]repo, []string) {
	t.Helper()
	repos, doubts, err := runCheck(time.Minute, homeDir, mode, "env")
	if err != nil {
		t.Fatal(err)
	}
	return repos, doubts
}

func TestCheckRecordsWhatIsNowhereElse(t *testing.T) {
	base := t.TempDir()
	remote := filepath.Join(base, "remote.git")
	seed := filepath.Join(base, "seed")
	os.MkdirAll(seed, 0o755)
	git(t, seed, "init", "--quiet")
	write(t, filepath.Join(seed, ".gitignore"), ".env\n")
	write(t, filepath.Join(seed, "tracked"), "one\n")
	git(t, seed, "add", ".")
	git(t, seed, "commit", "--quiet", "-m", "seed")
	git(t, base, "clone", "--quiet", "--bare", seed, remote)

	homeDir := filepath.Join(base, "home")
	os.MkdirAll(filepath.Join(homeDir, "workspace"), 0o755)

	// Pushed and clean: node_modules is left out, and an ignored file is only counted.
	clean := filepath.Join(homeDir, "workspace", "clean")
	clone(t, remote, clean)
	write(t, filepath.Join(clean, "node_modules", "left-out"), "x")
	write(t, filepath.Join(clean, ".env"), "x")

	// A commit on a detached HEAD, which no branch holds.
	detached := filepath.Join(homeDir, "workspace", "detached")
	clone(t, remote, detached)
	git(t, detached, "checkout", "--quiet", "--detach")
	git(t, detached, "commit", "--quiet", "--allow-empty", "-m", "round-1")

	// A local branch behind which HEAD sits clean on main.
	branch := filepath.Join(homeDir, "workspace", "branch")
	clone(t, remote, branch)
	git(t, branch, "checkout", "--quiet", "-b", "feature")
	git(t, branch, "commit", "--quiet", "--allow-empty", "-m", "feature")
	git(t, branch, "checkout", "--quiet", "main")

	// Pushed, but only to a repository on the same disk, which goes with the orb.
	local := filepath.Join(homeDir, "workspace", "local")
	clone(t, remote, local)
	git(t, local, "remote", "set-url", "origin", remote)

	// A stash, a changed tracked file and an untracked one, which its config hides.
	dirty := filepath.Join(homeDir, "dirty")
	clone(t, remote, dirty)
	git(t, dirty, "config", "status.showUntrackedFiles", "no")
	write(t, filepath.Join(dirty, "tracked"), "two\n")
	git(t, dirty, "stash", "--quiet")
	write(t, filepath.Join(dirty, "tracked"), "three\n")
	write(t, filepath.Join(dirty, "new"), "x")

	// Checkouts in a tool's cache are no one's work.
	clone(t, remote, filepath.Join(homeDir, ".cargo", "git", "checkouts", "dependency"))

	repos, doubts := check(t, homeDir, "orb")
	if len(doubts) != 0 {
		t.Fatalf("doubts: %v", doubts)
	}
	byPath := map[string]repo{}
	for _, r := range repos {
		byPath[r.Path] = r
	}
	if len(byPath) != 5 {
		t.Fatalf("want 5 checkouts, got %+v", repos)
	}
	head := git(t, clean, "rev-parse", "HEAD")
	want := map[string]repo{
		clean:    {Path: clean, Branch: "main", Head: head, Ignored: 1},
		detached: {Path: detached, Branch: "(detached)", Head: git(t, detached, "rev-parse", "HEAD"), Unpushed: 1},
		branch:   {Path: branch, Branch: "main", Head: head, Unpushed: 1},
		local:    {Path: local, Branch: "main", Head: head, Unpushed: 1},
		dirty:    {Path: dirty, Branch: "main", Head: head, Changed: 1, Untracked: 1, Stashes: 1},
	}
	for path, w := range want {
		if byPath[path] != w {
			t.Errorf("%s:\n got %+v\nwant %+v", path, byPath[path], w)
		}
	}
	f := facts{Repos: []repo{byPath[clean]}}
	if reason := f.unsafe(); reason != "" {
		t.Errorf("a clean checkout with ignored files is unsafe: %s", reason)
	}
	f = facts{Repos: []repo{byPath[clean], byPath[dirty]}}
	if reason := f.unsafe(); !strings.Contains(reason, "1 stashes") || !strings.Contains(reason, "1 untracked") {
		t.Errorf("unsafe reason: %q", reason)
	}
}

func TestCheckDoubtsWhatACopyCannotShow(t *testing.T) {
	base := t.TempDir()
	seed := filepath.Join(base, "home", "repo")
	os.MkdirAll(seed, 0o755)
	git(t, seed, "init", "--quiet")
	git(t, seed, "commit", "--quiet", "--allow-empty", "-m", "seed")
	git(t, seed, "worktree", "add", "--quiet", filepath.Join(base, "home", "tree"))
	empty := filepath.Join(base, "home", "empty")
	os.MkdirAll(empty, 0o755)
	git(t, empty, "init", "--quiet")

	_, doubts := check(t, filepath.Join(base, "home"), "copy")
	got := strings.Join(doubts, "\n")
	for _, want := range []string{"repo: has linked worktrees", "tree: linked checkout", "empty: cannot read HEAD"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing doubt %q in:\n%s", want, got)
		}
	}

	// In the orb itself, a linked worktree outside the home directory is checked too.
	outside := filepath.Join(base, "outside")
	git(t, seed, "worktree", "add", "--quiet", outside)
	repos, _ := check(t, filepath.Join(base, "home"), "orb")
	found := false
	for _, r := range repos {
		found = found || r.Path == outside
	}
	if !found {
		t.Errorf("worktree outside the home directory not checked: %+v", repos)
	}
}

func TestCheckOfACopyTrustsOnlyRemotesItFetches(t *testing.T) {
	base := t.TempDir()
	remote := filepath.Join(base, "remote.git")
	git(t, base, "init", "--quiet", "--bare", remote)
	seed := filepath.Join(base, "seed")
	clone(t, remote, seed)
	git(t, seed, "remote", "set-url", "origin", remote)
	git(t, seed, "commit", "--quiet", "--allow-empty", "-m", "seed")
	git(t, seed, "push", "--quiet", "origin", "main")

	// Its tracking branch has the commit, but the remote cannot be reached to confirm it.
	dir := filepath.Join(base, "home", "repo")
	clone(t, remote, dir)
	repos, _ := check(t, filepath.Join(base, "home"), "copy")
	if len(repos) != 1 || repos[0].Unpushed != 1 {
		t.Errorf("an unconfirmed remote counted: %+v", repos)
	}
	repos, _ = check(t, filepath.Join(base, "home"), "orb")
	if len(repos) != 1 || repos[0].Unpushed != 0 {
		t.Errorf("in the orb, the tracking branch did not count: %+v", repos)
	}

	// A branch the remote deleted, still under the check's namespace from an earlier fetch,
	// does not count when the remote is fetched again.
	// The remote is reachable here, as a command that is not a local path.
	git(t, dir, "config", "protocol.ext.allow", "always")
	git(t, dir, "remote", "set-url", "origin", "ext::%S "+remote)
	repos, _ = check(t, filepath.Join(base, "home"), "copy")
	if len(repos) != 1 || repos[0].Unpushed != 0 {
		t.Fatalf("a remote that has the commit did not count: %+v", repos)
	}
	git(t, dir, "commit", "--quiet", "--allow-empty", "-m", "only here")
	git(t, dir, "update-ref", "refs/orb-cleanup/1/gone", "HEAD")
	git(t, dir, "update-ref", "refs/orb-cleanup/origin/gone", "HEAD")
	repos, _ = check(t, filepath.Join(base, "home"), "copy")
	if len(repos) != 1 || repos[0].Unpushed != 1 {
		t.Errorf("an earlier fetch's refs counted: %+v", repos)
	}
}

func TestParseCheckNeedsTheWholeOutput(t *testing.T) {
	if _, _, err := parseCheck("repo\t/h/r\tmain\tabc\t0\t0\t0\t0\t0\n"); err == nil {
		t.Error("output without done was accepted")
	}
	if _, _, err := parseCheck("repo\t/h/r\tmain\tabc\t0\tx\t0\t0\t0\ndone\n"); err == nil {
		t.Error("a bad count was accepted")
	}
}

func TestRules(t *testing.T) {
	now := time.Date(2026, 11, 22, 12, 0, 0, 0, time.UTC)
	safe := &facts{Repos: []repo{{Path: "/home/user/workspace/repo", Ignored: 3}}}
	unsafe := &facts{Repos: []repo{{Path: "/home/user/workspace/repo", Unpushed: 1}}}
	archived := func(updated time.Duration) *thread { return &thread{Archived: true, Updated: now.Add(-updated)} }
	for _, tc := range []struct {
		name    string
		facts   *facts
		stopped time.Duration
		thread  *thread
		drop    bool
	}{
		{"archived a day ago", safe, 25 * time.Hour, archived(25 * time.Hour), true},
		{"archived, stopped under a day", safe, 23 * time.Hour, archived(25 * time.Hour), false},
		{"archived, but updated within the day", safe, 3 * day, archived(2 * time.Hour), false},
		{"not archived", safe, 3 * day, &thread{Updated: now.Add(-3 * day)}, false},
		{"archive unknown", safe, 3 * day, nil, false},
		{"archived, idle time unknown", safe, 3 * day, &thread{Archived: true}, false},
		{"stopped almost 7 days", safe, settledAfter - time.Minute, nil, false},
		{"stopped 7 days", safe, settledAfter, nil, true},
		{"unsafe, archived", unsafe, 3 * day, archived(3 * day), false},
		{"unsafe, stopped 30 days", unsafe, 31 * day, nil, false},
		{"no facts, stopped 30 days", nil, 31 * day, nil, false},
		{"doubt", &facts{Doubts: []string{"/home/user: cannot search"}}, 8 * day, nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			drop, why := rule(orb{Facts: tc.facts, Finished: now.Add(-tc.stopped)}, now, tc.thread)
			if drop != tc.drop {
				t.Errorf("drop = %v (%s), want %v", drop, why, tc.drop)
			}
		})
	}
	_, why := rule(orb{Facts: unsafe, Finished: now.Add(-31 * day)}, now, nil)
	if !strings.Contains(why, "kept until unpushed work can be rescued") {
		t.Errorf("why = %q", why)
	}
}

func TestFactsOfAnOrbThatStartedSinceAreStale(t *testing.T) {
	dir := t.TempDir()
	recorded := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	if err := writeFacts(dir, "amp-one", facts{Recorded: recorded, Source: "pause"}); err != nil {
		t.Fatal(err)
	}
	if readFacts(dir, "amp-one", recorded.Add(-time.Hour)) == nil {
		t.Error("facts recorded after the orb started were not read")
	}
	if readFacts(dir, "amp-one", recorded.Add(time.Minute)) != nil {
		t.Error("facts recorded before the orb last started were used")
	}
}

func TestMetadata(t *testing.T) {
	var authorization, path string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorization, path = r.Header.Get("Authorization"), r.URL.Path
		switch r.URL.Path {
		case "/api/v2/threads/T-01a1ff93-5a52/metadata":
			w.Write([]byte(`{"id":"T-01a1ff93-5a52","archived":true,"updatedAt":"2026-11-20T10:00:00.000Z"}`))
		default:
			http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		}
	}))
	defer server.Close()
	c := &cleaner{ampURL: server.URL, key: "sgamp_test", client: server.Client()}
	got := c.metadata("amp-01a1ff93-5a52")
	if got == nil || !got.Archived || !got.Updated.Equal(time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)) {
		t.Fatalf("metadata = %+v", got)
	}
	if authorization != "Bearer sgamp_test" || path != "/api/v2/threads/T-01a1ff93-5a52/metadata" {
		t.Errorf("asked %s with %q", path, authorization)
	}
	if got := c.metadata("amp-gone"); got != nil || !c.metadataFailed {
		t.Errorf("a 404 gave %+v", got)
	}
	if got := c.metadata("other"); got != nil {
		t.Errorf("a name without amp- gave %+v", got)
	}
}
