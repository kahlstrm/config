package main

import (
	"bufio"
	"bytes"
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
	"maps"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strings"
	"time"
)

type app struct {
	ID             string `json:"id"`
	InstallationID string `json:"installationId"`
	KeyFile        string `json:"keyFile"`
}

type configuration struct {
	Owner string `json:"owner"`
	App   app    `json:"app"`
}

// Tokens inherit the App's permissions; the installation decides repository access.
type tokenRequest struct {
	Repositories []string          `json:"repositories,omitempty"`
	Permissions  map[string]string `json:"permissions,omitempty"`
}

var repositoryNamePattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

func (c configuration) repositoryScope(repository string) (tokenRequest, error) {
	owner, name, found := strings.Cut(repository, "/")
	if !found || owner != c.Owner || !repositoryNamePattern.MatchString(name) || name == "." || name == ".." {
		return tokenRequest{}, errors.New("repository is not managed by the App")
	}
	return tokenRequest{Repositories: []string{name}}, nil
}

func gitRepository(fields map[string]string) (string, error) {
	if fields["protocol"] != "https" || fields["host"] != "github.com" {
		return "", errors.New("only github.com HTTPS credentials are supported")
	}
	if fields["path"] == "" {
		return "", errors.New("Git credential.useHttpPath must be enabled")
	}
	return strings.TrimSuffix(fields["path"], ".git"), nil
}

func appJWT(a app, now time.Time) (string, error) {
	data, err := os.ReadFile(a.KeyFile)
	if err != nil {
		return "", err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return "", errors.New("invalid PEM key")
	}
	var key *rsa.PrivateKey
	switch block.Type {
	case "RSA PRIVATE KEY":
		key, err = x509.ParsePKCS1PrivateKey(block.Bytes)
	case "PRIVATE KEY":
		var parsed any
		parsed, err = x509.ParsePKCS8PrivateKey(block.Bytes)
		key, _ = parsed.(*rsa.PrivateKey)
	default:
		return "", errors.New("unsupported PEM key type")
	}
	if err != nil {
		return "", err
	}
	if key == nil {
		return "", errors.New("App key must be RSA")
	}
	header, err := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(struct {
		IssuedAt  int64  `json:"iat"`
		ExpiresAt int64  `json:"exp"`
		Issuer    string `json:"iss"`
	}{now.Unix() - 60, now.Unix() + 540, a.ID})
	if err != nil {
		return "", err
	}
	encoding := base64.RawURLEncoding
	input := encoding.EncodeToString(header) + "." + encoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(input))
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		return "", err
	}
	return input + "." + encoding.EncodeToString(signature), nil
}

type helper struct {
	config configuration
	client *http.Client
	apiURL string
	input  io.Reader
	output io.Writer
	env    map[string]string
	run    func(string, []string, map[string]string) (int, error)
}

type apiError struct{ status int }

func (e apiError) Error() string {
	return fmt.Sprintf("GitHub App request failed (HTTP %d)", e.status)
}

func (h *helper) request(endpoint, token string, body, result any) error {
	method := http.MethodGet
	var data []byte
	if body != nil {
		method = http.MethodPost
		var err error
		data, err = json.Marshal(body)
		if err != nil {
			return err
		}
	}
	req, err := http.NewRequest(method, h.apiURL+"/"+endpoint, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", "kahlstrm-agents")
	req.Header.Set("Content-Type", "application/json")
	response, err := h.client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return apiError{response.StatusCode}
	}
	return json.NewDecoder(response.Body).Decode(result)
}

func (h *helper) installationToken(body tokenRequest) (string, error) {
	jwt, err := appJWT(h.config.App, time.Now())
	if err != nil {
		return "", err
	}
	var result struct {
		Token string `json:"token"`
	}
	if err := h.request("app/installations/"+h.config.App.InstallationID+"/access_tokens", jwt, body, &result); err != nil {
		return "", err
	}
	if result.Token == "" {
		return "", errors.New("missing installation token")
	}
	return result.Token, nil
}

func (h *helper) appLogin() (string, error) {
	jwt, err := appJWT(h.config.App, time.Now())
	if err != nil {
		return "", err
	}
	var result struct {
		Slug string `json:"slug"`
	}
	if err := h.request("app", jwt, nil, &result); err != nil {
		return "", err
	}
	if result.Slug == "" {
		return "", errors.New("missing App identity")
	}
	return result.Slug + "[bot]", nil
}

func option(args []string, name, short string) (string, error) {
	for index, arg := range args {
		if arg == name || short != "" && arg == short {
			if index+1 == len(args) {
				return "", errors.New("missing option value")
			}
			return args[index+1], nil
		}
		if strings.HasPrefix(arg, name+"=") {
			return strings.TrimPrefix(arg, name+"="), nil
		}
		if short != "" && strings.HasPrefix(arg, short) && len(arg) > len(short) {
			return strings.TrimPrefix(arg, short), nil
		}
	}
	return "", nil
}

