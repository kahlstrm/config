package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const pvc = `apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  storageClassName: local-storage
`

const namespace = `apiVersion: v1
kind: Namespace
metadata:
  name: app
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
`

const storageClass = `apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
reclaimPolicy: Retain
`

const bucket = `resource "google_storage_bucket" "state" {
  lifecycle {
    prevent_destroy = true
  }
}
`

func run(t *testing.T, args ...string) string {
	t.Helper()
	output, err := exec.Command("git", args...).CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v: %s", args, err, output)
	}
	return string(output)
}

// commit writes files (an empty content deletes one) and commits them.
func commit(t *testing.T, files map[string]string) string {
	t.Helper()
	for path, content := range files {
		if content == "" {
			run(t, "rm", "-q", path)
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		run(t, "add", path)
	}
	run(t, "commit", "-q", "--allow-empty", "-m", "change")
	return run(t, "rev-parse", "HEAD")[:40]
}

const layer = `apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
spec:
  path: ./infra/local-kubernetes/apps
  deletionPolicy: Orphan
  patches:
    - target:
        kind: PersistentVolumeClaim|CustomResourceDefinition
      patch: |
        metadata:
          annotations:
            kustomize.toolkit.fluxcd.io/prune: disabled
`

const kustomization = `apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - pvc.yaml
  - config.yaml
`

// repository starts a repository whose main holds a Flux layer, an app with a
// PVC, a protected namespace and a ConfigMap, a Retain StorageClass and a
// bucket with prevent_destroy.
func repository(t *testing.T) string {
	t.Chdir(t.TempDir())
	run(t, "init", "-q", "-b", "main")
	run(t, "config", "user.email", "test@example.com")
	run(t, "config", "user.name", "test")
	return commit(t, map[string]string{
		"infra/local-kubernetes/clusters/klusse/apps.yaml":   layer,
		"infra/local-kubernetes/apps/app/kustomization.yaml": kustomization,
		"infra/local-kubernetes/apps/app/pvc.yaml":           pvc,
		"infra/local-kubernetes/apps/app/namespace.yaml":     namespace,
		"infra/local-kubernetes/apps/app/config.yaml":        "kind: ConfigMap\nmetadata:\n  name: config\n",
		"infra/local-kubernetes/storage.yaml":                storageClass,
		"infra/gcp-project/main.tf":                          bucket,
		"infra/experiments/lab/namespace.yaml":               namespace,
		"docs/notes.md":                                      "kind: Namespace\n",
	})
}

func branch(t *testing.T, from string, files map[string]string) string {
	t.Helper()
	run(t, "checkout", "-q", "--detach", from)
	return commit(t, files)
}

func check(t *testing.T, base, head string, want []string) {
	t.Helper()
	got, err := findings(base, head)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("findings:\n got  %q\n want %q", got, want)
	}
}

const (
	claim     = "infra/local-kubernetes/apps/app/pvc.yaml"
	removesPV = claim + `: removes "kind: PersistentVolumeClaim", a stateful object`
	renamesPV = claim + `: changes "name: data" in a file that declares a stateful object or protection`
)

