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
	return configuration{
		ForkOwner: "kahlstrm-agents", UpstreamOwner: "kahlstrm", Repositories: []string{"config"},
		Apps: map[string]app{"fork": {ID: "1", InstallationID: "2"}, "upstream": {ID: "3", InstallationID: "4"}},
	}
}

func TestCredentialScope(t *testing.T) {
	for _, tt := range []struct {
		repo, purpose, app string
		permissions        map[string]string
	}{
		{"kahlstrm-agents/config", "git", "fork", map[string]string{"contents": "write"}},
		{"kahlstrm/config", "git", "upstream", map[string]string{"contents": "read"}},
		{"kahlstrm/config", "pr", "upstream", map[string]string{"contents": "read", "pull_requests": "write", "checks": "read", "actions": "read", "statuses": "read"}},
	} {
		t.Run(tt.repo+"/"+tt.purpose, func(t *testing.T) {
			name, body, err := testConfig().requestFor(tt.repo, tt.purpose)
			if err != nil || name != tt.app || !reflect.DeepEqual(body.Repositories, []string{"config"}) || !reflect.DeepEqual(body.Permissions, tt.permissions) {
				t.Fatalf("scope = %s %+v, %v", name, body, err)
			}
		})
	}
	for _, repo := range []string{"someone/config", "kahlstrm/other", "kahlstrm/config/extra", "config", "kahlstrm/../config", ""} {
		if _, _, err := testConfig().requestFor(repo, "git"); err == nil {
			t.Errorf("accepted unconfigured repository %q", repo)
		}
	}
	if _, _, err := testConfig().requestFor("kahlstrm-agents/config", "pr"); err == nil {
		t.Fatal("accepted PR credentials for fork")
	}
	cfg := testConfig()
	cfg.Repositories = append(cfg.Repositories, "project")
	name, body, err := cfg.requestFor("", "pr")
	if err != nil || name != "upstream" || !reflect.DeepEqual(body.Repositories, cfg.Repositories) || body.Permissions["contents"] != "read" {
		t.Fatalf("global token scope = %s %+v, %v", name, body, err)
	}
	cfg.Repositories = nil
	if _, _, err := cfg.requestFor("", "pr"); err == nil {
		t.Fatal("accepted an unscoped global token")
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
	for name, app := range cfg.Apps {
		app.KeyFile = path
		cfg.Apps[name] = app
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/app/installations/2/access_tokens":
			io.WriteString(w, `{"token":"fork-token"}`)
		case "/app/installations/4/access_tokens":
			io.WriteString(w, `{"token":"pr-token"}`)
		case "/installation/repositories":
			io.WriteString(w, `{"repositories":[]}`)
		case "/app":
			io.WriteString(w, `{"slug":"agent-pr"}`)
		default:
			t.Errorf("unexpected endpoint %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(server.Close)
	return &helper{config: cfg, client: server.Client(), apiURL: server.URL, input: strings.NewReader(""), output: &bytes.Buffer{}, env: map[string]string{}, checkout: func() (string, error) { return "", nil }, run: func(string, []string, map[string]string) (int, error) {
		t.Error("unexpected child command")
		return 1, nil
	}}
}

func TestMintRequest(t *testing.T) {
	h := testHelper(t)
	key, path := testKey(t, false)
	app := h.config.Apps["upstream"]
	app.KeyFile = path
	h.config.Apps["upstream"] = app
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
		var body tokenRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		if !reflect.DeepEqual(body.Repositories, []string{"config"}) || !reflect.DeepEqual(body.Permissions, prPermissions()) {
			t.Errorf("token scope = %+v", body)
		}
		io.WriteString(w, `{"token":"scoped-token"}`)
	}))
	defer server.Close()
	h.apiURL = server.URL
	token, err := h.mint("kahlstrm/config", "pr")
	if err != nil || token != "scoped-token" {
		t.Fatalf("token = %q, %v", token, err)
	}
}

