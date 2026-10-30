package main

import (
	"slices"
	"strings"
	"testing"
	"time"
)

func TestFlagsCountBeforeAndAfterTheCommand(t *testing.T) {
	for _, args := range [][]string{
		{"recreate", "-include", "kube-system/a,web/b", "-timeout", "2m"},
		{"-include", "kube-system/a,web/b", "recreate", "-timeout", "2m"},
		{"-include=kube-system/a,web/b", "-timeout=2m", "recreate"},
	} {
		inv, err := parse(args)
		if err != nil {
			t.Fatalf("%v: %v", args, err)
		}
		if inv.command != "recreate" || !slices.Equal(inv.include, []string{"kube-system/a", "web/b"}) || inv.timeout != 2*time.Minute {
			t.Errorf("%v parsed as %+v", args, inv)
		}
	}
}

func TestLeftoverAndMalformedArgumentsAreRejected(t *testing.T) {
	for args, want := range map[string]string{
		"recreate extra":                 `unexpected argument "extra"`,
		"recreate -include web/a plan":   `unexpected argument "plan"`,
		"recreate -include job-name":     "-include takes pod keys",
		"recreate -include web/a/b":      "-include takes pod keys",
		"apply":                          `unknown command "apply"`,
		"":                               "usage:",
		"plan -cni flannel":              "-cni flannel is for verify only",
		"verify -cni0 auto":              "-cni0 is talos or none",
		"recreate -include web/a -bogus": "flag provided but not defined",
	} {
		_, err := parse(strings.Fields(args))
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q: got %v, want an error containing %q", args, err, want)
		}
	}
}

func TestVerifyTakesTheCNIItExpects(t *testing.T) {
	inv, err := parse([]string{"verify", "-cni", "flannel", "-cni0", "none"})
	if err != nil || inv.cni != "flannel" || inv.cni0 != "none" {
		t.Errorf("got %+v, %v", inv, err)
	}
}
