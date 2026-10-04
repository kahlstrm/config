package lab

import (
	"strings"
	"testing"
)

func TestNegativeReply(t *testing.T) {
	for _, tc := range []struct {
		name, reply string
		roots, soa  int
		invalid     bool
	}{
		{"empty", "status: NOERROR\nANSWER: 0, AUTHORITY: 0", 0, 0, false},
		{"referral", "status: NOERROR\nANSWER: 0\n;; AUTHORITY SECTION:\n. 123 IN NS a.root-servers.net.\n;; ADDITIONAL SECTION:\n. 123 IN SOA ignored.example. hostmaster.example. 1 2 3 4 5", 1, 0, false},
		{"soa", "status: NOERROR\nANSWER: 0\n;; AUTHORITY SECTION:\nexample. 123 IN SOA ns.example. hostmaster.example. 1 2 3 4 5", 0, 1, false},
		{"positive", "status: NOERROR\nANSWER: 1", 0, 0, true},
		{"failure", "status: SERVFAIL\nANSWER: 0", 0, 0, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			roots, soa, err := NegativeReply(tc.reply)
			if (err != nil) != tc.invalid || roots != tc.roots || soa != tc.soa {
				t.Fatalf("got (%d, %d, %v)", roots, soa, err)
			}
		})
	}
}

func TestForwardPortRejectsMissingAndAmbiguousBindings(t *testing.T) {
	row := "TCP[HOST_FORWARD] 8 127.0.0.1 34589 10.0.2.15 22 0 0\n"
	for _, output := range []string{"", row + row} {
		if _, err := ForwardPort(output, "tcp", 22); err == nil {
			t.Fatal("accepted a missing or ambiguous binding")
		}
	}
	if port, err := ForwardPort(row, "tcp", 22); err != nil || port != 34589 {
		t.Fatalf("got port %d: %v", port, err)
	}
}

func TestConsoleDoesNotRepeatPasswords(t *testing.T) {
	state := ConsoleLogin{Password: "saved"}
	for _, tc := range []struct{ prompt, response string }{
		{"Login:", "admin+ct\r"}, {"Password:", "\r"},
		{"new password>", "saved\r"}, {"new password>", ""},
		{"repeat new password>", "saved\r"}, {"repeat new password>", ""},
	} {
		response, _, err := state.Respond(tc.prompt)
		if err != nil || response != tc.response {
			t.Fatalf("prompt %q: response %q, error %v", tc.prompt, response, err)
		}
	}
}

func TestConsoleRetriesSavedPasswordOnlyOnce(t *testing.T) {
	state := ConsoleLogin{Password: "saved"}
	for _, prompt := range []string{"Login:", "Password:", "Login failed\nLogin:"} {
		if _, _, err := state.Respond(prompt); err != nil {
			t.Fatal(err)
		}
	}
	response, _, err := state.Respond("Password:")
	if err != nil || response != "saved\r" {
		t.Fatalf("got %q: %v", response, err)
	}
	if _, _, err := state.Respond("Login failed"); err == nil || !strings.Contains(err.Error(), "saved lab password") {
		t.Fatalf("saved password rejection did not fail: %v", err)
	}
}