func startsWith(args []string, prefix ...string) bool {
	return len(args) >= len(prefix) && slices.Equal(args[:len(prefix)], prefix)
}

func (h *helper) authStatus(token string, args []string) error {
	// gh probes /user, which installation tokens cannot authenticate.
	var repositories json.RawMessage
	if err := h.request("installation/repositories", token, nil, &repositories); err != nil {
		return err
	}
	login, err := h.appLogin()
	if err != nil {
		return err
	}
	format, err := option(args, "--json", "")
	if err != nil {
		return err
	}
	if format == "hosts" {
		status := map[string]any{"hosts": map[string]any{"github.com": []any{map[string]any{"state": "success", "active": true, "host": "github.com", "login": login, "tokenSource": "GitHub App"}}}}
		return json.NewEncoder(h.output).Encode(status)
	}
	_, err = fmt.Fprintf(h.output, "github.com: authenticated as %s (GitHub App installation)\n", login)
	return err
}

func (h *helper) runGH(binary string, args []string) (int, error) {
	if len(args) == 0 || slices.Contains([]string{"--version", "version", "--help", "help"}, args[0]) || slices.Contains(args, "--help") || args[len(args)-1] == "-h" {
		return h.run(binary, args, h.env)
	}
	host, err := option(args, "--hostname", "-h")
	if err != nil {
		return 0, err
	}
	if host == "" {
		host = h.env["GH_HOST"]
	}
	if host != "" && host != "github.com" {
		return 0, errors.New("only github.com is supported")
	}
	if args[0] == "auth" && !startsWith(args, "auth", "status") && !startsWith(args, "auth", "token") {
		return 0, errors.New("GitHub authentication is managed by the App")
	}
	token, err := h.installationToken(tokenRequest{})
	if err != nil {
		return 0, err
	}
	if startsWith(args, "auth", "status") {
		return 0, h.authStatus(token, args)
	}
	if startsWith(args, "api", "user") {
		login, err := h.appLogin()
		if err != nil {
			return 0, err
		}
		args = append([]string{"api", "users/" + login}, args[2:]...)
	}
	env := maps.Clone(h.env)
	delete(env, "GITHUB_TOKEN")
	env["GH_TOKEN"], env["GH_HOST"] = token, "github.com"
	return h.run(binary, args, env)
}

func (h *helper) gitCredentials() error {
	fields := map[string]string{}
	scanner := bufio.NewScanner(h.input)
	for scanner.Scan() {
		if scanner.Text() == "" {
			break
		}
		if name, value, ok := strings.Cut(scanner.Text(), "="); ok {
			fields[name] = value
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	repository, err := gitRepository(fields)
	if err != nil {
		return nil
	}
	// Other repositories fall through to anonymous access.
	scope, err := h.config.repositoryScope(repository)
	if err != nil {
		return nil
	}
	token, err := h.installationToken(scope)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(h.output, "username=x-access-token\npassword=%s\n\n", token)
	return err
}

func (h *helper) execute(args []string) (int, error) {
	if startsWith(args, "git") {
		if !slices.Equal(args, []string{"git", "get"}) {
			return 0, nil
		}
		return 0, h.gitCredentials()
	}
	if startsWith(args, "gh") && len(args) >= 2 {
		return h.runGH(args[1], args[2:])
	}
	return 0, errors.New("invalid helper invocation")
}

func commandRunner(input io.Reader, output, stderr io.Writer) func(string, []string, map[string]string) (int, error) {
	return func(binary string, args []string, env map[string]string) (int, error) {
		command := exec.Command(binary, args...)
		command.Stdin, command.Stdout, command.Stderr = input, output, stderr
		command.Env = make([]string, 0, len(env))
		for name, value := range env {
			command.Env = append(command.Env, name+"="+value)
		}
		if err := command.Run(); err != nil {
			var exit *exec.ExitError
			if errors.As(err, &exit) {
				code := exit.ExitCode()
				if code < 0 {
					code = 1
				}
				return code, nil
			}
			return 0, err
		}
		return 0, nil
	}
}

func main() {
	data, err := os.ReadFile("/etc/agent-github.json")
	var cfg configuration
	if err == nil {
		err = json.Unmarshal(data, &cfg)
	}
	code := 1
	if err == nil {
		env := map[string]string{}
		for _, entry := range os.Environ() {
			if name, value, ok := strings.Cut(entry, "="); ok {
				env[name] = value
			}
		}
		h := helper{
			config: cfg, client: &http.Client{Timeout: 30 * time.Second}, apiURL: "https://api.github.com",
			input: os.Stdin, output: os.Stdout, env: env,
			run: commandRunner(os.Stdin, os.Stdout, os.Stderr),
		}
		code, err = h.execute(os.Args[1:])
	}
	if err != nil {
		var api apiError
		if errors.As(err, &api) {
			fmt.Fprintln(os.Stderr, api)
		} else {
			fmt.Fprintln(os.Stderr, "GitHub credentials unavailable; check App configuration, runtime keys, and connectivity")
		}
		code = 1
	}
	os.Exit(code)
}