func TestGhRepository(t *testing.T) {
	h := testHelper(t)
	h.checkout = func() (string, error) { return "kahlstrm-agents/config", nil }
	for _, tt := range []struct {
		args []string
		want string
	}{
		{[]string{"pr", "create"}, "kahlstrm/config"},
		{[]string{"pr", "view", "1", "-R", "kahlstrm/config"}, "kahlstrm/config"},
		{[]string{"repo", "view", "kahlstrm-agents/config"}, "kahlstrm-agents/config"},
		{[]string{"api", "repos/kahlstrm/config/pulls/1"}, "kahlstrm/config"},
		{[]string{"pr", "list", "--repo=https://github.com/kahlstrm/config.git"}, "kahlstrm/config"},
		{[]string{"pr", "list", "-Rkahlstrm-agents/config"}, "kahlstrm-agents/config"},
	} {
		repo, err := h.ghRepository(tt.args)
		if err != nil || repo != tt.want {
			t.Errorf("%v: repository = %q, %v", tt.args, repo, err)
		}
	}
	h.env["GH_REPO"] = "git@github.com:kahlstrm-agents/config.git"
	if repo, err := h.ghRepository([]string{"pr", "list"}); err != nil || repo != "kahlstrm/config" {
		t.Fatalf("GH_REPO = %q, %v", repo, err)
	}
	for _, value := range []string{"other/config", "malformed"} {
		h.env["GH_REPO"] = value
		if _, err := h.runGH("/store/gh", []string{"pr", "list"}, ""); err == nil {
			t.Errorf("accepted %s", value)
		}
	}
}

func TestGhHostPrefixedSelectors(t *testing.T) {
	for _, tt := range []struct {
		name, repository, target, token string
		args                            []string
	}{
		{"repo flag", "", "kahlstrm/config", "pr-token", []string{"pr", "list", "-R", "github.com/kahlstrm/config"}},
		{"fork flag", "", "kahlstrm-agents/config", "fork-token", []string{"repo", "view", "--repo=github.com/kahlstrm-agents/config"}},
		{"environment", "github.com/kahlstrm/config", "kahlstrm/config", "pr-token", []string{"pr", "list"}},
		{"fork environment", "github.com/kahlstrm-agents/config", "kahlstrm/config", "pr-token", []string{"pr", "list"}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			h := testHelper(t)
			h.env["GH_REPO"] = tt.repository
			h.run = func(binary string, args []string, env map[string]string) (int, error) {
				if binary != "/store/gh" || !reflect.DeepEqual(args, tt.args) || env["GH_REPO"] != tt.target || env["GH_TOKEN"] != tt.token {
					t.Errorf("command = %s %v, repository = %q, token = %q", binary, args, env["GH_REPO"], env["GH_TOKEN"])
				}
				return 0, nil
			}
			if code, err := h.runGH("/store/gh", tt.args, ""); err != nil || code != 0 {
				t.Fatalf("gh = %d, %v", code, err)
			}
		})
	}
	h := testHelper(t)
	for _, repository := range []string{"other.example/kahlstrm/config", "github.com/other/config", "github.com/kahlstrm/unconfigured"} {
		if _, err := h.runGH("/store/gh", []string{"pr", "list", "-R", repository}, ""); err == nil {
			t.Errorf("accepted unconfigured repository %q", repository)
		}
	}
}

func TestGhAPIRepositoryRouting(t *testing.T) {
	for _, tt := range []struct {
		name, endpoint, checkout, repository, target, token string
	}{
		{"leading slash fork", "/repos/kahlstrm-agents/config/contents/README", "kahlstrm/config", "", "kahlstrm-agents/config", "fork-token"},
		{"leading slash upstream", "/repos/kahlstrm/config/pulls", "", "", "kahlstrm/config", "pr-token"},
		{"checkout placeholders", "repos/{owner}/{repo}/pulls", "kahlstrm/config", "", "kahlstrm/config", "pr-token"},
		{"fork checkout placeholders", "/repos/{owner}/{repo}/pulls", "kahlstrm-agents/config", "", "kahlstrm/config", "pr-token"},
		{"environment placeholders", "repos/{owner}/{repo}/pulls", "other/unconfigured", "github.com/kahlstrm/config", "kahlstrm/config", "pr-token"},
		{"explicit fork owner", "repos/kahlstrm-agents/{repo}/contents/README", "kahlstrm/config", "", "kahlstrm-agents/config", "fork-token"},
		{"explicit repository", "repos/{owner}/config/pulls", "", "kahlstrm/config", "kahlstrm/config", "pr-token"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			h := testHelper(t)
			h.checkout = func() (string, error) { return tt.checkout, nil }
			h.env["GH_REPO"] = tt.repository
			args := []string{"api", tt.endpoint}
			h.run = func(binary string, command []string, env map[string]string) (int, error) {
				if binary != "/store/gh" || !reflect.DeepEqual(command, args) || env["GH_REPO"] != tt.target || env["GH_TOKEN"] != tt.token {
					t.Errorf("command = %s %v, repository = %q, token = %q", binary, command, env["GH_REPO"], env["GH_TOKEN"])
				}
				return 0, nil
			}
			if code, err := h.runGH("/store/gh", args, ""); err != nil || code != 0 {
				t.Fatalf("gh = %d, %v", code, err)
			}
		})
	}
	for _, tt := range []struct{ endpoint, repository string }{
		{"repos/{owner}/{repo}/pulls", ""},
		{"repos/{owner}/{repo}/pulls", "other/config"},
		{"/repos/other/config/contents/README", "kahlstrm/config"},
		{"/repos/kahlstrm-agents/unconfigured/contents/README", "kahlstrm/config"},
	} {
		h := testHelper(t)
		h.env["GH_REPO"] = tt.repository
		if _, err := h.runGH("/store/gh", []string{"api", tt.endpoint}, ""); err == nil {
			t.Errorf("accepted endpoint %q with repository %q", tt.endpoint, tt.repository)
		}
	}
}

