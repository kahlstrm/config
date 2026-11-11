// destroy-guard fails a pull request that deletes a stateful object, lifts a
// protection against deletion, or changes the guard itself, unless the pull
// request declares it with the allow-destroy label.
//
// It compares the pull request's head with its merge base on the base branch
// through git alone, so it never runs code from the pull request. In each
// deployed infrastructure file it looks at the lines the pull request removes,
// that is, lines of the merge base that the head no longer has as often. A
// removed line is a finding when it holds a protection or declares a stateful
// object; when it is a top-level name, namespace or path in a file that declares
// one, since that renames or retargets it; and when it is a kustomization.yaml
// entry whose file or directory declares one, since that drops it from what Flux
// applies. Moving a line within a file is not a finding; moving it to another
// file is.
//
//	destroy-guard <base revision> <head revision>
//
// ALLOW_DESTROY=true reports the findings without failing.
package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	pathpkg "path"
	"regexp"
	"strings"
)

// What a removed line protects or declares. Comment lines never count.
var patterns = []struct {
	what string
	re   *regexp.Regexp
}{
	{"Flux prune protection", regexp.MustCompile(`kustomize\.toolkit\.fluxcd\.io/prune["']?:\s*["']?disabled`)},
	{"deletionPolicy: Orphan", regexp.MustCompile(`deletionPolicy["']?:\s*["']?Orphan`)},
	{"reclaim policy Retain", regexp.MustCompile(`[rR]eclaimPolicy["']?:\s*["']?Retain`)},
	{"prevent_destroy", regexp.MustCompile(`prevent_destroy\s*=\s*true`)},
	{"delete or rebuild protection", regexp.MustCompile(`(delete|rebuild)_protection\s*=\s*true`)},
	{"a stateful object", regexp.MustCompile(`kind["']?:\s*["']?(PersistentVolumeClaim|PersistentVolume|Namespace|CustomResourceDefinition|StorageClass)\b`)},
	{"a volume claim template", regexp.MustCompile(`volumeClaimTemplates?["']?:`)},
}

// Any change to these needs the label: the guard, its workflow and the ruleset
// that requires it.
var guardPaths = []string{
	".github/workflows/destroy-guard.yml",
	".github/rulesets/",
	"infra/destroy-guard/",
}

var (
	// metadata.name, metadata.namespace and a Flux Kustomization's spec.path.
	identity = regexp.MustCompile(`^  (name|namespace|path):`)
	// A plain list entry of a kustomization.yaml, such as a resource.
	entry = regexp.MustCompile(`^\s*-\s+([^\s#:]+|\S+://\S+)$`)
)

func infrastructure(path string) bool {
	for _, extension := range []string{".yaml", ".yml", ".tf", ".py"} {
		if strings.HasSuffix(path, extension) {
			return true
		}
	}
	return false
}

// scanned reports whether a file is deployed infrastructure: manifests,
// Terraform and the scripts that set protections, outside labs and tests.
func scanned(path string) bool {
	return strings.HasPrefix(path, "infra/") && !strings.HasPrefix(path, "infra/experiments/") &&
		!strings.HasPrefix(path, "infra/destroy-guard/") && !strings.Contains(path, "/tests/") &&
		infrastructure(path)
}

