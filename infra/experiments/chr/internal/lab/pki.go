package lab

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"slices"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/errgroup"
)

type authority struct {
	cert *x509.Certificate
	key  *rsa.PrivateKey
	pem  string
}

// PKI mirrors Let's Encrypt's chain: clients trust only Root, intermediates are
// signed by a cross-signed root that servers send along with them.
type PKI struct {
	Root  string
	cross authority
}

// CrossSigned is the root that intermediates chain to, signed by Root.
func (p *PKI) CrossSigned() string { return p.cross.pem }

type Issuance struct {
	ID, Certificate, Key, Issuer string
}

func NewKey() (*rsa.PrivateKey, error) { return rsa.GenerateKey(rand.Reader, 2048) }

func encode(kind string, der []byte) string {
	return string(pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: der}))
}

func sign(template *x509.Certificate, parent *authority, key *rsa.PrivateKey) (authority, error) {
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return authority{}, err
	}
	template.SerialNumber = serial
	template.NotBefore = time.Now().Add(-time.Hour)
	if template.NotAfter.IsZero() {
		template.NotAfter = time.Now().Add(90 * 24 * time.Hour)
	}
	signer, issuer := key, template
	if parent != nil {
		signer, issuer = parent.key, parent.cert
	}
	der, err := x509.CreateCertificate(rand.Reader, template, issuer, &key.PublicKey, signer)
	if err != nil {
		return authority{}, err
	}
	cert, err := x509.ParseCertificate(der)
	return authority{cert: cert, key: key, pem: encode("CERTIFICATE", der)}, err
}