func TestDestructiveChangesFail(t *testing.T) {
	base := repository(t)
	cases := []struct {
		name  string
		files map[string]string
		want  []string
	}{
		{"deleting a claim's file", map[string]string{claim: ""}, []string{removesPV, renamesPV}},
		{"renaming a claim", map[string]string{claim: strings.Replace(pvc, "name: data", "name: data2", 1)}, []string{renamesPV}},
		{"dropping a claim from its kustomization", map[string]string{
			"infra/local-kubernetes/apps/app/kustomization.yaml": strings.Replace(kustomization, "  - pvc.yaml\n", "", 1),
		}, []string{"infra/local-kubernetes/apps/app/kustomization.yaml: drops pvc.yaml, which declares a stateful object or protection"}},
		{"narrowing the layer's prune patch", map[string]string{
			"infra/local-kubernetes/clusters/klusse/apps.yaml": strings.Replace(layer, "PersistentVolumeClaim|CustomResourceDefinition", "PersistentVolumeClaim", 1),
		}, []string{`infra/local-kubernetes/clusters/klusse/apps.yaml: removes "kind: PersistentVolumeClaim|CustomResourceDefinition", a stateful object`}},
		{"retargeting the layer", map[string]string{
			"infra/local-kubernetes/clusters/klusse/apps.yaml": strings.Replace(layer, "local-kubernetes/apps", "local-kubernetes/other", 1),
		}, []string{`infra/local-kubernetes/clusters/klusse/apps.yaml: changes "path: ./infra/local-kubernetes/apps" in a file that declares a stateful object or protection`}},
		{"lifting a namespace's prune protection", map[string]string{
			"infra/local-kubernetes/apps/app/namespace.yaml": "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: app\n",
		}, []string{`infra/local-kubernetes/apps/app/namespace.yaml: removes "kustomize.toolkit.fluxcd.io/prune: disabled", Flux prune protection`}},
		{"switching a class to Delete", map[string]string{
			"infra/local-kubernetes/storage.yaml": strings.Replace(storageClass, "Retain", "Delete", 1),
		}, []string{`infra/local-kubernetes/storage.yaml: removes "reclaimPolicy: Retain", reclaim policy Retain`}},
		{"commenting out prevent_destroy", map[string]string{
			"infra/gcp-project/main.tf": strings.Replace(bucket, "prevent_destroy", "# prevent_destroy", 1),
		}, []string{`infra/gcp-project/main.tf: removes "prevent_destroy = true", prevent_destroy`}},
		{"moving a claim to another file", map[string]string{claim: "", "infra/local-kubernetes/apps/app/state.yaml": pvc},
			[]string{removesPV, renamesPV}},
		{"editing the guard", map[string]string{".github/workflows/destroy-guard.yml": "on: {}\n"},
			[]string{".github/workflows/destroy-guard.yml: changes the destructive-change guard"}},
		{"editing the ruleset", map[string]string{".github/rulesets/main.json": "{}\n"},
			[]string{".github/rulesets/main.json: changes the destructive-change guard"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			check(t, "main", branch(t, base, c.files), c.want)
		})
	}
}

func TestSafeChangesPass(t *testing.T) {
	base := repository(t)
	cases := []struct {
		name  string
		files map[string]string
	}{
		{"growing a claim", map[string]string{claim: pvc + "  resources: {requests: {storage: 2Gi}}\n"}},
		{"reordering a file", map[string]string{"infra/local-kubernetes/apps/app/namespace.yaml": "metadata:\n  annotations:\n    kustomize.toolkit.fluxcd.io/prune: disabled\n  name: app\nkind: Namespace\napiVersion: v1\n"}},
		{"adding a claim", map[string]string{"infra/local-kubernetes/apps/new/pvc.yaml": pvc}},
		{"renaming a ConfigMap", map[string]string{"infra/local-kubernetes/apps/app/config.yaml": "kind: ConfigMap\nmetadata:\n  name: settings\n"}},
		{"dropping a ConfigMap from its kustomization", map[string]string{
			"infra/local-kubernetes/apps/app/kustomization.yaml": strings.Replace(kustomization, "  - config.yaml\n", "", 1),
		}},
		{"deleting a lab's namespace", map[string]string{"infra/experiments/lab/namespace.yaml": ""}},
		{"editing docs that name a kind", map[string]string{"docs/notes.md": "nothing\n"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			check(t, "main", branch(t, base, c.files), nil)
		})
	}
}

// A claim merged to main after the pull request branched is missing from the
// pull request, which does not remove it: the guard compares with the merge
// base, not with main's tip.
func TestComparesWithTheMergeBase(t *testing.T) {
	base := repository(t)
	head := branch(t, base, map[string]string{"infra/local-kubernetes/apps/app/config.yaml": "kind: ConfigMap\n"})
	run(t, "checkout", "-q", "main")
	commit(t, map[string]string{"infra/local-kubernetes/apps/later/pvc.yaml": pvc})
	check(t, "main", head, nil)
}