func git(args ...string) ([]byte, error) {
	var stderr bytes.Buffer
	command := exec.Command("git", args...)
	command.Stderr = &stderr
	output, err := command.Output()
	if err != nil {
		return nil, fmt.Errorf("git %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return output, nil
}

// files lists the files a revision has at a path, or under it if it is a
// directory.
func files(revision, path string) ([]string, error) {
	output, err := git("ls-tree", "-r", "-z", "--full-tree", "--name-only", revision, "--", path)
	if err != nil {
		return nil, err
	}
	var result []string
	for _, name := range strings.Split(string(output), "\x00") {
		if name == path || strings.HasPrefix(name, path+"/") {
			result = append(result, name)
		}
	}
	return result, nil
}

// lines returns a file's lines without comments and blank lines, or none if
// the revision lacks the file. Any other git failure stops the guard.
func lines(revision, path string) ([]string, error) {
	present, err := files(revision, path)
	if err != nil || len(present) == 0 {
		return nil, err
	}
	content, err := git("show", revision+":"+path)
	if err != nil {
		return nil, err
	}
	var result []string
	for _, line := range strings.Split(string(content), "\n") {
		line = strings.TrimRight(line, " \t\r")
		if trimmed := strings.TrimSpace(line); trimmed != "" && !strings.HasPrefix(trimmed, "#") {
			result = append(result, line)
		}
	}
	return result, nil
}

// protects names what a line protects or declares, or returns "".
func protects(line string) string {
	for _, pattern := range patterns {
		if pattern.re.MatchString(line) {
			return pattern.what
		}
	}
	return ""
}

func declares(lines []string) bool {
	for _, line := range lines {
		if protects(line) != "" {
			return true
		}
	}
	return false
}

// declaresUnder reports whether a file, or any file under a directory,
// declares a stateful object or protection at a revision.
func declaresUnder(revision, path string) (bool, error) {
	names, err := files(revision, path)
	if err != nil {
		return false, err
	}
	for _, name := range names {
		if !infrastructure(name) {
			continue
		}
		content, err := lines(revision, name)
		if err != nil {
			return false, err
		}
		if declares(content) {
			return true, nil
		}
	}
	return false, nil
}

// removed lists what one file's change from base to head destroys or lifts.
func removed(base, head, path string) ([]string, error) {
	before, err := lines(base, path)
	if err != nil {
		return nil, err
	}
	after, err := lines(head, path)
	if err != nil {
		return nil, err
	}
	remaining := map[string]int{}
	for _, line := range after {
		remaining[line]++
	}
	stateful := declares(before)
	kustomization := pathpkg.Base(path) == "kustomization.yaml" || pathpkg.Base(path) == "kustomization.yml"
	var result []string
	for _, line := range before {
		if remaining[line] > 0 {
			remaining[line]--
			continue
		}
		trimmed := strings.TrimSpace(line)
		if what := protects(line); what != "" {
			result = append(result, fmt.Sprintf("%s: removes %q, %s", path, trimmed, what))
		} else if stateful && identity.MatchString(line) {
			result = append(result, fmt.Sprintf("%s: changes %q in a file that declares a stateful object or protection", path, trimmed))
		} else if match := entry.FindStringSubmatch(line); kustomization && match != nil {
			target := match[1]
			drops := strings.Contains(target, "://")
			if !drops {
				if drops, err = declaresUnder(base, pathpkg.Join(pathpkg.Dir(path), target)); err != nil {
					return nil, err
				}
			}
			if drops {
				result = append(result, fmt.Sprintf("%s: drops %s, which declares a stateful object or protection", path, target))
			}
		}
	}
	return result, nil
}

// findings lists what the pull request from base to head destroys or lifts.
func findings(base, head string) ([]string, error) {
	mergeBase, err := git("merge-base", base, head)
	if err != nil {
		return nil, err
	}
	from := strings.TrimSpace(string(mergeBase))
	changed, err := git("diff", "-z", "--no-renames", "--name-only", from, head)
	if err != nil {
		return nil, err
	}
	var result []string
	for _, path := range strings.Split(strings.TrimSuffix(string(changed), "\x00"), "\x00") {
		if path == "" {
			continue
		}
		for _, guard := range guardPaths {
			if path == guard || strings.HasSuffix(guard, "/") && strings.HasPrefix(path, guard) {
				result = append(result, fmt.Sprintf("%s: changes the destructive-change guard", path))
			}
		}
		if !scanned(path) {
			continue
		}
		found, err := removed(from, head, path)
		if err != nil {
			return nil, err
		}
		result = append(result, found...)
	}
	return result, nil
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: destroy-guard <base revision> <head revision>")
		os.Exit(2)
	}
	found, err := findings(os.Args[1], os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if len(found) == 0 {
		fmt.Println("No stateful object or protection is removed.")
		return
	}
	for _, finding := range found {
		fmt.Println(finding)
	}
	if os.Getenv("ALLOW_DESTROY") == "true" {
		fmt.Println("The pull request declares this with allow-destroy.")
		return
	}
	fmt.Println(`If this is intended, add the label allow-destroy and name in the description what is destroyed.`)
	os.Exit(1)
}
