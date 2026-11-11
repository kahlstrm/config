package main

import (
	"reflect"
	"strings"
	"testing"
)

// A plan shaped like `terraform show -json` of local-networking, with secret values in the
// configuration, state and changes that the summary must never contain.
const fixture = `{
  "prior_state": {"values": {"root_module": {"resources": [{"values": {"password": "PRIOR-SECRET"}}]}}},
  "configuration": {
    "provider_config": {
      "google": {"name": "google", "full_name": "registry.terraform.io/hashicorp/google"},
      "routeros.kuberack": {"name": "routeros", "alias": "kuberack", "expressions": {"password": {"constant_value": "PROVIDER-SECRET"}}},
      "routeros.stationary": {"name": "routeros", "alias": "stationary"}
    },
    "root_module": {
      "resources": [{"address": "google_secret_manager_secret.x", "provider_config_key": "google"}],
      "module_calls": {
        "kuberack": {"module": {
          "resources": [{"address": "routeros_ip_dhcp_server_lease.lease", "provider_config_key": "kuberack:routeros.kuberack"}],
          "module_calls": {"dns": {"module": {"resources": [{"address": "routeros_ip_dns_record.a", "provider_config_key": "routeros.kuberack"}]}}}
        }},
        "bootstrap_stationary": {"module": {"resources": [
          {"address": "routeros_ip_firewall_filter.ipv4_filter", "provider_config_key": "routeros.stationary"}
        ]}},
        "ops_kuberack": {"module": {"resources": [{"address": "routeros_system_user.ops", "provider_config_key": "routeros.kuberack"}]}}
      }
    }
  },
  "resource_changes": [
    {"address": "module.kuberack.routeros_ip_dhcp_server_lease.lease[\"nas\"]", "module_address": "module.kuberack", "mode": "managed",
     "type": "routeros_ip_dhcp_server_lease", "name": "lease", "provider_name": "registry.terraform.io/terraform-routeros/routeros",
     "change": {"actions": ["update"], "before": {"address": "10.10.10.5", "comment": "nas", "mac_address": "AA"},
       "after": {"address": "10.10.10.6", "comment": "nas", "mac_address": "AA"}, "after_unknown": {}, "before_sensitive": {}, "after_sensitive": {}}},
    {"address": "module.kuberack.module.dns[0].routeros_ip_dns_record.a", "module_address": "module.kuberack.module.dns[0]", "mode": "managed",
     "type": "routeros_ip_dns_record", "name": "a", "provider_name": "registry.terraform.io/terraform-routeros/routeros",
     "change": {"actions": ["create"], "before": null, "after": {"name": "x"}}},
    {"address": "module.bootstrap_stationary.routeros_ip_firewall_filter.ipv4_filter[\"drop\"]", "module_address": "module.bootstrap_stationary", "mode": "managed",
     "type": "routeros_ip_firewall_filter", "name": "ipv4_filter", "provider_name": "registry.terraform.io/terraform-routeros/routeros",
     "change": {"actions": ["delete", "create"], "before": {"action": "drop"}, "after": {"action": "accept"}, "after_unknown": {"id": true}}},
    {"address": "module.ops_kuberack.routeros_system_user.ops", "module_address": "module.ops_kuberack", "mode": "managed",
     "type": "routeros_system_user", "name": "ops", "provider_name": "registry.terraform.io/terraform-routeros/routeros",
     "change": {"actions": ["update"], "before": {"password": "OLD-SECRET", "group": "ops-poe"}, "after": {"password": "NEW-SECRET", "group": "ops-poe"},
       "before_sensitive": {"password": true}, "after_sensitive": {"password": true}}},
    {"address": "module.gone.routeros_system_script.x", "module_address": "module.gone", "mode": "managed",
     "type": "routeros_system_script", "name": "x", "provider_name": "registry.terraform.io/terraform-routeros/routeros",
     "change": {"actions": ["delete"], "before": {"source": "GONE-SECRET"}, "after": null}},
    {"address": "google_secret_manager_secret.x", "mode": "managed", "type": "google_secret_manager_secret", "name": "x",
     "provider_name": "registry.terraform.io/hashicorp/google", "change": {"actions": ["no-op"]}},
    {"address": "data.google_secret_manager_secret_version.v", "mode": "data", "type": "google_secret_manager_secret_version", "name": "v",
     "provider_name": "registry.terraform.io/hashicorp/google", "change": {"actions": ["read"], "after": {"secret_data": "DATA-SECRET"}}}
  ],
  "output_changes": {
    "ops_home_assistant_token": {"actions": ["update"], "before": "OLD-OUTPUT-SECRET", "after": "NEW-OUTPUT-SECRET"},
    "k8s_api_vip": {"actions": ["no-op"], "before": "10.10.10.10", "after": "10.10.10.10"}
  }
}`