func TestGhCloneUsesTargetInstallation(t *testing.T) {
	for _, tt := range []struct {
		repository, target, token string
	}{
		{"kahlstrm-agents/config", "kahlstrm-agents/config", "fork-token"},
		{"https://github.com/kahlstrm-agents/config.git", "kahlstrm-agents/config", "fork-token"},
		{"kahlstrm/config", "kahlstrm/config", "pr-token"},
	} {
		t.Run(tt.repository, func(t *testing.T) {
			h := testHelper(t)
			args := []string{"repo", "clone", tt.repository, "destination", "--", "--depth=1"}
			h.run = func(binary string, command []string, env map[string]string) (int, error) {
				if binary != "/store/gh" || !reflect.DeepEqual(command, args) {
					t.Errorf("clone command = %s %v", binary, command)
				}
				if env["GH_TOKEN"] != tt.token || env["GH_REPO"] != tt.target {
					t.Errorf("clone selected token %q for %q", env["GH_TOKEN"], env["GH_REPO"])
				}
				return 0, nil
			}
			for _, checkout := range []string{"", "kahlstrm/config"} {
				h.checkout = func() (string, error) { return checkout, nil }
				if code, err := h.runGH("/store/gh", args, ""); err != nil || code != 0 {
					t.Fatalf("clone = %d, %v", code, err)
				}
			}
		})
	}
	h := testHelper(t)
	for _, repository := range []string{"other/config", "kahlstrm-agents/unconfigured"} {
		if _, err := h.runGH("/store/gh", []string{"repo", "clone", repository}, ""); err == nil {
			t.Errorf("accepted unconfigured clone target %q", repository)
		}
	}
}

func TestGhEnvironmentAndExitCode(t *testing.T) {
	h := testHelper(t)
	h.checkout = func() (string, error) { return "kahlstrm-agents/config", nil }
	h.env = map[string]string{"GH_TOKEN": "personal", "GITHUB_TOKEN": "personal", "PATH": "test-path"}
	h.run = func(binary string, args []string, env map[string]string) (int, error) {
		if binary != "/store/gh" || !reflect.DeepEqual(args, []string{"pr", "list"}) {
			t.Errorf("command = %s %v", binary, args)
		}
		if env["GH_TOKEN"] != "pr-token" || env["GH_REPO"] != "kahlstrm/config" || env["GH_HOST"] != "github.com" || env["PATH"] != "test-path" {
			t.Errorf("environment = %v", env)
		}
		if _, exists := env["GITHUB_TOKEN"]; exists {
			t.Error("inherited personal token")
		}
		return 7, nil
	}
	if code, err := h.runGH("/store/gh", []string{"pr", "list"}, ""); err != nil || code != 7 {
		t.Fatalf("exit = %d, %v", code, err)
	}
	if h.env["GH_TOKEN"] != "personal" || h.env["GITHUB_TOKEN"] != "personal" {
		t.Fatal("mutated parent credentials")
	}
}

