package lab

import (
	"image"
	"testing"
)

// Trimmed from a dump of the T3 home screen while it reports being offline.
const offlineHome = `<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" class="android.widget.FrameLayout" package="com.t3tools.t3code" content-desc="" bounds="[0,0][1080,2400]"><node index="0" text="" class="android.view.ViewGroup" content-desc="You are offline" bounds="[55,182][405,238]"><node index="0" text="You are offline" class="android.widget.TextView" content-desc="" bounds="[112,182][404,238]" /></node><node index="1" text="Chats" class="android.widget.TextView" content-desc="" bounds="[84,2253][171,2295]" /></node></hierarchy>`

func TestParseHierarchyFindsNestedLabels(t *testing.T) {
	nodes, err := ParseHierarchy([]byte(offlineHome))
	if err != nil {
		t.Fatal(err)
	}
	if len(nodes) != 4 {
		t.Fatalf("got %d nodes, want 4", len(nodes))
	}
	offline, ok := Find(nodes, Labelled("You are offline"))
	if !ok || offline.Bounds != image.Rect(55, 182, 405, 238) {
		t.Fatalf("offline header: got %+v, %v", offline, ok)
	}
	chats, ok := Find(nodes, Labelled("Chats"))
	if !ok || chats.Bounds != image.Rect(84, 2253, 171, 2295) {
		t.Fatalf("Chats tab: got %+v, %v", chats, ok)
	}
	if _, ok := Find(nodes, Labelled("Connected")); ok {
		t.Fatal("found a label that is not on screen")
	}
}

func TestParseHierarchyRejectsMalformedBounds(t *testing.T) {
	_, err := ParseHierarchy([]byte(`<hierarchy><node text="x" bounds="[1,2]" /></hierarchy>`))
	if err == nil {
		t.Fatal("accepted malformed bounds")
	}
}
