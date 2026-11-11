package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"time"
)

// credentials creates the GCP private key and its self-signed certificate in state, once, and
// writes the service account key file that Terraform and newGCP read to keyFile(). The
// certificate is what a maintainer uploads as the account's key; GCP takes the key's expiry
// from it. Without an account or key ID, it removes the key file instead.
func credentials(state, email, keyID string) error {
	keyPath, certPath := filepath.Join(state, "gcp.key"), filepath.Join(state, "gcp.crt")
	if _, err := os.Stat(keyPath); errors.Is(err, os.ErrNotExist) {
		key, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			return err
		}
		der, err := x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			return err
		}
		if err := place(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0400); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	data, err := os.ReadFile(keyPath)
	if err != nil {
		return err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return errors.New(keyPath + ": no private key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return err
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return errors.New(keyPath + ": not an RSA key")
	}
	if _, err := os.Stat(certPath); errors.Is(err, os.ErrNotExist) {
		now := time.Now()
		template := &x509.Certificate{
			SerialNumber: big.NewInt(now.UnixNano()),
			Subject:      pkix.Name{CommonName: "unused"},
			NotBefore:    now,
			NotAfter:     now.AddDate(1, 0, 0),
		}
		der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
		if err != nil {
			return err
		}
		if err := place(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0444); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	if email == "" || keyID == "" {
		if err := os.Remove(keyFile()); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	file, _ := json.Marshal(map[string]string{
		"type":           "service_account",
		"project_id":     project,
		"private_key_id": keyID,
		"private_key":    string(data),
		"client_email":   email,
		"token_uri":      "https://oauth2.googleapis.com/token",
	})
	return place(keyFile(), file, 0400)
}

// place writes data to path through a temporary file, so a reader never sees half of it.
func place(path string, data []byte, mode os.FileMode) error {
	temporary := path + ".new"
	os.Remove(temporary)
	if err := os.WriteFile(temporary, data, 0600); err != nil {
		return err
	}
	if err := os.Chmod(temporary, mode); err != nil {
		return err
	}
	return os.Rename(temporary, path)
}
