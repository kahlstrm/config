package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"slices"
	"strings"
)

func crc32c(data []byte) uint32 { return crc32.Checksum(data, crc32.MakeTable(crc32.Castagnoli)) }

// edit is one property change of a JSON secret. Its value comes from a source named on the
// command line, so the approval prompt shows which properties change but no value.
type edit struct {
	path   []string // dotted property path, such as home_assistant.token
	remove bool
	kind   string // generate: token or password
	env    string // from an environment variable, such as one from Amp's Secrets & Env Vars
}

func (e edit) String() string { return strings.Join(e.path, ".") }

func parsePath(spec string) ([]string, error) {
	path := strings.Split(spec, ".")
	if slices.Contains(path, "") {
		return nil, fmt.Errorf("%q: not a dotted property path", spec)
	}
	return path, nil
}

// parseEdit reads --remove PATH, --generate PATH=token|password and --from-env PATH=VARIABLE.
func parseEdit(flag, spec string) (edit, error) {
	name, source, _ := strings.Cut(spec, "=")
	path, err := parsePath(name)
	if err != nil {
		return edit{}, err
	}
	e := edit{path: path}
	switch flag {
	case "remove":
		if source != "" {
			return edit{}, fmt.Errorf("--remove %s takes no value", spec)
		}
		e.remove = true
	case "generate":
		if source != "token" && source != "password" {
			return edit{}, fmt.Errorf("--generate %s: choose PATH=token or PATH=password", spec)
		}
		e.kind = source
	case "from-env":
		if source == "" {
			return edit{}, fmt.Errorf("--from-env %s: name the variable as PATH=VARIABLE", spec)
		}
		e.env = source
	}
	return e, nil
}

// generate returns a random token (64 hex digits) or password (32 letters and digits).
func generate(kind string) (string, error) {
	data := make([]byte, 32)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	if kind == "token" {
		return hex.EncodeToString(data), nil
	}
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	for i, b := range data {
		// 248 = 4 × 62: rejecting larger bytes keeps every character equally likely.
		for b >= 248 {
			var one [1]byte
			if _, err := rand.Read(one[:]); err != nil {
				return "", err
			}
			b = one[0]
		}
		data[i] = alphabet[int(b)%len(alphabet)]
	}
	return string(data), nil
}

// applyEdits changes doc in place and returns, per edit, whether it added, changed or
// removed its property. Values are never part of an error or the result.
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
		switch {
		case e.remove:
			if !exists {
				return nil, fmt.Errorf("%s: no such property to remove", e)
			}
			delete(parent, leaf)
			report = append(report, "removed "+e.String())
			continue
		case e.kind != "":
			value, err := generate(e.kind)
			if err != nil {
				return nil, err
			}
			parent[leaf] = value
		default:
			value := getenv(e.env)
			if value == "" {
				return nil, fmt.Errorf("%s: the variable %s is empty or unset", e, e.env)
			}
			parent[leaf] = value
		}
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
