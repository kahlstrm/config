package main

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func testConfig() configuration {
	return configuration{Owner: "kahlstrm", App: app{ID: "3", InstallationID: "4"}}
}

func TestRepositoryScope(t *testing.T) {
	body, err := testConfig().repositoryScope("kahlstrm/config")
	if err != nil || !reflect.DeepEqual(body.Repositories, []string{"config"}) || body.Permissions != nil {
		t.Fatalf("scope = %+v, %v", body, err)
	}
	if data, err := json.Marshal(body); err != nil || strings.Contains(string(data), "permissions") {
		t.Fatalf("scoped request = %s, %v", data, err)
	}
	for _, repo := range []string{"someone/config", "kahlstrm/config/extra", "config", "kahlstrm/..", "kahlstrm/.", "kahlstrm/", "kahlstrm/a b", ""} {
		if _, err := testConfig().repositoryScope(repo); err == nil {
			t.Errorf("accepted invalid repository %q", repo)
		}
	}
}

func TestGitRepository(t *testing.T) {
	repo, err := gitRepository(map[string]string{"protocol": "https", "host": "github.com", "path": "kahlstrm/config.git"})
	if err != nil || repo != "kahlstrm/config" {
		t.Fatalf("repository = %q, %v", repo, err)
	}
	for _, fields := range []map[string]string{
		{"protocol": "http", "host": "github.com", "path": "kahlstrm/config"},
		{"protocol": "https", "host": "evil.example", "path": "kahlstrm/config"},
		{"protocol": "https", "host": "github.com"},
	} {
		if _, err := gitRepository(fields); err == nil {
			t.Errorf("accepted unsupported Git request %v", fields)
		}
	}
}

func testKey(t *testing.T, pkcs8 bool) (*rsa.PrivateKey, string) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	block := &pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}
	if pkcs8 {
		block.Type = "PRIVATE KEY"
		block.Bytes, err = x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(t.TempDir(), "app.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(block), 0600); err != nil {
		t.Fatal(err)
	}
	return key, path
}

func verifyJWT(t *testing.T, token string, key *rsa.PrivateKey, issuer string, now int64) {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Errorf("invalid JWT")
		return
	}
	decode := func(part string, value any) {
		t.Helper()
		data, err := base64.RawURLEncoding.DecodeString(part)
		if err != nil {
			t.Error(err)
			return
		}
		if err := json.Unmarshal(data, value); err != nil {
			t.Error(err)
		}
	}
	var header map[string]string
	decode(parts[0], &header)
	if header["alg"] != "RS256" || header["typ"] != "JWT" {
		t.Errorf("JWT header %v", header)
	}
	var claims struct {
		Issuer    string `json:"iss"`
		IssuedAt  int64  `json:"iat"`
		ExpiresAt int64  `json:"exp"`
	}
	decode(parts[1], &claims)
	if claims.Issuer != issuer || claims.IssuedAt != now-60 || claims.ExpiresAt != now+540 {
		t.Errorf("JWT claims %+v", claims)
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Error(err)
		return
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(&key.PublicKey, crypto.SHA256, digest[:], signature); err != nil {
		t.Error(err)
	}
}