func TestPlanSummaryAndRefusals(t *testing.T) {
	changes, err := parsePlan([]byte(fixture))
	if err != nil {
		t.Fatal(err)
	}
	want := []change{
		{Address: `module.bootstrap_stationary.routeros_ip_firewall_filter.ipv4_filter["drop"]`, Type: "routeros_ip_firewall_filter", Action: "replace", Router: "stationary", Attributes: []string{"action", "id (known after apply)"}},
		// Its block is gone, so every router is armed for it.
		{Address: `module.gone.routeros_system_script.x`, Type: "routeros_system_script", Action: "delete", Router: "kuberack,stationary"},
		{Address: `module.kuberack.module.dns[0].routeros_ip_dns_record.a`, Type: "routeros_ip_dns_record", Action: "create", Router: "kuberack"},
		{Address: `module.kuberack.routeros_ip_dhcp_server_lease.lease["nas"]`, Type: "routeros_ip_dhcp_server_lease", Action: "update", Router: "kuberack", Attributes: []string{"address"}},
		{Address: `module.ops_kuberack.routeros_system_user.ops`, Type: "routeros_system_user", Action: "update", Router: "kuberack", Attributes: []string{"password (sensitive)"}},
		{Address: `output.ops_home_assistant_token`, Type: "output", Action: "update"},
	}
	if !reflect.DeepEqual(changes, want) {
		t.Fatalf("changes:\n%#v\nwant:\n%#v", changes, want)
	}
	if got := routers(changes); !reflect.DeepEqual(got, map[string]int{"kuberack": 4, "stationary": 2}) {
		t.Fatalf("routers: %v", got)
	}
	if got := blocked(changes, nil); !reflect.DeepEqual(got, []string{labelAccess, labelDestroy}) {
		t.Fatalf("blocked without labels: %v", got)
	}
	if got := blocked(changes, []string{labelDestroy}); !reflect.DeepEqual(got, []string{labelAccess}) {
		t.Fatalf("blocked with the destroy label: %v", got)
	}
	if got := blocked([]change{changes[2], changes[3], changes[5]}, nil); got != nil {
		t.Fatalf("ordinary changes blocked: %v", got)
	}
	text := summary("# plan", changes, []string{labelDestroy})
	for _, secret := range []string{"SECRET", "10.10.10.6", "10.10.10.10", "accept"} {
		if strings.Contains(text, secret) {
			t.Fatalf("summary shows the value %q:\n%s", secret, text)
		}
	}
	for _, line := range []string{
		"1 to create, 3 to update, 1 to replace, 1 to delete.",
		"| update | `module.ops_kuberack.routeros_system_user.ops` | kuberack | password (sensitive) |",
		"Allowed by the label `networking:allow-destroy`",
		"**Refused**: the merged PRs lack the label `networking:allow-access`; the plan changes the firewall or ops' own RouterOS user: `module.bootstrap_stationary",
	} {
		if !strings.Contains(text, line) {
			t.Fatalf("summary lacks %q:\n%s", line, text)
		}
	}
}

func TestPlanRejectsRouterOSWithoutAlias(t *testing.T) {
	plan := `{"configuration": {"provider_config": {"routeros": {"name": "routeros"}},
	  "root_module": {"resources": [{"address": "routeros_system_script.x", "provider_config_key": "routeros"}]}},
	  "resource_changes": [{"address": "routeros_system_script.x", "mode": "managed", "type": "routeros_system_script", "name": "x",
	    "provider_name": "registry.terraform.io/terraform-routeros/routeros", "change": {"actions": ["create"]}}]}`
	if _, err := parsePlan([]byte(plan)); err == nil || !strings.Contains(err.Error(), "router is unknown") {
		t.Fatalf("err = %v", err)
	}
}