func TestGhAuthAndViewer(t *testing.T) {
	h := testHelper(t)
	if code, err := h.runGH("/store/gh", []string{"auth", "status", "--json", "hosts"}, ""); err != nil || code != 0 {
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
	if _, err := h.runGH("/store/gh", []string{"api", "user", "--jq", ".login"}, ""); err != nil {
		t.Fatal(err)
	}
}

func TestGhRejectionsAndUnauthenticatedHelp(t *testing.T) {
	h := testHelper(t)
	for _, args := range [][]string{{"auth", "login"}, {"api", "user", "--hostname", "evil.example"}, {"pr", "list", "-R"}} {
		if _, err := h.runGH("/store/gh", args, ""); err == nil {
			t.Errorf("accepted %v", args)
		}
	}
	h.config.Apps = nil
	h.run = func(string, []string, map[string]string) (int, error) { return 0, nil }
	if code, err := h.runGH("/store/gh", []string{"--version"}, ""); err != nil || code != 0 {
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
					io.WriteString(w, `{"token":"pr-token"}`)
					return
				}
				w.WriteHeader(tt.status)
				io.WriteString(w, tt.body)
			}))
			defer server.Close()
			h.apiURL = server.URL
			if _, err := h.runGH("/store/gh", []string{"auth", "status", "--json", "hosts"}, ""); err == nil {
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
	h.input = strings.NewReader("protocol=https\nhost=github.com\npath=kahlstrm-agents/config.git\n\n")
	if code, err := h.execute([]string{"git", "get"}); err != nil || code != 0 {
		t.Fatalf("Git get = %d, %v", code, err)
	}
	if got := h.output.(*bytes.Buffer).String(); got != "username=x-access-token\npassword=fork-token\n\n" {
		t.Fatalf("Git credentials = %q", got)
	}
	for _, args := range [][]string{{"git", "store"}, {"git", "erase"}, {"git", "get"}} {
		h.output = &bytes.Buffer{}
		h.input = strings.NewReader("protocol=https\nhost=evil.example\npath=kahlstrm/config\n\n")
		if code, err := h.execute(args); err != nil || code != 0 || h.output.(*bytes.Buffer).Len() != 0 {
			t.Fatalf("unsupported Git operation = %d, %v", code, err)
		}
	}
}

func TestForkCommandPreservesStreams(t *testing.T) {
	h := testHelper(t)
	var output, stderr bytes.Buffer
	h.env["PATH"] = os.Getenv("PATH")
	h.run = commandRunner(strings.NewReader("request body"), &output, &stderr)
	script := filepath.Join(t.TempDir(), "gh")
	shell, err := exec.LookPath("sh")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte("#!"+shell+"\n[ \"$GH_TOKEN\" = fork-token ] || exit 99\ncat\necho diagnostic >&2\nexit 7\n"), 0700); err != nil {
		t.Fatal(err)
	}
	code, err := h.runGH(script, []string{"api", "repos/kahlstrm-agents/config/contents/README.md", "--input", "-"}, "")
	if err != nil || code != 7 || output.String() != "request body" || stderr.String() != "diagnostic\n" {
		t.Fatalf("child = %d, %v, stdout=%q stderr=%q", code, err, &output, &stderr)
	}
}

func TestCheckoutPrefersUpstream(t *testing.T) {
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git: %v %s", err, out)
		}
	}
	run("init")
	run("remote", "add", "origin", "https://github.com/kahlstrm-agents/config.git")
	t.Chdir(dir)
	if repo, err := checkoutRepository(); err != nil || repo != "kahlstrm-agents/config" {
		t.Fatalf("origin = %s, %v", repo, err)
	}
	run("remote", "add", "upstream", "https://github.com/kahlstrm/config.git")
	if repo, err := checkoutRepository(); err != nil || repo != "kahlstrm/config" {
		t.Fatalf("upstream = %s, %v", repo, err)
	}
	run("remote", "set-url", "upstream", "https://evil.example/config")
	if _, err := checkoutRepository(); err == nil {
		t.Fatal("unsupported remote silently fell back to global credentials")
	}
	h := testHelper(t)
	h.checkout = checkoutRepository
	if _, err := h.runGH("/store/gh", []string{"pr", "list"}, ""); err == nil {
		t.Fatal("accepted unsupported checkout remote")
	}
}
