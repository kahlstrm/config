package lab

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"strings"
	"time"
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

func (p *PKI) Intermediate(name string) (*Intermediate, error) {
	intermediate, err := newAuthority(name, &p.cross)
	return &Intermediate{authority: intermediate, chain: intermediate.pem + p.cross.pem}, err
}

func (i *Intermediate) Issue(key *rsa.PrivateKey, domain string) (Issuance, error) {
	leaf, err := sign(&x509.Certificate{
		Subject:     pkix.Name{CommonName: domain},
		DNSNames:    []string{domain},
		IPAddresses: []net.IP{net.IPv4(127, 0, 0, 1)},
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
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

// ServedChain describes the certificates address presents, without verifying them.
func ServedChain(ctx context.Context, address string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	dialer := tls.Dialer{Config: &tls.Config{InsecureSkipVerify: true}}
	conn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	var chain strings.Builder
	for i, cert := range conn.(*tls.Conn).ConnectionState().PeerCertificates {
		fmt.Fprintf(&chain, "%d subject=%s issuer=%s serial=%s\n", i, cert.Subject, cert.Issuer, cert.SerialNumber.Text(16))
	}
	return chain.String(), nil
}

// VerifyServed checks that address presents the expected leaf with a chain that
// verifies against root alone, as the provider and browsers require.
func VerifyServed(ctx context.Context, address, root string, want Issuance) error {
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM([]byte(root)) {
		return errors.New("invalid root certificate")
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	dialer := tls.Dialer{Config: &tls.Config{RootCAs: roots, ServerName: "127.0.0.1"}}
	conn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return fmt.Errorf("verifying served chain: %w", err)
	}
	defer conn.Close()
	served := conn.(*tls.Conn).ConnectionState().PeerCertificates[0].SerialNumber.Text(16)
	if served != want.ID {
		return fmt.Errorf("served certificate %s, expected %s", served, want.ID)
	}
	return nil
}
