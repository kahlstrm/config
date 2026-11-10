// secret-edit changes properties of the local-kubernetes Secret Manager secret from an Amp
// orb. It authenticates with the orb's own short-lived identity through the amp-orbs workload
// identity pool (infra/gcp-project/amp-orbs.tf) and never prints a value. See the secret-edits
// ADR in infra/docs/adr.
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"hash/crc32"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	project  = "infra-464520"
	secret   = "local-kubernetes"
	audience = "urn:amp:gcp:" + project
	provider = "//iam.googleapis.com/projects/638826885263/locations/global/workloadIdentityPools/amp-orbs/providers/ampcode"
)

// The endpoints and the Amp token are variables so that tests can replace them.
var (
	stsURL        = "https://sts.googleapis.com/v1/token"
	secretManager = "https://secretmanager.googleapis.com"
	idToken       = func(ctx context.Context) (string, error) {
		command := exec.CommandContext(ctx, "amp", "orb", "id-token", "--audience", audience)
		command.Stderr = os.Stderr
		out, err := command.Output()
		if err != nil {
			return "", fmt.Errorf("amp orb id-token: %w (run this in an Amp orb)", err)
		}
		return strings.TrimSpace(string(out)), nil
	}
)

const usage = `usage: secret-edit [--from-env PATH=VARIABLE] [--remove PATH]...
  Writes a new version of the local-kubernetes secret with only the named properties changed,
  then destroys the versions before the one it read. Values are never printed.`

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, os.Args[1:], os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "secret-edit:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, getenv func(string) string, stdout io.Writer) error {
	var edits []edit
	flags := flag.NewFlagSet("secret-edit", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	for _, name := range []string{"from-env", "remove"} {
		flags.Func(name, "property change", func(spec string) error {
			e, err := parseEdit(name, spec)
			edits = append(edits, e)
			return err
		})
	}
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return errors.New(usage)
		}
		return err
	}
	if flags.NArg() != 0 || len(edits) == 0 {
		return errors.New(usage)
	}
	seen := map[string]bool{}
	for _, e := range edits {
		if seen[e.String()] {
			return fmt.Errorf("%s: changed twice", e)
		}
		seen[e.String()] = true
	}
	g, err := newGCP(ctx)
	if err != nil {
		return err
	}
	data, read, err := g.access(ctx)
	if err != nil {
		return fmt.Errorf("read %s: %w", secret, err)
	}
	updated, report, err := editSecret(data, edits, getenv)
	if err != nil {
		return fmt.Errorf("%s version %d: %w", secret, read, err)
	}
	added, err := g.addVersion(ctx, updated)
	if err != nil {
		return fmt.Errorf("write %s: %w", secret, err)
	}
	fmt.Fprintf(stdout, "%s: version %d → %d: %s. Values were not printed.\n", secret, read, added, strings.Join(report, ", "))
	if added != read+1 {
		// Another edit wrote in between and this one replaced it; destroy nothing.
		return fmt.Errorf("another version was added after version %d was read, so version %d may have undone it; check the versions in between", read, added)
	}
	// Every active version is billed, and older versions hold values that were meant to go.
	// Version read stays enabled so that the edit can be undone.
	destroyed, err := g.destroyBefore(ctx, read)
	if len(destroyed) > 0 {
		fmt.Fprintf(stdout, "Destroyed versions %s; Secret Manager deletes them after a day.\n", strings.Trim(fmt.Sprint(destroyed), "[]"))
	}
	if err != nil {
		return fmt.Errorf("the new version is written, but destroying older versions failed: %w", err)
	}
	fmt.Fprintln(stdout, "External Secrets picks up the change at its next refresh, within an hour.")
	return nil
}

// gcp calls Secret Manager with a federated access token for the orb's identity.
type gcp struct {
	token  string
	client *http.Client
}

