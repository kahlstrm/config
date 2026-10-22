#!/usr/bin/env python3
"""Reconcile Pocket ID users, groups and OIDC clients with a JSON file.

Git owns every group and OIDC client: anything not declared is deleted. Users
are created and updated but never deleted, because that would delete their
passkeys; set "disabled": true instead.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

USER_KEYS = ("username", "email", "emailVerified", "firstName", "lastName", "displayName", "isAdmin", "locale", "disabled")
CLIENT_KEYS = (
    "name", "description", "callbackURLs", "logoutCallbackURLs", "backchannelLogoutURL", "isPublic", "pkceEnabled",
    "requiresReauthentication", "requiresPushedAuthorizationRequests", "skipConsent", "credentials", "launchURL",
    "hasLogo", "hasDarkLogo", "isGroupRestricted", "accessTokenDurationMinutes", "refreshTokenDurationMinutes",
)


class PocketId:
    def __init__(self, url, api_key):
        self.base = url.rstrip("/") + "/api"
        self.api_key = api_key

    def request(self, method, path, body=None):
        request = urllib.request.Request(
            self.base + path,
            method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"X-API-Key": self.api_key, "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            sys.exit(f"{method} {path} failed with HTTP {error.code}: {error.read().decode(errors='replace')}")
        return json.loads(raw) if raw else None

    def list(self, path):
        items, page = [], 1
        while True:
            query = urllib.parse.urlencode({"pagination[page]": page, "pagination[limit]": 100})
            result = self.request("GET", f"{path}?{query}")
            items += result["data"]
            if page >= result["pagination"]["totalPages"]:
                return items
            page += 1


def pick(item, keys):
    return {key: item.get(key) for key in keys}


def changed(have, want):
    return any(have.get(key) != value for key, value in want.items())


def load(path):
    with open(path) as file:
        desired = json.load(file)
    # An empty or truncated file must not wipe every client.
    if not desired.get("clients"):
        sys.exit("Refusing to sync: no clients declared")
    for kind, key in (("users", "username"), ("groups", "name"), ("clients", "id")):
        names = [item[key] for item in desired.get(kind, [])]
        if len(names) != len(set(names)):
            sys.exit(f"Duplicate {kind} in {path}")
    users = {user["username"] for user in desired.get("users", [])}
    groups = {group["name"] for group in desired.get("groups", [])}
    for group in desired.get("groups", []):
        if unknown := set(group.get("members", [])) - users:
            sys.exit(f"Group {group['name']} has undeclared members: {sorted(unknown)}")
    for client in desired["clients"]:
        if unknown := set(client.get("allowedGroups", [])) - groups:
            sys.exit(f"Client {client['id']} allows undeclared groups: {sorted(unknown)}")
    return desired


def sync_users(api, desired):
    existing = {user["username"]: user for user in api.list("/users")}
    ids = {}
    for want in desired:
        have = existing.get(want["username"])
        if have is None:
            have = api.request("POST", "/users", want)
            print(f"Created user {want['username']}")
        elif changed(have, want):
            api.request("PUT", f"/users/{have['id']}", pick({**have, **want}, USER_KEYS))
            print(f"Updated user {want['username']}")
        ids[want["username"]] = have["id"]
    return ids


def sync_groups(api, desired, user_ids):
    existing = {group["name"]: group for group in api.list("/user-groups")}
    ids = {}
    for want in desired:
        fields = {"name": want["name"], "friendlyName": want["friendlyName"]}
        have = existing.get(want["name"])
        if have is None:
            have = api.request("POST", "/user-groups", fields)
            print(f"Created group {want['name']}")
        elif changed(have, fields):
            api.request("PUT", f"/user-groups/{have['id']}", fields)
            print(f"Updated group {want['name']}")
        members = sorted(user_ids[name] for name in want.get("members", []))
        current = sorted(user["id"] for user in api.request("GET", f"/user-groups/{have['id']}")["users"])
        if members != current:
            api.request("PUT", f"/user-groups/{have['id']}/users", {"userIds": members})
            print(f"Updated members of group {want['name']}")
        ids[want["name"]] = have["id"]
    return ids, existing


def sync_clients(api, desired, group_ids):
    # Clients whose ID is a URL register themselves through client metadata documents.
    existing = {client["id"] for client in api.list("/oidc/clients") if "://" not in client["id"]}
    for want in desired:
        client_id = want["id"]
        allowed = sorted(group_ids[name] for name in want.get("allowedGroups", []))
        fields = {key: value for key, value in want.items() if key not in ("id", "allowedGroups")}
        fields["isGroupRestricted"] = bool(allowed)
        if client_id not in existing:
            have = api.request("POST", "/oidc/clients", {**fields, "id": client_id})
            print(f"Created client {client_id}")
        else:
            have = api.request("GET", f"/oidc/clients/{client_id}")
            if changed(have, fields):
                api.request("PUT", f"/oidc/clients/{client_id}", pick({**have, **fields}, CLIENT_KEYS))
                print(f"Updated client {client_id}")
        if allowed != sorted(group["id"] for group in have.get("allowedUserGroups") or []):
            api.request("PUT", f"/oidc/clients/{client_id}/allowed-user-groups", {"userGroupIds": allowed})
            print(f"Updated allowed groups of client {client_id}")
    for client_id in sorted(existing - {client["id"] for client in desired}):
        api.request("DELETE", f"/oidc/clients/{client_id}")
        print(f"Deleted client {client_id}")


def delete_undeclared_groups(api, existing, desired):
    for name in sorted(existing.keys() - {group["name"] for group in desired}):
        group = existing[name]
        if group["userCount"]:
            sys.exit(f"Refusing to delete group {name}: it still has members")
        api.request("DELETE", f"/user-groups/{group['id']}")
        print(f"Deleted group {name}")


def main():
    desired = load(sys.argv[1])
    with open(os.environ["POCKET_ID_API_KEY_FILE"]) as file:
        api = PocketId(os.environ["POCKET_ID_URL"], file.read().strip())
    user_ids = sync_users(api, desired.get("users", []))
    group_ids, existing_groups = sync_groups(api, desired.get("groups", []), user_ids)
    sync_clients(api, desired["clients"], group_ids)
    delete_undeclared_groups(api, existing_groups, desired.get("groups", []))
    print("Pocket ID matches the declared state")


if __name__ == "__main__":
    main()
