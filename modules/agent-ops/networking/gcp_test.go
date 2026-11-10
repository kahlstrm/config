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
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The client signs its token request with the key file, then reads and adds secret versions
// with the token, as Secret Manager's REST API expects.
func TestSecretRoundTrip(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	var added []byte
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
				fmt.Fprint(w, `{"ID": "unused", "Who": "amp@ops"}`)
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
		case "POST /v1/projects/p/secrets/local-networking:addVersion":
			var body struct {
				Payload struct{ Data, DataCrc32c string }
			}
			data, _ := io.ReadAll(r.Body)
			json.Unmarshal(data, &body)
			added, _ = base64.StdEncoding.DecodeString(body.Payload.Data)
			if body.Payload.DataCrc32c != fmt.Sprint(crc32c(added)) {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			fmt.Fprint(w, `{"name": "projects/1/secrets/local-networking/versions/8"}`)
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
	if version, err := g.addSecretVersion(ctx, "p", "local-networking", []byte(`{"a": 2}`)); err != nil || version != "8" || string(added) != `{"a": 2}` {
		t.Fatalf("add: %q %q %v", version, added, err)
	}
	g.storage = server.URL
	lock, generation, err := g.object(ctx, "bucket", "local-networking/default.tflock")
	if err != nil || generation != "1762790000123456" || !strings.Contains(string(lock), "amp@ops") {
		t.Fatalf("lock: %q %q %v", lock, generation, err)
	}
	if _, _, err := g.accessSecret(ctx, "p", "sops_age_key"); err != errNotFound {
		t.Fatalf("missing secret: %v", err)
	}
}