func newGCP(ctx context.Context) (*gcp, error) {
	subject, err := idToken(ctx)
	if err != nil {
		return nil, err
	}
	g := &gcp{client: &http.Client{Timeout: time.Minute}}
	form := url.Values{
		"grant_type":           {"urn:ietf:params:oauth:grant-type:token-exchange"},
		"audience":             {provider},
		"scope":                {"https://www.googleapis.com/auth/cloud-platform"},
		"requested_token_type": {"urn:ietf:params:oauth:token-type:access_token"},
		"subject_token_type":   {"urn:ietf:params:oauth:token-type:id_token"},
		"subject_token":        {subject},
	}
	var token struct {
		AccessToken string `json:"access_token"`
	}
	if err := g.do(ctx, http.MethodPost, stsURL, "application/x-www-form-urlencoded", strings.NewReader(form.Encode()), &token); err != nil {
		return nil, fmt.Errorf("exchange the orb's token: %w", err)
	}
	g.token = token.AccessToken
	return g, nil
}

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
	if response.StatusCode >= 300 {
		// Google's errors carry a status and message, or STS's error and description, never a
		// secret's data.
		var failure struct {
			Error       json.RawMessage `json:"error"`
			Description string          `json:"error_description"`
		}
		_ = json.Unmarshal(data, &failure)
		var detail struct{ Status, Message string }
		if json.Unmarshal(failure.Error, &detail) != nil {
			_ = json.Unmarshal(failure.Error, &detail.Status)
			detail.Message = failure.Description
		}
		return fmt.Errorf("%s %s: %s: %s %s", method, request.URL.Path, response.Status, detail.Status, detail.Message)
	}
	return json.Unmarshal(data, out)
}

func secretURL(suffix string) string {
	return fmt.Sprintf("%s/v1/projects/%s/secrets/%s%s", secretManager, project, secret, suffix)
}

// versionNumber returns the number at the end of a version's resource name.
func versionNumber(name string) (int, error) {
	return strconv.Atoi(name[strings.LastIndex(name, "/")+1:])
}

// access returns the latest version and its number.
func (g *gcp) access(ctx context.Context) ([]byte, int, error) {
	var version struct {
		Name    string
		Payload struct{ Data string }
	}
	if err := g.do(ctx, http.MethodGet, secretURL("/versions/latest:access"), "", nil, &version); err != nil {
		return nil, 0, err
	}
	number, err := versionNumber(version.Name)
	if err != nil {
		return nil, 0, err
	}
	data, err := base64.StdEncoding.DecodeString(version.Payload.Data)
	return data, number, err
}

// addVersion writes data as a new version and returns its number.
func (g *gcp) addVersion(ctx context.Context, data []byte) (int, error) {
	sum := crc32.Checksum(data, crc32.MakeTable(crc32.Castagnoli))
	body, _ := json.Marshal(map[string]any{"payload": map[string]any{"data": base64.StdEncoding.EncodeToString(data), "dataCrc32c": fmt.Sprint(sum)}})
	var version struct{ Name string }
	if err := g.do(ctx, http.MethodPost, secretURL(":addVersion"), "application/json", bytes.NewReader(body), &version); err != nil {
		return 0, err
	}
	return versionNumber(version.Name)
}

// destroyBefore destroys the enabled versions numbered below keep and returns their numbers.
func (g *gcp) destroyBefore(ctx context.Context, keep int) ([]int, error) {
	var names []string
	query := url.Values{"filter": {"state:ENABLED"}, "pageSize": {"100"}}
	for {
		var page struct {
			Versions      []struct{ Name string }
			NextPageToken string
		}
		if err := g.do(ctx, http.MethodGet, secretURL("/versions?"+query.Encode()), "", nil, &page); err != nil {
			return nil, err
		}
		for _, v := range page.Versions {
			names = append(names, v.Name)
		}
		if page.NextPageToken == "" {
			break
		}
		query.Set("pageToken", page.NextPageToken)
	}
	var destroyed []int
	for _, name := range names {
		number, err := versionNumber(name)
		if err != nil {
			return destroyed, err
		}
		if number >= keep {
			continue
		}
		uri := fmt.Sprintf("%s/v1/%s:destroy", secretManager, name)
		if err := g.do(ctx, http.MethodPost, uri, "application/json", strings.NewReader("{}"), &struct{}{}); err != nil {
			return destroyed, err
		}
		destroyed = append(destroyed, number)
	}
	slices.Sort(destroyed)
	return destroyed, nil
}
