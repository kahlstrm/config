package lab

import (
	"strings"
	"testing"
)

func TestOverrideConfigReplacesSpacedKeys(t *testing.T) {
	// avdmanager writes "key = value"; the emulator honours the first of duplicate keys.
	current := "hw.lcd.density = 320\ndisk.dataPartition.size = 6442450944\nimage.sysdir.1 = system-images/x/\n"
	got := overrideConfig(current, map[string]string{"hw.lcd.density": "420", "disk.dataPartition.size": "3G"})
	for _, want := range []string{"hw.lcd.density=420", "disk.dataPartition.size=3G", "image.sysdir.1 = system-images/x/"} {
		if strings.Count(got, want) != 1 {
			t.Errorf("want one %q in:\n%s", want, got)
		}
	}
	for _, stale := range []string{"320", "6442450944"} {
		if strings.Contains(got, stale) {
			t.Errorf("kept stale %q in:\n%s", stale, got)
		}
	}
}
