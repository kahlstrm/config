package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The client signs its token request with the key file, then reads secret versions and state
// objects with the token, as Secret Manager's and Cloud Storage's REST APIs expect.
func TestSecretRoundTrip(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/token" {
			r.ParseForm()
			parts := strings.Split(r.Form.Get("assertion"), ".")
			claims, _ := base64.RawURLEncoding.DecodeString(parts[1])
			var c map[string]any
			json.Unmarshal(claims, &c)
			if len(parts) != 3 || c["iss"] != "ops@p.iam.gserviceaccount.com" || c["aud"] != server.URL+"/token" {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			fmt.Fprint(w, `{"access_token": "T"}`)
			return
		}
		if r.Header.Get("Authorization") != "Bearer T" {
			w.WriteHeader(http.StatusUnauthorized)
			fmt.Fprint(w, `{"error": {"status": "UNAUTHENTICATED", "message": "no"}}`)
			return
		}
		if r.URL.Path == "/storage/v1/b/bucket/o/local-networking/default.tflock" {
			// The lock JSON's ID is not the unlock ID; the object's generation is.
			if r.URL.Query().Get("alt") == "media" && r.URL.Query().Get("generation") == "1762790000123456" {
				fmt.Fprint(w, `{"ID": "unused", "Who": "infra-local-networking@pannu"}`)
			} else if r.URL.RawQuery == "" {
				fmt.Fprint(w, `{"name": "local-networking/default.tflock", "generation": "1762790000123456"}`)
			} else {
				w.WriteHeader(http.StatusBadRequest)
			}
			return
		}
		switch r.Method + " " + r.URL.Path {
		case "GET /v1/projects/p/secrets/local-networking/versions/latest:access":
			fmt.Fprintf(w, `{"name": "projects/1/secrets/local-networking/versions/7", "payload": {"data": %q}}`, base64.StdEncoding.EncodeToString([]byte(`{"a": 1}`)))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	file := filepath.Join(t.TempDir(), "gcp.json")
	keyJSON, _ := json.Marshal(map[string]string{"client_email": "ops@p.iam.gserviceaccount.com", "token_uri": server.URL + "/token",
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))})
	os.WriteFile(file, keyJSON, 0600)

	ctx := context.Background()
	g, err := newGCP(ctx, file)
	if err != nil {
		t.Fatal(err)
	}
	g.secretManager = server.URL
	data, version, err := g.accessSecret(ctx, "p", "local-networking")
	if err != nil || string(data) != `{"a": 1}` || version != "7" {
		t.Fatalf("access: %q %q %v", data, version, err)
	}
	g.storage = server.URL
	lock, generation, err := g.object(ctx, "bucket", "local-networking/default.tflock")
	if err != nil || generation != "1762790000123456" || !strings.Contains(string(lock), "infra-local-networking@pannu") {
		t.Fatalf("lock: %q %q %v", lock, generation, err)
	}
	if _, _, err := g.accessSecret(ctx, "p", "sops_age_key"); err != errNotFound {
		t.Fatalf("missing secret: %v", err)
	}
}

// credentials creates the key once and keeps it, and the key file it writes signs the token
// request that newGCP makes.
func TestCredentials(t *testing.T) {
	state := t.TempDir()
	stateDirectory = t.TempDir()
	if err := credentials(state, "", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(keyFile()); !os.IsNotExist(err) {
		t.Fatalf("key file without an account: %v", err)
	}
	key, _ := os.ReadFile(filepath.Join(state, "gcp.key"))
	certificate, _ := os.ReadFile(filepath.Join(state, "gcp.crt"))
	if err := credentials(state, "a@p.iam.gserviceaccount.com", "abc"); err != nil {
		t.Fatal(err)
	}
	if again, _ := os.ReadFile(filepath.Join(state, "gcp.key")); string(again) != string(key) {
		t.Fatal("the key changed on the second run")
	}
	block, _ := pem.Decode(certificate)
	parsed, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Stat(filepath.Join(state, "gcp.key")); info.Mode().Perm() != 0400 {
		t.Fatalf("key mode %v", info.Mode())
	}
	var file struct {
		ClientEmail  string `json:"client_email"`
		PrivateKeyID string `json:"private_key_id"`
	}
	data, _ := os.ReadFile(keyFile())
	if err := json.Unmarshal(data, &file); err != nil || file.ClientEmail != "a@p.iam.gserviceaccount.com" || file.PrivateKeyID != "abc" {
		t.Fatalf("key file: %s %v", data, err)
	}
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		parts := strings.Split(r.Form.Get("assertion"), ".")
		signature, _ := base64.RawURLEncoding.DecodeString(parts[2])
		if err := parsed.CheckSignature(x509.SHA256WithRSA, []byte(parts[0]+"."+parts[1]), signature); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		fmt.Fprint(w, `{"access_token": "T"}`)
	}))
	defer server.Close()
	// The token URI is Google's in the file; point it at the test server.
	var raw map[string]string
	json.Unmarshal(data, &raw)
	raw["token_uri"] = server.URL
	data, _ = json.Marshal(raw)
	if err := place(keyFile(), data, 0400); err != nil {
		t.Fatal(err)
	}
	if _, err := newGCP(context.Background(), keyFile()); err != nil {
		t.Fatalf("the certificate does not verify the key file's signature: %v", err)
	}
}
