package lab

import (
	"crypto/tls"
	"encoding/pem"
	"strings"
	"testing"
)

func serve(t *testing.T, issuance Issuance, chain string) string {
	t.Helper()
	pair, err := tls.X509KeyPair([]byte(issuance.Certificate+chain), []byte(issuance.Key))
	if err != nil {
		t.Fatal(err)
	}
	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{pair}})
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
	for _, tc := range []struct {
		name, chain string
		want        Issuance
		wantError   string
	}{
		{"full chain", issuance.Issuer, issuance, ""},
		{"missing intermediate", crossOnly, issuance, "unknown authority"},
		{"leaf only", "", issuance, "unknown authority"},
		{"stale leaf", issuance.Issuer, other, "expected " + other.ID},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := VerifyServed(t.Context(), serve(t, issuance, tc.chain), pki.Root, tc.want)
			if tc.wantError == "" && err != nil || tc.wantError != "" && (err == nil || !strings.Contains(err.Error(), tc.wantError)) {
				t.Fatalf("VerifyServed error = %v, want %q", err, tc.wantError)
			}
		})
	}
}
