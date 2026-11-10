// Package routeros arms a dead-man switch on a RouterOS router over its REST API before an
// apply: a backup of the configuration, and a one-shot scheduler job that loads it, which
// reboots the router into the configuration from before the apply. Disarm removes both once
// the apply's checks pass; if they fail, or nothing disarms it, the router restores itself.
package routeros

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// Name names the scheduler job and the backup, Name+".backup".
const Name = "ops-deadman"

const backupFile = Name + ".backup"

// Router is one router's REST API, at Base (https://host), as a user that may save and load
// backups and edit the scheduler.
type Router struct {
	Base     string
	User     string
	Password string
	Client   *http.Client
}

func (r *Router) call(ctx context.Context, method, path string, body, out any) error {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(data)
	}
	request, err := http.NewRequestWithContext(ctx, method, r.Base+"/rest"+path, reader)
	if err != nil {
		return err
	}
	request.SetBasicAuth(r.User, r.Password)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	client := r.Client
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return err
	}
	if response.StatusCode >= 300 {
		var failure struct{ Message, Detail string }
		_ = json.Unmarshal(data, &failure)
		return fmt.Errorf("%s %s: %s: %s %s", method, path, response.Status, failure.Message, failure.Detail)
	}
	if out != nil && len(data) > 0 {
		return json.Unmarshal(data, out)
	}
	return nil
}

type item map[string]string

func (r *Router) find(ctx context.Context, path, field, value string) ([]item, error) {
	var items []item
	err := r.call(ctx, http.MethodGet, path+"?"+url.Values{field: {value}}.Encode(), nil, &items)
	return items, err
}

func (r *Router) remove(ctx context.Context, path, field, value string) error {
	items, err := r.find(ctx, path, field, value)
	if err != nil {
		return err
	}
	for _, it := range items {
		if err := r.call(ctx, http.MethodDelete, path+"/"+it[".id"], nil, nil); err != nil {
			return err
		}
	}
	return nil
}

// Clock returns the router's wall-clock time, in which the scheduler runs.
func (r *Router) Clock(ctx context.Context) (time.Time, error) {
	var clock struct{ Date, Time string }
	if err := r.call(ctx, http.MethodGet, "/system/clock", nil, &clock); err != nil {
		return time.Time{}, err
	}
	return time.Parse("2006-01-02 15:04:05", clock.Date+" "+clock.Time)
}

// Pending reports whether a restore is scheduled.
func (r *Router) Pending(ctx context.Context) (bool, error) {
	jobs, err := r.find(ctx, "/system/scheduler", "name", Name)
	return len(jobs) > 0, err
}

// Restored reports whether a backup is left without its job: the router restored it, or a
// disarm stopped between the two deletions.
func (r *Router) Restored(ctx context.Context) (bool, error) {
	pending, err := r.Pending(ctx)
	if err != nil || pending {
		return false, err
	}
	files, err := r.find(ctx, "/file", "name", backupFile)
	return len(files) > 0, err
}

// Arm saves a backup and schedules its restore after delay, by the router's clock, and
// returns the router time it fires at. It refuses while a restore is already scheduled.
func (r *Router) Arm(ctx context.Context, delay time.Duration) (time.Time, error) {
	if pending, err := r.Pending(ctx); err != nil {
		return time.Time{}, err
	} else if pending {
		return time.Time{}, errors.New("a dead-man restore is already scheduled")
	}
	if err := r.remove(ctx, "/file", "name", backupFile); err != nil {
		return time.Time{}, err
	}
	if err := r.call(ctx, http.MethodPost, "/system/backup/save", map[string]string{"name": Name, "dont-encrypt": "yes"}, nil); err != nil {
		return time.Time{}, err
	}
	for attempt := 0; ; attempt++ {
		files, err := r.find(ctx, "/file", "name", backupFile)
		if err != nil {
			return time.Time{}, err
		}
		if len(files) > 0 {
			break
		}
		if attempt == 20 {
			return time.Time{}, errors.New("the backup did not appear")
		}
		select {
		case <-ctx.Done():
			return time.Time{}, ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	now, err := r.Clock(ctx)
	if err != nil {
		return time.Time{}, err
	}
	at := now.Add(delay).Truncate(time.Second)
	err = r.call(ctx, http.MethodPut, "/system/scheduler", map[string]string{
		"name":       Name,
		"start-date": at.Format("2006-01-02"),
		"start-time": at.Format("15:04:05"),
		"on-event":   `/system backup load name=` + backupFile + ` password=""`,
		"comment":    "ops runner: restore the configuration from before an apply unless its checks pass",
	}, nil)
	return at, err
}

// Disarm removes the scheduled restore, then the backup.
func (r *Router) Disarm(ctx context.Context) error {
	if err := r.remove(ctx, "/system/scheduler", "name", Name); err != nil {
		return err
	}
	return r.remove(ctx, "/file", "name", backupFile)
}

// Healthy checks what the apply must not break: the REST API answers this user, which is
// how ops manages the router, and an IPv4 default route is active, so the WAN is up.
func (r *Router) Healthy(ctx context.Context) error {
	var resource map[string]string
	if err := r.call(ctx, http.MethodGet, "/system/resource", nil, &resource); err != nil {
		return err
	}
	routes, err := r.find(ctx, "/ip/route", "dst-address", "0.0.0.0/0")
	if err != nil {
		return err
	}
	for _, route := range routes {
		if route["active"] == "true" {
			return nil
		}
	}
	return errors.New("no active IPv4 default route")
}
