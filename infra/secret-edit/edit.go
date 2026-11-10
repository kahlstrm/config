package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
)

// clusterOnly names the values that have Secret Manager secrets of their own, which only the
// cluster's External Secrets reads. Orbs can read the whole bundle they edit, so these never go
// back into it.
var clusterOnly = []string{"sops_age_key", "klusse_amp_runner_key"}

// edit is one property change of the JSON secret. Its value comes from an environment variable
// named on the command line, so the command shows which properties change but no value.
type edit struct {
	path   []string // dotted property path, such as telegram.bot_token
	remove bool
	env    string
}

func (e edit) String() string { return strings.Join(e.path, ".") }

// parseEdit reads --remove PATH and --from-env PATH=VARIABLE.
func parseEdit(flag, spec string) (edit, error) {
	name, variable, _ := strings.Cut(spec, "=")
	path := strings.Split(name, ".")
	if slices.Contains(path, "") {
		return edit{}, fmt.Errorf("%q: not a dotted property path", name)
	}
	if slices.Contains(clusterOnly, path[0]) {
		return edit{}, fmt.Errorf("%s has a secret of its own that no orb may read; a maintainer changes it", path[0])
	}
	e := edit{path: path}
	switch flag {
	case "remove":
		if variable != "" {
			return edit{}, fmt.Errorf("--remove %s takes no value", spec)
		}
		e.remove = true
	case "from-env":
		if variable == "" {
			return edit{}, fmt.Errorf("--from-env %s: name the variable as PATH=VARIABLE", spec)
		}
		e.env = variable
	}
	return e, nil
}

// applyEdits changes doc in place and returns, per edit, whether it added, changed or removed
// its property. Values are never part of an error or the result.
func applyEdits(doc map[string]any, edits []edit, getenv func(string) string) ([]string, error) {
	var report []string
	for _, e := range edits {
		parent := doc
		for i, name := range e.path[:len(e.path)-1] {
			next, ok := parent[name]
			if !ok && !e.remove {
				next = map[string]any{}
				parent[name] = next
			}
			object, ok := next.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("%s: %s is not an object", e, strings.Join(e.path[:i+1], "."))
			}
			parent = object
		}
		leaf := e.path[len(e.path)-1]
		_, exists := parent[leaf]
		if e.remove {
			if !exists {
				return nil, fmt.Errorf("%s: no such property to remove", e)
			}
			delete(parent, leaf)
			report = append(report, "removed "+e.String())
			continue
		}
		value := getenv(e.env)
		if value == "" {
			return nil, fmt.Errorf("%s: the variable %s is empty or unset", e, e.env)
		}
		parent[leaf] = value
		if exists {
			report = append(report, "changed "+e.String())
		} else {
			report = append(report, "added "+e.String())
		}
	}
	return report, nil
}

// editSecret applies edits to the JSON object in data and returns the new document.
func editSecret(data []byte, edits []edit, getenv func(string) string) ([]byte, []string, error) {
	var doc map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	// Numbers stay as written instead of passing through float64.
	decoder.UseNumber()
	if err := decoder.Decode(&doc); err != nil || doc == nil {
		return nil, nil, errors.New("the latest version is not a JSON object")
	}
	report, err := applyEdits(doc, edits, getenv)
	if err != nil {
		return nil, nil, err
	}
	var out bytes.Buffer
	encoder := json.NewEncoder(&out)
	// Bearer URLs keep their & instead of becoming \u0026.
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	err = encoder.Encode(doc)
	return out.Bytes(), report, err
}
