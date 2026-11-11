package routeros

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fake keeps the state of the REST paths the switch uses.
type fake struct {
	mu        sync.Mutex
	clock     string
	files     map[string]item
	scheduler map[string]item
	routes    []item
	next      int
	saved     map[string]string
}

func newFake() *fake {
	return &fake{clock: "2026-11-10 23:58:30", files: map[string]item{}, scheduler: map[string]item{}, routes: []item{{"dst-address": "0.0.0.0/0", "active": "true"}}}
}

func (f *fake) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if user, password, ok := r.BasicAuth(); !ok || user != "admin" || password != "secret" {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/rest")
	list := func(items map[string]item) {
		out := []item{}
		for _, it := range items {
			if it["name"] == r.URL.Query().Get("name") {
				out = append(out, it)
			}
		}
		json.NewEncoder(w).Encode(out)
	}
	add := func(items map[string]item, it item) {
		f.next++
		it[".id"] = fmt.Sprintf("*%d", f.next)
		items[it[".id"]] = it
	}
	var body map[string]string
	if r.Body != nil {
		json.NewDecoder(r.Body).Decode(&body)
	}
	switch {
	case r.Method == http.MethodGet && path == "/system/clock":
		date, clock, _ := strings.Cut(f.clock, " ")
		json.NewEncoder(w).Encode(map[string]string{"date": date, "time": clock})
	case r.Method == http.MethodGet && path == "/system/resource":
		json.NewEncoder(w).Encode(map[string]string{"uptime": "1d"})
	case r.Method == http.MethodGet && path == "/ip/route":
		json.NewEncoder(w).Encode(f.routes)
	case r.Method == http.MethodGet && path == "/file":
		list(f.files)
	case r.Method == http.MethodGet && path == "/system/scheduler":
		list(f.scheduler)
	case r.Method == http.MethodPost && path == "/system/backup/save":
		f.saved = body
		add(f.files, item{"name": body["name"] + ".backup"})
	case r.Method == http.MethodPut && path == "/system/scheduler":
		add(f.scheduler, item(body))
	case r.Method == http.MethodDelete && strings.HasPrefix(path, "/file/"):
		delete(f.files, strings.TrimPrefix(path, "/file/"))
	case r.Method == http.MethodDelete && strings.HasPrefix(path, "/system/scheduler/"):
		delete(f.scheduler, strings.TrimPrefix(path, "/system/scheduler/"))
	default:
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"message": "Bad Request", "detail": "no such command"})
	}
}

func start(t *testing.T) (*fake, *Router) {
	f := newFake()
	server := httptest.NewServer(f)
	t.Cleanup(server.Close)
	return f, &Router{Base: server.URL, User: "admin", Password: "secret"}
}

func TestArmSchedulesRestoreAcrossMidnight(t *testing.T) {
	ctx := context.Background()
	f, r := start(t)
	at, err := r.Arm(ctx, 5*time.Minute+10*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if want := "2026-11-11 00:03:40"; at.Format("2006-01-02 15:04:05") != want {
		t.Fatalf("restore at %s, want %s", at, want)
	}
	if f.saved["dont-encrypt"] != "yes" || f.saved["name"] != Name {
		t.Fatalf("backup saved with %v", f.saved)
	}
	if len(f.scheduler) != 1 {
		t.Fatalf("scheduler: %v", f.scheduler)
	}
	for _, job := range f.scheduler {
		if job["start-date"] != "2026-11-11" || job["start-time"] != "00:03:40" || job["on-event"] != `/system backup load name=ops-deadman.backup password=""` {
			t.Fatalf("job: %v", job)
		}
	}
	if _, err := r.Arm(ctx, time.Minute); err == nil || !strings.Contains(err.Error(), "already scheduled") {
		t.Fatalf("second arm: %v", err)
	}
	if restored, err := r.Restored(ctx); err != nil || restored {
		t.Fatalf("restored while pending: %t %v", restored, err)
	}
	if err := r.Disarm(ctx); err != nil {
		t.Fatal(err)
	}
	if len(f.scheduler) != 0 || len(f.files) != 0 {
		t.Fatalf("left after disarm: %v %v", f.scheduler, f.files)
	}
}

func TestRestoredBackupIsReportedAndReplaced(t *testing.T) {
	ctx := context.Background()
	f, r := start(t)
	if _, err := r.Arm(ctx, time.Minute); err != nil {
		t.Fatal(err)
	}
	// The restore fired: the backup predates the job, so the job is gone and the file stays.
	clear(f.scheduler)
	if restored, err := r.Restored(ctx); err != nil || !restored {
		t.Fatalf("restored: %t %v", restored, err)
	}
	if _, err := r.Arm(ctx, time.Minute); err != nil {
		t.Fatal(err)
	}
	if len(f.files) != 1 {
		t.Fatalf("files after rearm: %v", f.files)
	}
}

func TestHealthyNeedsActiveDefaultRoute(t *testing.T) {
	ctx := context.Background()
	f, r := start(t)
	if err := r.Healthy(ctx); err != nil {
		t.Fatal(err)
	}
	f.routes = []item{{"dst-address": "0.0.0.0/0", "active": "false"}}
	if err := r.Healthy(ctx); err == nil {
		t.Fatal("healthy without an active default route")
	}
	r.Password = "wrong"
	if err := r.Healthy(ctx); err == nil || !strings.Contains(err.Error(), "401") {
		t.Fatalf("wrong password: %v", err)
	}
}
