package main

import (
	"encoding/json"
	"fmt"
	"reflect"
	"regexp"
	"slices"
	"sort"
	"strings"
)

// The labels a PR carries to allow what the apply refuses by default.
const (
	labelDestroy = "networking:allow-destroy"
	labelAccess  = "networking:allow-access"
)

// change is one resource change of a plan, without values.
type change struct {
	Address    string
	Type       string
	Action     string // create, update, delete, replace
	Router     string // the RouterOS provider alias, or "" for other providers
	Attributes []string
}

// plan is what the summary and the guards need from `terraform show -json`. The JSON holds
// the configuration's and the state's values unmasked, so it is parsed in memory and never
// printed or stored.
type plan struct {
	Configuration struct {
		ProviderConfig map[string]struct {
			Name  string `json:"name"`
			Alias string `json:"alias"`
		} `json:"provider_config"`
		RootModule module `json:"root_module"`
	} `json:"configuration"`
	ResourceChanges []struct {
		Address       string `json:"address"`
		ModuleAddress string `json:"module_address"`
		Mode          string `json:"mode"`
		Type          string `json:"type"`
		Name          string `json:"name"`
		ProviderName  string `json:"provider_name"`
		Change        struct {
			Actions         []string        `json:"actions"`
			Before          json.RawMessage `json:"before"`
			After           json.RawMessage `json:"after"`
			AfterUnknown    json.RawMessage `json:"after_unknown"`
			BeforeSensitive json.RawMessage `json:"before_sensitive"`
			AfterSensitive  json.RawMessage `json:"after_sensitive"`
		} `json:"change"`
	} `json:"resource_changes"`
	OutputChanges map[string]struct {
		Actions []string `json:"actions"`
	} `json:"output_changes"`
}

type module struct {
	Resources []struct {
		Address           string `json:"address"`
		ProviderConfigKey string `json:"provider_config_key"`
	} `json:"resources"`
	ModuleCalls map[string]struct {
		Module module `json:"module"`
	} `json:"module_calls"`
}

var instanceKey = regexp.MustCompile(`\[[^\]]*\]`)

// providerKeys maps each configured resource, by its address without instance keys, to the
// provider configuration it uses.
func (m module) providerKeys(prefix string, keys map[string]string) {
	for _, r := range m.Resources {
		keys[prefix+r.Address] = r.ProviderConfigKey
	}
	for name, call := range m.ModuleCalls {
		call.Module.providerKeys(prefix+"module."+name+".", keys)
	}
}

func parsePlan(data []byte) ([]change, error) {
	var p plan
	err := json.Unmarshal(data, &p)
	if err != nil {
		return nil, fmt.Errorf("plan JSON: %w", err)
	}
	keys := map[string]string{}
	p.Configuration.RootModule.providerKeys("", keys)
	// A resource whose block or module was removed has no configuration naming its router,
	// so every router is armed for it.
	var aliases []string
	for _, provider := range p.Configuration.ProviderConfig {
		if provider.Name == "routeros" && provider.Alias != "" {
			aliases = append(aliases, provider.Alias)
		}
	}
	sort.Strings(aliases)
	var changes []change
	for _, rc := range p.ResourceChanges {
		actions := rc.Change.Actions
		if rc.Mode != "managed" || slices.Equal(actions, []string{"no-op"}) || slices.Equal(actions, []string{"read"}) {
			continue
		}
		c := change{Address: rc.Address, Type: rc.Type}
		if c.Action, err = action(rc.Address, actions); err != nil {
			return nil, err
		}
		if strings.HasSuffix(rc.ProviderName, "/routeros") {
			address := rc.Type + "." + rc.Name
			if rc.ModuleAddress != "" {
				address = instanceKey.ReplaceAllString(rc.ModuleAddress, "") + "." + address
			}
			key, ok := keys[address]
			if !ok && c.Action == "delete" && len(aliases) > 0 {
				c.Router = strings.Join(aliases, ",")
				changes = append(changes, c)
				continue
			}
			if !ok {
				return nil, fmt.Errorf("%s: not in the configuration", rc.Address)
			}
			if _, after, found := strings.Cut(key, ":"); found {
				key = after
			}
			c.Router = p.Configuration.ProviderConfig[key].Alias
			if c.Router == "" {
				return nil, fmt.Errorf("%s: uses RouterOS provider %q without an alias, so its router is unknown", rc.Address, key)
			}
		}
		if c.Action == "update" || c.Action == "replace" {
			c.Attributes = changedAttributes(rc.Change.Before, rc.Change.After, rc.Change.AfterUnknown, rc.Change.BeforeSensitive, rc.Change.AfterSensitive)
		}
		changes = append(changes, c)
	}
	for name, oc := range p.OutputChanges {
		if slices.Equal(oc.Actions, []string{"no-op"}) {
			continue
		}
		c := change{Address: "output." + name, Type: "output"}
		if c.Action, err = action(c.Address, oc.Actions); err != nil {
			return nil, err
		}
		changes = append(changes, c)
	}
	sort.SliceStable(changes, func(i, j int) bool { return changes[i].Address < changes[j].Address })
	return changes, nil
}

