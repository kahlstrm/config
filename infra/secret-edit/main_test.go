package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

const versions = "/v1/projects/infra-464520/secrets/local-kubernetes/versions"

// fakeGoogle serves STS and Secret Manager for local-kubernetes, whose versions 5, 6 and 7 are
// enabled and 7 holds latest.
type fakeGoogle struct {
	t         *testing.T
	requests  int
	added     []byte
	addedAs   int // the number the new version gets; 8 unless another edit wrote meanwhile
	destroyed []string
}

func (f *fakeGoogle) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.requests++
	if r.URL.Path == "/token" {
		r.ParseForm()
		if r.Form.Get("subject_token") != "AMP-TOKEN" || r.Form.Get("audience") != provider ||
			r.Form.Get("subject_token_type") != "urn:ietf:params:oauth:token-type:id_token" {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprint(w, `{"error": "invalid_grant", "error_description": "rejected"}`)
			return
		}
		fmt.Fprint(w, `{"access_token": "FEDERATED"}`)
		return
	}
	if r.Header.Get("Authorization") != "Bearer FEDERATED" {
		w.WriteHeader(http.StatusForbidden)
		fmt.Fprint(w, `{"error": {"status": "PERMISSION_DENIED", "message": "no"}}`)
		return
	}
	name := func(n int) string {
		return fmt.Sprintf("projects/638826885263/secrets/local-kubernetes/versions/%d", n)
	}
	switch {
	case r.Method == http.MethodGet && r.URL.Path == versions+"/latest:access":
		doc := `{"cloudflare_api_token": "OLD-TOKEN", "telegram": {"chat_id": 123}, "stale": "GONE", "amp_alert_webhook_url": "https://x/?a=1&b=2"}`
		fmt.Fprintf(w, `{"name": %q, "payload": {"data": %q}}`, name(7), base64.StdEncoding.EncodeToString([]byte(doc)))
	case r.Method == http.MethodPost && r.URL.Path == "/v1/projects/infra-464520/secrets/local-kubernetes:addVersion":
		var body struct {
			Payload struct{ Data, DataCrc32c string }
		}
		json.NewDecoder(r.Body).Decode(&body)
		f.added, _ = base64.StdEncoding.DecodeString(body.Payload.Data)
		if body.Payload.DataCrc32c != fmt.Sprint(crc32.Checksum(f.added, crc32.MakeTable(crc32.Castagnoli))) {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		fmt.Fprintf(w, `{"name": %q}`, name(f.addedAs))
	case r.Method == http.MethodGet && r.URL.Path == versions:
		if r.URL.Query().Get("filter") != "state:ENABLED" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		// Newest first, as Secret Manager lists them, and over two pages.
		if r.URL.Query().Get("pageToken") == "" {
			fmt.Fprintf(w, `{"versions": [{"name": %q}, {"name": %q}], "nextPageToken": "P2"}`, name(8), name(7))
		} else {
			fmt.Fprintf(w, `{"versions": [{"name": %q}, {"name": %q}]}`, name(6), name(5))
		}
	case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/v1/projects/638826885263/secrets/local-kubernetes/versions/") &&
		strings.HasSuffix(r.URL.Path, ":destroy"):
		f.destroyed = append(f.destroyed, strings.TrimSuffix(r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:], ":destroy"))
		fmt.Fprint(w, `{}`)
	default:
		f.t.Errorf("unexpected %s %s", r.Method, r.URL)
		w.WriteHeader(http.StatusNotFound)
	}
}

func serve(t *testing.T) *fakeGoogle {
	f := &fakeGoogle{t: t, addedAs: 8}
	server := httptest.NewServer(f)
	t.Cleanup(server.Close)
	oldSTS, oldSM, oldToken := stsURL, secretManager, idToken
	stsURL, secretManager = server.URL+"/token", server.URL
	idToken = func(context.Context) (string, error) { return "AMP-TOKEN", nil }
	t.Cleanup(func() { stsURL, secretManager, idToken = oldSTS, oldSM, oldToken })
	return f
}