func TestAppJWT(t *testing.T) {
	for _, pkcs8 := range []bool{false, true} {
		t.Run(fmt.Sprint(pkcs8), func(t *testing.T) {
			key, path := testKey(t, pkcs8)
			token, err := appJWT(app{ID: "123", KeyFile: path}, time.Unix(1000, 0))
			if err != nil {
				t.Fatal(err)
			}
			verifyJWT(t, token, key, "123", 1000)
		})
	}
	path := filepath.Join(t.TempDir(), "invalid.pem")
	if err := os.WriteFile(path, []byte("not a key"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := appJWT(app{ID: "1", KeyFile: path}, time.Now()); err == nil {
		t.Fatal("accepted invalid PEM")
	}
}

func testHelper(t *testing.T) *helper {
	t.Helper()
	_, path := testKey(t, false)
	cfg := testConfig()
	cfg.App.KeyFile = path
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/app/installations/4/access_tokens":
			io.WriteString(w, `{"token":"app-token"}`)
		case "/installation/repositories":
			io.WriteString(w, `{"repositories":[]}`)
		case "/app":
			io.WriteString(w, `{"slug":"agent-pr"}`)
		case "/kahlstrm/config.git/info/refs":
		default:
			t.Errorf("unexpected endpoint %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(server.Close)
	return &helper{config: cfg, client: server.Client(), apiURL: server.URL, gitURL: server.URL, wait: func(time.Duration) {}, input: strings.NewReader(""), output: &bytes.Buffer{}, env: map[string]string{}, run: func(string, []string, map[string]string) (int, error) {
		t.Error("unexpected child command")
		return 1, nil
	}}
}

func TestInstallationTokenRequest(t *testing.T) {
	h := testHelper(t)
	key, path := testKey(t, false)
	h.config.App.KeyFile = path
	var bodies []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/app/installations/4/access_tokens" {
			t.Errorf("request = %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("X-GitHub-Api-Version") != "2022-11-28" || r.Header.Get("Content-Type") != "application/json" {
			t.Error("missing API headers")
		}
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		parts := strings.Split(token, ".")
		if len(parts) != 3 {
			t.Error("missing App JWT")
			w.WriteHeader(401)
			return
		}
		payload, _ := base64.RawURLEncoding.DecodeString(parts[1])
		var claims struct {
			IssuedAt int64 `json:"iat"`
		}
		if err := json.Unmarshal(payload, &claims); err != nil {
			t.Error(err)
			w.WriteHeader(401)
			return
		}
		verifyJWT(t, token, key, "3", claims.IssuedAt+60)
		data, _ := io.ReadAll(r.Body)
		bodies = append(bodies, string(data))
		io.WriteString(w, `{"token":"minted"}`)
	}))
	defer server.Close()
	h.apiURL = server.URL
	scope, err := h.config.repositoryScope("kahlstrm/config")
	if err != nil {
		t.Fatal(err)
	}
	for _, body := range []tokenRequest{scope, {}} {
		if token, err := h.installationToken(body); err != nil || token != "minted" {
			t.Fatalf("token = %q, %v", token, err)
		}
	}
	if !reflect.DeepEqual(bodies, []string{`{"repositories":["config"]}`, `{}`}) {
		t.Fatalf("token requests = %q", bodies)
	}
}

func TestGhEnvironmentAndExitCode(t *testing.T) {
	h := testHelper(t)
	h.env = map[string]string{"GH_TOKEN": "personal", "GITHUB_TOKEN": "personal", "PATH": "test-path"}
	h.run = func(binary string, args []string, env map[string]string) (int, error) {
		if binary != "/store/gh" || !reflect.DeepEqual(args, []string{"pr", "list"}) {
			t.Errorf("command = %s %v", binary, args)
		}
		if env["GH_TOKEN"] != "app-token" || env["GH_HOST"] != "github.com" || env["PATH"] != "test-path" {
			t.Errorf("environment = %v", env)
		}
		if _, exists := env["GITHUB_TOKEN"]; exists {
			t.Error("inherited personal token")
		}
		return 7, nil
	}
	if code, err := h.runGH("/store/gh", []string{"pr", "list"}); err != nil || code != 7 {
		t.Fatalf("exit = %d, %v", code, err)
	}
	if h.env["GH_TOKEN"] != "personal" || h.env["GITHUB_TOKEN"] != "personal" {
		t.Fatal("mutated parent credentials")
	}
}

func TestGhAuthAndViewer(t *testing.T) {
	h := testHelper(t)
	if code, err := h.runGH("/store/gh", []string{"auth", "status", "--json", "hosts"}); err != nil || code != 0 {
		t.Fatalf("auth status = %d, %v", code, err)
	}
	var status struct {
		Hosts map[string][]struct {
			Login, State string
			Active       bool
		}
	}
	if err := json.Unmarshal(h.output.(*bytes.Buffer).Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	accounts := status.Hosts["github.com"]
	if len(accounts) != 1 || accounts[0].Login != "agent-pr[bot]" || accounts[0].State != "success" || !accounts[0].Active {
		t.Fatalf("status = %+v", status)
	}
	h.run = func(binary string, args []string, env map[string]string) (int, error) {
		if !reflect.DeepEqual(args, []string{"api", "users/agent-pr[bot]", "--jq", ".login"}) {
			t.Errorf("viewer command = %v", args)
		}
		return 0, nil
	}
	if _, err := h.runGH("/store/gh", []string{"api", "user", "--jq", ".login"}); err != nil {
		t.Fatal(err)
	}
}

func TestGhRejectionsAndUnauthenticatedHelp(t *testing.T) {
	h := testHelper(t)
	for _, args := range [][]string{{"auth", "login"}, {"auth", "refresh"}, {"api", "user", "--hostname", "evil.example"}} {
		if _, err := h.runGH("/store/gh", args); err == nil {
			t.Errorf("accepted %v", args)
		}
	}
	h.config.App = app{}
	h.run = func(string, []string, map[string]string) (int, error) { return 0, nil }
	if code, err := h.runGH("/store/gh", []string{"--version"}); err != nil || code != 0 {
		t.Fatalf("version = %d, %v", code, err)
	}
}

func TestRevokedInstallationAndMalformedResponses(t *testing.T) {
	for _, tt := range []struct {
		status int
		body   string
	}{{401, `{"message":"secret"}`}, {200, "invalid JSON"}, {200, `{"token":""}`}} {
		t.Run(fmt.Sprint(tt), func(t *testing.T) {
			h := testHelper(t)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/app/installations/4/access_tokens" && tt.status == 401 {
					io.WriteString(w, `{"token":"app-token"}`)
					return
				}
				w.WriteHeader(tt.status)
				io.WriteString(w, tt.body)
			}))
			defer server.Close()
			h.apiURL = server.URL
			if _, err := h.runGH("/store/gh", []string{"auth", "status", "--json", "hosts"}); err == nil {
				t.Fatal("reported authentication despite failed API response")
			}
			if h.output.(*bytes.Buffer).Len() != 0 {
				t.Fatal("reported successful authentication")
			}
		})
	}
}

