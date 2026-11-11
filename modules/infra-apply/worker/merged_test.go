package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The labels that count come from the PRs merged since the last clean apply that change the
// layer or the shared modules, not from PRs that change other layers or are only contained in
// the commit.
func TestMergedPRs(t *testing.T) {
	top := t.TempDir()
	stateDirectory, layer = t.TempDir(), "local-networking"
	gitIn := func(args ...string) string {
		cmd := exec.Command("git", append([]string{"-C", top, "-c", "user.name=t", "-c", "user.email=t@t"}, args...)...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
		return strings.TrimSpace(string(out))
	}
	commit := func(path string) string {
		full := filepath.Join(top, path)
		os.MkdirAll(filepath.Dir(full), 0755)
		os.WriteFile(full, []byte(path+fmt.Sprint(len(gitIn("log", "--oneline", "--all")))), 0644)
		gitIn("add", "-A")
		gitIn("commit", "-qm", path)
		return gitIn("rev-parse", "HEAD")
	}
	gitIn("init", "-q")
	gitIn("commit", "-q", "--allow-empty", "-m", "root")
	applied := commit("infra/local-networking/a.tf")
	module := commit("infra/modules/m/main.tf")
	other := commit("infra/local-talos/b.tf")
	layerChange := commit("infra/local-networking/c.tf")
	pulls := map[string]string{
		applied: `[{"number": 1, "merged_at": "2026-01-01T00:00:00Z", "merge_commit_sha": "` + applied + `", "base": {"ref": "main"}}]`,
		module:  `[{"number": 2, "merged_at": "2026-01-01T00:00:00Z", "merge_commit_sha": "` + module + `", "base": {"ref": "main"}}]`,
		other:   `[{"number": 3, "merged_at": "2026-01-01T00:00:00Z", "merge_commit_sha": "` + other + `", "base": {"ref": "main"}}]`,
		// A PR that only contains the commit, and an unmerged one, don't count.
		layerChange: `[{"number": 4, "merged_at": "2026-01-01T00:00:00Z", "merge_commit_sha": "` + layerChange + `", "base": {"ref": "main"}},
			{"number": 5, "merged_at": "2026-01-01T00:00:00Z", "merge_commit_sha": "0000", "base": {"ref": "main"}},
			{"number": 6, "merged_at": null, "merge_commit_sha": "` + layerChange + `", "base": {"ref": "main"}}]`,
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sha := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/repos/"+repository+"/commits/"), "/pulls")
		body, ok := pulls[sha]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		fmt.Fprint(w, body)
	}))
	defer server.Close()
	githubAPI = server.URL
	head := gitIn("rev-parse", "HEAD")
	ctx := context.Background()

	// Without a recorded apply, only the last change to the layer or the modules counts.
	if got, err := mergedPRs(ctx, top, head); err != nil || !reflect.DeepEqual(got, []int{4}) {
		t.Fatalf("no apply: %v %v", got, err)
	}
	os.WriteFile(appliedPath(), []byte(applied+"\n"), 0600)
	if got, err := mergedPRs(ctx, top, head); err != nil || !reflect.DeepEqual(got, []int{2, 4}) {
		t.Fatalf("since the apply: %v %v", got, err)
	}
	// An apply recorded from a commit main no longer contains is ignored.
	os.WriteFile(appliedPath(), []byte(strings.Repeat("1", 40)+"\n"), 0600)
	if got, err := mergedPRs(ctx, top, head); err != nil || !reflect.DeepEqual(got, []int{4}) {
		t.Fatalf("unknown apply: %v %v", got, err)
	}
}