// An edit writes a version where only the named properties differ, keeps the version it read
// for undo, destroys the older ones and prints no value.
func TestEdit(t *testing.T) {
	f := serve(t)
	env := map[string]string{"CLOUDFLARE": "NEW-TOKEN", "BOT": "BOT-TOKEN"}
	var out bytes.Buffer
	err := run(context.Background(), []string{
		"--from-env", "cloudflare_api_token=CLOUDFLARE",
		"--from-env", "telegram.bot_token=BOT",
		"--remove", "stale",
	}, func(name string) string { return env[name] }, &out)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	decoder := json.NewDecoder(bytes.NewReader(f.added))
	decoder.UseNumber()
	if err := decoder.Decode(&doc); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"cloudflare_api_token":  "NEW-TOKEN",
		"telegram":              map[string]any{"chat_id": json.Number("123"), "bot_token": "BOT-TOKEN"},
		"amp_alert_webhook_url": "https://x/?a=1&b=2",
	}
	if fmt.Sprint(doc) != fmt.Sprint(want) {
		t.Fatalf("written %v", doc)
	}
	if !strings.Contains(string(f.added), `"https://x/?a=1&b=2"`) {
		t.Fatalf("the URL changed form:\n%s", f.added)
	}
	if !slices.Equal(f.destroyed, []string{"6", "5"}) {
		t.Fatalf("destroyed %v, want 6 and 5", f.destroyed)
	}
	printed := out.String()
	for _, value := range []string{"NEW-TOKEN", "BOT-TOKEN", "OLD-TOKEN", "GONE"} {
		if strings.Contains(printed, value) {
			t.Fatalf("output shows a value:\n%s", printed)
		}
	}
	if !strings.Contains(printed, "version 7 → 8: changed cloudflare_api_token, added telegram.bot_token, removed stale") ||
		!strings.Contains(printed, "Destroyed versions 5 6;") {
		t.Fatalf("output:\n%s", printed)
	}
}

// The values with secrets of their own are refused before anything is read or written, at
// any depth of the path and with either flag.
func TestRefusesClusterOnlyValues(t *testing.T) {
	f := serve(t)
	for _, args := range [][]string{
		{"--from-env", "sops_age_key=KEY"},
		{"--remove", "klusse_amp_runner_key"},
		{"--from-env", "a=A", "--from-env", "klusse_amp_runner_key.x=KEY"},
	} {
		err := run(context.Background(), args, func(string) string { return "VALUE" }, io.Discard)
		if err == nil || !strings.Contains(err.Error(), "secret of its own") {
			t.Fatalf("%v: %v", args, err)
		}
	}
	if f.requests != 0 {
		t.Fatalf("%d requests made", f.requests)
	}
}

// A failed edit writes nothing and its error names the property, never a value.
func TestFailedEditWritesNothing(t *testing.T) {
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"--from-env", "cloudflare_api_token=UNSET"}, "UNSET is empty or unset"},
		{[]string{"--remove", "missing"}, "no such property"},
		{[]string{"--from-env", "cloudflare_api_token.x=SET"}, "cloudflare_api_token is not an object"},
	} {
		f := serve(t)
		err := run(context.Background(), c.args, func(name string) string { return map[string]string{"SET": "S"}[name] }, io.Discard)
		if err == nil || !strings.Contains(err.Error(), c.want) || strings.Contains(err.Error(), "OLD-TOKEN") {
			t.Fatalf("%v: %v", c.args, err)
		}
		if f.added != nil || f.destroyed != nil {
			t.Fatalf("%v: wrote or destroyed", c.args)
		}
	}
}

// When another edit added a version between this one's read and write, this edit may have undone
// it, so it reports that and destroys nothing.
func TestConcurrentEditDestroysNothing(t *testing.T) {
	f := serve(t)
	f.addedAs = 9
	err := run(context.Background(), []string{"--remove", "stale"}, func(string) string { return "" }, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "another version was added after version 7") {
		t.Fatal(err)
	}
	if f.destroyed != nil {
		t.Fatalf("destroyed %v", f.destroyed)
	}
}
