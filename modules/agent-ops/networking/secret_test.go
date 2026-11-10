package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestEditSecret(t *testing.T) {
	data := []byte(`{"kuberack_rb5009": {"username": "admin", "password": "OLD"}, "port": 8443, "webhook": "https://x/?a=1&b=2", "stale": "GONE"}`)
	edits := []edit{}
	for _, spec := range [][2]string{
		{"remove", "stale"},
		{"generate", "kuberack_rb5009.password=password"},
		{"generate", "home_assistant.token=token"},
		{"from-env", "cloudflare.api_token=CF_TOKEN"},
	} {
		e, err := parseEdit(spec[0], spec[1])
		if err != nil {
			t.Fatal(err)
		}
		edits = append(edits, e)
	}
	out, report, err := editSecret(data, edits, func(name string) string { return map[string]string{"CF_TOKEN": "FROM-AMP"}[name] })
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"removed stale", "changed kuberack_rb5009.password", "added home_assistant.token", "added cloudflare.api_token"}; !reflect.DeepEqual(report, want) {
		t.Fatalf("report %v", report)
	}
	if strings.Contains(strings.Join(report, " "), "FROM-AMP") {
		t.Fatal("report shows a value")
	}
	// Numbers and URLs keep their form.
	if !strings.Contains(string(out), `"port": 8443`) || !strings.Contains(string(out), `"https://x/?a=1&b=2"`) {
		t.Fatalf("output:\n%s", out)
	}
	var doc struct {
		Kuberack struct{ Username, Password string } `json:"kuberack_rb5009"`
		Home     struct{ Token string }              `json:"home_assistant"`
		Cloud    struct {
			Token string `json:"api_token"`
		} `json:"cloudflare"`
		Stale *string `json:"stale"`
	}
	if err := json.Unmarshal(out, &doc); err != nil {
		t.Fatal(err)
	}
	if doc.Kuberack.Username != "admin" || len(doc.Kuberack.Password) != 32 || doc.Kuberack.Password == "OLD" ||
		strings.Trim(doc.Kuberack.Password, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") != "" {
		t.Fatalf("password %q", doc.Kuberack.Password)
	}
	if len(doc.Home.Token) != 64 || strings.Trim(doc.Home.Token, "0123456789abcdef") != "" {
		t.Fatalf("token %q", doc.Home.Token)
	}
	if doc.Cloud.Token != "FROM-AMP" || doc.Stale != nil {
		t.Fatalf("doc %+v", doc)
	}
}

func TestEditSecretErrorsNameNoValues(t *testing.T) {
	data := []byte(`{"a": "VALUE-A", "b": {"c": "VALUE-C"}}`)
	for _, c := range []struct {
		flag, spec, want string
	}{
		{"remove", "missing", "no such property"},
		{"generate", "a.x=token", "a is not an object"},
		{"from-env", "b.c=UNSET", "UNSET is empty or unset"},
	} {
		e, err := parseEdit(c.flag, c.spec)
		if err != nil {
			t.Fatal(err)
		}
		_, _, err = editSecret(data, []edit{e}, func(string) string { return "" })
		if err == nil || !strings.Contains(err.Error(), c.want) || strings.Contains(err.Error(), "VALUE") {
			t.Fatalf("%s %s: %v", c.flag, c.spec, err)
		}
	}
	for _, c := range [][2]string{{"remove", "a=1"}, {"generate", "a=pin"}, {"from-env", "a"}, {"remove", "a..b"}} {
		if _, err := parseEdit(c[0], c[1]); err == nil {
			t.Fatalf("parseEdit(%q, %q) accepted", c[0], c[1])
		}
	}
}