func TestGitProtocol(t *testing.T) {
	h := testHelper(t)
	h.input = strings.NewReader("protocol=https\nhost=github.com\npath=kahlstrm/config.git\n\n")
	if code, err := h.execute([]string{"git", "get"}); err != nil || code != 0 {
		t.Fatalf("Git get = %d, %v", code, err)
	}
	if got := h.output.(*bytes.Buffer).String(); got != "username=x-access-token\npassword=app-token\n\n" {
		t.Fatalf("Git credentials = %q", got)
	}
	for _, request := range []string{"host=evil.example\npath=kahlstrm/config", "host=github.com\npath=someone/config"} {
		for _, args := range [][]string{{"git", "store"}, {"git", "erase"}, {"git", "get"}} {
			h.output = &bytes.Buffer{}
			h.input = strings.NewReader("protocol=https\n" + request + "\n\n")
			if code, err := h.execute(args); err != nil || code != 0 || h.output.(*bytes.Buffer).Len() != 0 {
				t.Fatalf("unsupported Git operation %v %q = %d, %v", args, request, code, err)
			}
		}
	}
}

func TestGitWaitsForPushAccess(t *testing.T) {
	for _, tt := range []struct {
		rejections, probes int
	}{{2, 3}, {100, pushAccessAttempts}} {
		t.Run(fmt.Sprint(tt.rejections), func(t *testing.T) {
			h := testHelper(t)
			probes := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/app/installations/4/access_tokens" {
					io.WriteString(w, `{"token":"app-token"}`)
					return
				}
				user, password, _ := r.BasicAuth()
				if r.URL.Path != "/kahlstrm/config.git/info/refs" || r.URL.Query().Get("service") != "git-receive-pack" || user != "x-access-token" || password != "app-token" {
					t.Errorf("probe = %s %s", r.URL, user)
				}
				if probes++; probes <= tt.rejections {
					w.WriteHeader(403)
				}
			}))
			defer server.Close()
			h.apiURL, h.gitURL = server.URL, server.URL
			h.input = strings.NewReader("protocol=https\nhost=github.com\npath=kahlstrm/config.git\n\n")
			if code, err := h.execute([]string{"git", "get"}); err != nil || code != 0 {
				t.Fatalf("Git get = %d, %v", code, err)
			}
			if probes != tt.probes || !strings.Contains(h.output.(*bytes.Buffer).String(), "password=app-token") {
				t.Fatalf("probes = %d, output = %q", probes, h.output)
			}
		})
	}
}

func TestCommandPreservesStreams(t *testing.T) {
	h := testHelper(t)
	var output, stderr bytes.Buffer
	h.env["PATH"] = os.Getenv("PATH")
	h.run = commandRunner(strings.NewReader("request body"), &output, &stderr)
	script := filepath.Join(t.TempDir(), "gh")
	shell, err := exec.LookPath("sh")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte("#!"+shell+"\n[ \"$GH_TOKEN\" = app-token ] || exit 99\ncat\necho diagnostic >&2\nexit 7\n"), 0700); err != nil {
		t.Fatal(err)
	}
	code, err := h.runGH(script, []string{"api", "repos/kahlstrm/config/contents/README.md", "--input", "-"})
	if err != nil || code != 7 || output.String() != "request body" || stderr.String() != "diagnostic\n" {
		t.Fatalf("child = %d, %v, stdout=%q stderr=%q", code, err, &output, &stderr)
	}
}
