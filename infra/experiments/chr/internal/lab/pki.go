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
	if template.NotBefore.IsZero() {
		template.NotBefore = time.Now().Add(-time.Hour)
	}
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

func signAuthority(name string, notAfter time.Time, parent *authority, key *rsa.PrivateKey) (authority, error) {
	return sign(&x509.Certificate{
		Subject:               pkix.Name{CommonName: name},
		NotAfter:              notAfter,
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
	}, parent, key)
}

func newAuthority(name string, parent *authority) (authority, error) {
	key, err := NewKey()
	if err != nil {
		return authority{}, err
	}
	return signAuthority(name, time.Now().Add(365*24*time.Hour), parent, key)
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
	return p.IntermediateUntil(name, time.Now().Add(365*24*time.Hour))
}

func (p *PKI) IntermediateUntil(name string, notAfter time.Time) (*Intermediate, error) {
	key, err := NewKey()
	if err != nil {
		return nil, err
	}
	intermediate, err := signAuthority(name, notAfter, &p.cross, key)
	return &Intermediate{authority: intermediate, chain: intermediate.pem + p.cross.pem}, err
}

// Reissue signs a new certificate for an intermediate's name and key with a later expiry,
// as a CA does to extend an intermediate. Leaves it issued verify through either one.
func (p *PKI) Reissue(i *Intermediate) (*Intermediate, error) {
	intermediate, err := signAuthority(i.cert.Subject.CommonName, i.cert.NotAfter.Add(365*24*time.Hour), &p.cross, i.key)
	return &Intermediate{authority: intermediate, chain: intermediate.pem + p.cross.pem}, err
}

func (i *Intermediate) Issue(key *rsa.PrivateKey, domain string) (Issuance, error) {
	return i.issue(&x509.Certificate{}, key, domain)
}

// IssueExpired issues a certificate whose 90 days of validity ended yesterday.
func (i *Intermediate) IssueExpired(key *rsa.PrivateKey, domain string) (Issuance, error) {
	return i.issue(&x509.Certificate{NotBefore: time.Now().Add(-91 * 24 * time.Hour), NotAfter: time.Now().Add(-24 * time.Hour)}, key, domain)
}

func (i *Intermediate) issue(template *x509.Certificate, key *rsa.PrivateKey, domain string) (Issuance, error) {
	// Let's Encrypt leaves carry a key-derived SKID, which RouterOS uses to find a
	// service's leaf; renewals that reuse the key repeat it. Go only adds one to CAs.
	skid := sha1.Sum(x509.MarshalPKCS1PublicKey(&key.PublicKey))
	template.Subject = pkix.Name{CommonName: domain}
	template.SubjectKeyId = skid[:]
	template.DNSNames = []string{domain}
	template.IPAddresses = []net.IP{net.IPv4(127, 0, 0, 1)}
	template.KeyUsage = x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment
	template.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
	leaf, err := sign(template, &i.authority, key)
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
const handshakes, concurrentHandshakes = 48, 16

type handshake struct {
	chain []*x509.Certificate
	err   error
}

// handshakeWith records the chain address presents, even if the handshake then fails.
// It retries failures before any certificate: a restarting service refuses connections,
// and when a burst overflows RouterOS's accept backlog, QEMU's user-mode network never
// retransmits the ClientHello that the guest dropped.
func handshakeWith(ctx context.Context, address string) handshake {
	for attempt := 1; ; attempt++ {
		var h handshake
		config := &tls.Config{InsecureSkipVerify: true, VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
			for _, der := range raw {
				cert, err := x509.ParseCertificate(der)
				if err != nil {
					return err
				}
				h.chain = append(h.chain, cert)
			}
			return nil
		}}
		dialCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		conn, err := (&tls.Dialer{Config: config}).DialContext(dialCtx, "tcp", address)
		cancel()
		if err == nil {
			conn.Close()
		}
		h.err = err
		if err == nil || len(h.chain) > 0 || attempt == 5 || Sleep(ctx, time.Second) != nil {
			return h
		}
	}
}

// survey counts how concurrent handshakes with address are described.
func survey(ctx context.Context, address string, describe func(handshake) string) map[string]int {
	var mu sync.Mutex
	outcomes := map[string]int{}
	var group errgroup.Group
	group.SetLimit(concurrentHandshakes)
	for range handshakes {
		group.Go(func() error {
			outcome := describe(handshakeWith(ctx, address))
			mu.Lock()
			defer mu.Unlock()
			outcomes[outcome]++
			return nil
		})
	}
	group.Wait()
	return outcomes
}

func tally(outcomes map[string]int) []string {
	lines := make([]string, 0, len(outcomes))
	for outcome, count := range outcomes {
		lines = append(lines, fmt.Sprintf("%d/%d handshakes: %s", count, handshakes, outcome))
	}
	slices.Sort(lines)
	return lines
}

// ServedChain describes the certificates address presents, without verifying them.
func ServedChain(ctx context.Context, address string) string {
	return strings.Join(tally(survey(ctx, address, func(h handshake) string {
		var description strings.Builder
		if h.err != nil {
			description.WriteString(h.err.Error())
		}
		for i, cert := range h.chain {
			fmt.Fprintf(&description, "\n  %d subject=%s issuer=%s serial=%s", i, cert.Subject, cert.Issuer, cert.SerialNumber.Text(16))
		}
		return description.String()
	})), "\n") + "\n"
}

// VerifyServed checks that every handshake with address presents the expected leaf
// with a chain that verifies against root alone, as the provider and browsers require.
func VerifyServed(ctx context.Context, address, root string, want Issuance) error {
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM([]byte(root)) {
		return errors.New("invalid root certificate")
	}
	outcomes := survey(ctx, address, func(h handshake) string {
		if h.err != nil {
			return fmt.Sprintf("handshake: %v", h.err)
		}
		intermediates := x509.NewCertPool()
		for _, cert := range h.chain[1:] {
			intermediates.AddCert(cert)
		}
		if _, err := h.chain[0].Verify(x509.VerifyOptions{Roots: roots, Intermediates: intermediates, DNSName: "127.0.0.1"}); err != nil {
			return fmt.Sprintf("verifying served chain: %v", err)
		}
		if served := h.chain[0].SerialNumber.Text(16); served != want.ID {
			return fmt.Sprintf("served certificate %s, expected %s", served, want.ID)
		}
		return ""
	})
	delete(outcomes, "")
	if len(outcomes) > 0 {
		return errors.New(strings.Join(tally(outcomes), "; "))
	}
	return nil
}