func action(address string, actions []string) (string, error) {
	switch {
	case slices.Contains(actions, "delete") && slices.Contains(actions, "create"):
		return "replace", nil
	case len(actions) == 1 && slices.Contains([]string{"create", "update", "delete"}, actions[0]):
		return actions[0], nil
	}
	return "", fmt.Errorf("%s: unknown actions %v", address, actions)
}

// changedAttributes names the top-level attributes whose value or sensitivity changes, or
// becomes known only after the apply; sensitive ones are marked, and no value is kept.
func changedAttributes(before, after, unknown, beforeSensitive, afterSensitive json.RawMessage) []string {
	object := func(raw json.RawMessage) map[string]any {
		var m map[string]any
		_ = json.Unmarshal(raw, &m)
		return m
	}
	b, a, u, bs, as := object(before), object(after), object(unknown), object(beforeSensitive), object(afterSensitive)
	names := map[string]bool{}
	for _, m := range []map[string]any{b, a, u} {
		for name := range m {
			names[name] = true
		}
	}
	var changed []string
	for name := range names {
		isUnknown := u[name] != nil && u[name] != false
		if !isUnknown && reflect.DeepEqual(b[name], a[name]) && reflect.DeepEqual(bs[name], as[name]) {
			continue
		}
		label := name
		if (bs[name] != nil && bs[name] != false) || (as[name] != nil && as[name] != false) {
			label += " (sensitive)"
		}
		if isUnknown {
			label += " (known after apply)"
		}
		changed = append(changed, label)
	}
	sort.Strings(changed)
	return changed
}

// refusals lists, per label, the changes the apply refuses unless the PR carries it.
func refusals(changes []change) map[string][]string {
	out := map[string][]string{}
	for _, c := range changes {
		if c.Type == "output" {
			continue
		}
		if c.Action == "delete" || c.Action == "replace" {
			out[labelDestroy] = append(out[labelDestroy], c.Address)
		}
		firewall := strings.HasPrefix(c.Type, "routeros_ip_firewall_") || strings.HasPrefix(c.Type, "routeros_ipv6_firewall_") ||
			(c.Type == "routeros_move_items" && strings.HasPrefix(c.Address, "module.bootstrap_"))
		if firewall || strings.HasPrefix(c.Address, "module.ops_kuberack.") {
			out[labelAccess] = append(out[labelAccess], c.Address)
		}
	}
	return out
}

// blocked returns the labels whose changes the PR's labels don't allow.
func blocked(changes []change, labels []string) []string {
	var missing []string
	for label := range refusals(changes) {
		if !slices.Contains(labels, label) {
			missing = append(missing, label)
		}
	}
	sort.Strings(missing)
	return missing
}

// summary renders the plan for the thread and the PR: actions, addresses, routers and the
// names of changed attributes, never values.
func summary(header string, changes []change, labels []string) string {
	var s strings.Builder
	s.WriteString(header)
	counts := map[string]int{}
	for _, c := range changes {
		counts[c.Action]++
	}
	fmt.Fprintf(&s, "\n%d to create, %d to update, %d to replace, %d to delete.\n", counts["create"], counts["update"], counts["replace"], counts["delete"])
	if len(changes) > 0 {
		s.WriteString("\n| Action | Resource | Router | Changed attributes |\n| --- | --- | --- | --- |\n")
		for _, c := range changes {
			router := c.Router
			if router == "" {
				router = "-"
			}
			fmt.Fprintf(&s, "| %s | `%s` | %s | %s |\n", c.Action, c.Address, router, strings.Join(c.Attributes, ", "))
		}
	}
	refused := refusals(changes)
	if len(refused) == 0 {
		s.WriteString("\nNo deletions, replacements, firewall or ops-user changes.\n")
	}
	for _, label := range []string{labelDestroy, labelAccess} {
		addresses := refused[label]
		if len(addresses) == 0 {
			continue
		}
		what := map[string]string{labelDestroy: "deletes or replaces resources", labelAccess: "changes the firewall or ops' own RouterOS user"}[label]
		state := "**Refused**: the PR lacks"
		if slices.Contains(labels, label) {
			state = "Allowed by"
		}
		fmt.Fprintf(&s, "\n%s the label `%s`; the plan %s: %s.\n", state, label, what, "`"+strings.Join(addresses, "`, `")+"`")
	}
	return s.String()
}

// routers counts each router's changes.
func routers(changes []change) map[string]int {
	out := map[string]int{}
	for _, c := range changes {
		if c.Router != "" {
			for _, router := range strings.Split(c.Router, ",") {
				out[router]++
			}
		}
	}
	return out
}
