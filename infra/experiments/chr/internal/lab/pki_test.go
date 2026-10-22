package lab

import (
	"crypto/tls"
	"encoding/pem"
	"strings"
	"sync/atomic"
	"testing"
)

type served struct {
	issuance Issuance
	chain    string
}

// serve rotates through workers per connection, like a server whose worker
// processes loaded different certificates.
func serve(t *testing.T, workers ...served) string {
	t.Helper()
	pairs := make([]tls.Certificate, len(workers))
	for i, worker := range workers {
		pair, err := tls.X509KeyPair([]byte(worker.issuance.Certificate+worker.chain), []byte(worker.issuance.Key))
		if err != nil {
			t.Fatal(err)
		}
		pairs[i] = pair
	}
	var connections atomic.Int64
	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{GetCertificate: func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
		return &pairs[connections.Add(1)%int64(len(pairs))], nil
	}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			conn.(*tls.Conn).Handshake()
			conn.Close()
		}
	}()
	return listener.Addr().String()
}

func TestVerifyServed(t *testing.T) {
	pki, err := NewPKI()
	if err != nil {
		t.Fatal(err)
	}
	intermediate, err := pki.Intermediate("Lab YR1")
	if err != nil {
		t.Fatal(err)
	}
	key, err := NewKey()
	if err != nil {
		t.Fatal(err)
	}
	issuance, err := intermediate.Issue(key, "router.lab.test")
	if err != nil {
		t.Fatal(err)
	}
	if blocks := strings.Count(issuance.Issuer, "-----BEGIN CERTIFICATE-----"); blocks != 2 {
		t.Fatalf("issuer chain has %d certificates, want intermediate and cross-sign", blocks)
	}
	first, _ := pem.Decode([]byte(issuance.Issuer))
	crossOnly := strings.TrimPrefix(issuance.Issuer, string(pem.EncodeToMemory(first)))
	other, err := intermediate.Issue(key, "router.lab.test")
	if err != nil {
		t.Fatal(err)
	}
	current := served{issuance, issuance.Issuer}
	for _, tc := range []struct {
		name      string
		workers   []served
		want      Issuance
		wantError string
	}{
		{"full chain", []served{current}, issuance, ""},
		{"missing intermediate", []served{{issuance, crossOnly}}, issuance, "unknown authority"},
		{"leaf only", []served{{issuance, ""}}, issuance, "unknown authority"},
		{"stale leaf", []served{current}, other, "expected " + other.ID},
		{"one stale worker", []served{current, current, current, {other, issuance.Issuer}}, issuance, "expected " + issuance.ID},
		{"one worker without chain", []served{current, current, current, {issuance, ""}}, issuance, "unknown authority"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := VerifyServed(t.Context(), serve(t, tc.workers...), pki.Root, tc.want)
			if tc.wantError == "" && err != nil || tc.wantError != "" && (err == nil || !strings.Contains(err.Error(), tc.wantError)) {
				t.Fatalf("VerifyServed error = %v, want %q", err, tc.wantError)
			}
		})
	}
}
