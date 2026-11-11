package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// gcp calls Secret Manager and Cloud Storage as the service account in a key file.
type gcp struct {
	token         string
	client        *http.Client
	secretManager string
	storage       string
}

func newGCP(ctx context.Context, keyFile string) (*gcp, error) {
	data, err := os.ReadFile(keyFile)
	if err != nil {
		return nil, err
	}
	var key struct {
		ClientEmail string `json:"client_email"`
		PrivateKey  string `json:"private_key"`
		TokenURI    string `json:"token_uri"`
	}
	if err := json.Unmarshal(data, &key); err != nil {
		return nil, fmt.Errorf("%s: %w", keyFile, err)
	}
	block, _ := pem.Decode([]byte(key.PrivateKey))
	if block == nil {
		return nil, fmt.Errorf("%s: no private key", keyFile)
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		if parsed, err = x509.ParsePKCS1PrivateKey(block.Bytes); err != nil {
			return nil, fmt.Errorf("%s: %w", keyFile, err)
		}
	}
	private, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("%s: not an RSA key", keyFile)
	}
	encode := func(v any) string {
		data, _ := json.Marshal(v)
		return base64.RawURLEncoding.EncodeToString(data)
	}
	now := time.Now()
	unsigned := encode(map[string]string{"alg": "RS256", "typ": "JWT"}) + "." + encode(map[string]any{
		"iss": key.ClientEmail, "aud": key.TokenURI, "scope": "https://www.googleapis.com/auth/cloud-platform",
		"iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
	})
	digest := sha256.Sum256([]byte(unsigned))
	signature, err := rsa.SignPKCS1v15(rand.Reader, private, crypto.SHA256, digest[:])
	if err != nil {
		return nil, err
	}
	g := &gcp{client: &http.Client{Timeout: time.Minute}, secretManager: "https://secretmanager.googleapis.com", storage: "https://storage.googleapis.com"}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)}}
	var token struct {
		AccessToken string `json:"access_token"`
	}
	if err := g.do(ctx, http.MethodPost, key.TokenURI, "application/x-www-form-urlencoded", strings.NewReader(form.Encode()), &token); err != nil {
		return nil, fmt.Errorf("GCP token for %s: %w", key.ClientEmail, err)
	}
	g.token = token.AccessToken
	return g, nil
}

var errNotFound = errors.New("not found")

func (g *gcp) do(ctx context.Context, method, uri, contentType string, body io.Reader, out any) error {
	request, err := http.NewRequestWithContext(ctx, method, uri, body)
	if err != nil {
		return err
	}
	if g.token != "" {
		request.Header.Set("Authorization", "Bearer "+g.token)
	}
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	response, err := g.client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 16<<20))
	if err != nil {
		return err
	}
	if response.StatusCode == http.StatusNotFound {
		return errNotFound
	}
	if response.StatusCode >= 300 {
		// Google's error bodies carry a status and message, never the resource's data.
		var failure struct {
			Error struct{ Status, Message string } `json:"error"`
		}
		_ = json.Unmarshal(data, &failure)
		return fmt.Errorf("%s %s: %s: %s %s", method, request.URL.Path, response.Status, failure.Error.Status, failure.Error.Message)
	}
	if out == nil {
		return nil
	}
	if raw, ok := out.(*[]byte); ok {
		*raw = data
		return nil
	}
	return json.Unmarshal(data, out)
}

// accessSecret returns the latest version of a secret and that version's number.
func (g *gcp) accessSecret(ctx context.Context, project, secret string) ([]byte, string, error) {
	var version struct {
		Name    string
		Payload struct{ Data string }
	}
	uri := fmt.Sprintf("%s/v1/projects/%s/secrets/%s/versions/latest:access", g.secretManager, project, secret)
	if err := g.do(ctx, http.MethodGet, uri, "", nil, &version); err != nil {
		return nil, "", err
	}
	data, err := base64.StdEncoding.DecodeString(version.Payload.Data)
	return data, version.Name[strings.LastIndex(version.Name, "/")+1:], err
}

// object returns a Cloud Storage object's content and generation, or errNotFound. The
// generation is read first and pinned, so both describe the same object.
func (g *gcp) object(ctx context.Context, bucket, name string) ([]byte, string, error) {
	var metadata struct{ Generation string }
	uri := fmt.Sprintf("%s/storage/v1/b/%s/o/%s", g.storage, bucket, url.PathEscape(name))
	if err := g.do(ctx, http.MethodGet, uri, "", nil, &metadata); err != nil {
		return nil, "", err
	}
	var data []byte
	err := g.do(ctx, http.MethodGet, uri+"?alt=media&generation="+url.QueryEscape(metadata.Generation), "", nil, &data)
	return data, metadata.Generation, err
}