func newAuthority(name string, parent *authority) (authority, error) {
	key, err := NewKey()
	if err != nil {
		return authority{}, err
	}
	return sign(&x509.Certificate{
		Subject:               pkix.Name{CommonName: name},
		NotAfter:              time.Now().Add(365 * 24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
	}, parent, key)
}

func NewPKI() (*PKI, error) {
	root, err := newAuthority("Lab Root X1", nil)
	if err != nil {
		return nil, err
	}
	cross, err := newAuthority("Lab Root YR", &root)
	return &PKI{Root: root.pem, cross: cross}, err
}

type Intermediate struct {
	authority
	chain string
}

func (i *Intermediate) PEM() string { return i.pem }

func (p *PKI) Intermediate(name string) (*Intermediate, error) {
	intermediate, err := newAuthority(name, &p.cross)
	return &Intermediate{authority: intermediate, chain: intermediate.pem + p.cross.pem}, err
}

func (i *Intermediate) Issue(key *rsa.PrivateKey, domain string) (Issuance, error) {
	// Let's Encrypt leaves carry a key-derived SKID, which RouterOS uses to find a
	// service's leaf; renewals that reuse the key repeat it. Go only adds one to CAs.
	skid := sha1.Sum(x509.MarshalPKCS1PublicKey(&key.PublicKey))
	leaf, err := sign(&x509.Certificate{
		Subject:      pkix.Name{CommonName: domain},
		SubjectKeyId: skid[:],
		DNSNames:     []string{domain},
		IPAddresses:  []net.IP{net.IPv4(127, 0, 0, 1)},
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}, &i.authority, key)
	if err != nil {
		return Issuance{}, err
	}
	return Issuance{
		ID:          leaf.cert.SerialNumber.Text(16),
		Certificate: leaf.pem,
		Key:         encode("RSA PRIVATE KEY", x509.MarshalPKCS1PrivateKey(key)),
		Issuer:      i.chain,
	}, nil
}

// RouterOS www-ssl hands connections to worker processes that keep whichever
// certificate was current when they started, so a single handshake proves little.
// More concurrent handshakes than the service's max-sessions get refused.
const handshakes, concurrentHandshakes = 48, 16

// probe performs handshakes against address and counts each distinct outcome.
// handshake prepares each handshake's configuration and returns how to describe it.
func probe(ctx context.Context, address string, handshake func(*tls.Config) func(tls.ConnectionState, error) string) map[string]int {
	var mu sync.Mutex
	outcomes := map[string]int{}
	var group errgroup.Group
	group.SetLimit(concurrentHandshakes)
	for range handshakes {
		group.Go(func() error {
			result := handshakeOnce(ctx, address, handshake)
			mu.Lock()
			defer mu.Unlock()
			outcomes[result]++
			return nil
		})
	}
	group.Wait()
	return outcomes
}

// handshakeOnce retries a handshake that timed out before the server presented a
// certificate. A burst of connections can overflow RouterOS's accept backlog, and
// QEMU's user-mode network never retransmits the ClientHello that the guest dropped.
func handshakeOnce(ctx context.Context, address string, handshake func(*tls.Config) func(tls.ConnectionState, error) string) string {
	for attempt := 1; ; attempt++ {
		config := &tls.Config{}
		outcome := handshake(config)
		presented := false
		verify := config.VerifyPeerCertificate
		config.VerifyPeerCertificate = func(raw [][]byte, chains [][]*x509.Certificate) error {
			presented = true
			if verify != nil {
				return verify(raw, chains)
			}
			return nil
		}
		ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		conn, err := (&tls.Dialer{Config: config}).DialContext(ctx, "tcp", address)
		cancel()
		if err != nil && errors.Is(err, context.DeadlineExceeded) && !presented && attempt < 3 {
			continue
		}
		var state tls.ConnectionState
		if err == nil {
			state = conn.(*tls.Conn).ConnectionState()
			conn.Close()
		}
		return outcome(state, err)
	}
}

func tally(outcomes map[string]int) []string {
	lines := make([]string, 0, len(outcomes))
	for outcome, count := range outcomes {
		lines = append(lines, fmt.Sprintf("%d/%d handshakes: %s", count, handshakes, outcome))
	}
	slices.Sort(lines)
	return lines
}

// WaitServing waits until address completes a TLS handshake, as after a service restart.
func WaitServing(ctx context.Context, address string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	dialer := tls.Dialer{Config: &tls.Config{InsecureSkipVerify: true}}
	for {
		conn, err := dialer.DialContext(ctx, "tcp", address)
		if err == nil {
			return conn.Close()
		}
		if Sleep(ctx, time.Second) != nil {
			return fmt.Errorf("waiting for TLS on %s: %w", address, err)
		}
	}
}

// ServedChain describes the certificates address presents, without verifying them.
// The chain is captured before the handshake signature check, so a leaf served
// with a mismatched key still shows up next to the error.
func ServedChain(ctx context.Context, address string) string {
	return strings.Join(tally(probe(ctx, address, func(config *tls.Config) func(tls.ConnectionState, error) string {
		var chain strings.Builder
		config.InsecureSkipVerify = true
		config.VerifyPeerCertificate = func(raw [][]byte, _ [][]*x509.Certificate) error {
			for i, der := range raw {
				cert, err := x509.ParseCertificate(der)
				if err != nil {
					return err
				}
				fmt.Fprintf(&chain, "\n  %d subject=%s issuer=%s serial=%s", i, cert.Subject, cert.Issuer, cert.SerialNumber.Text(16))
			}
			return nil
		}
		return func(_ tls.ConnectionState, err error) string {
			if err != nil {
				return err.Error() + chain.String()
			}
			return chain.String()
		}
	})), "\n") + "\n"
}

// VerifyServed checks that every handshake with address presents the expected leaf
// with a chain that verifies against root alone, as the provider and browsers require.
func VerifyServed(ctx context.Context, address, root string, want Issuance) error {
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM([]byte(root)) {
		return errors.New("invalid root certificate")
	}
	outcomes := probe(ctx, address, func(config *tls.Config) func(tls.ConnectionState, error) string {
		config.RootCAs, config.ServerName = roots, "127.0.0.1"
		return func(state tls.ConnectionState, err error) string {
			if err != nil {
				return fmt.Sprintf("verifying served chain: %v", err)
			}
			if served := state.PeerCertificates[0].SerialNumber.Text(16); served != want.ID {
				return fmt.Sprintf("served certificate %s, expected %s", served, want.ID)
			}
			return ""
		}
	})
	delete(outcomes, "")
	if len(outcomes) > 0 {
		return errors.New(strings.Join(tally(outcomes), "; "))
	}
	return nil
}
