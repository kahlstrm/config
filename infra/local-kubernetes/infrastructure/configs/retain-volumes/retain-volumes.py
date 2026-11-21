#!/usr/bin/env python3
"""Set every PersistentVolume's reclaim policy to Retain.

local-storage provisions new volumes with Retain. This covers the volumes it
provisioned before, and any other class, so deleting a claim never deletes the
data behind it.

katalyst-threads is the one exception: the Katalyst control plane owns those
thread disks and deletes their claims when it drops them, and a thread's context
lives in the bucket, so their volumes keep Delete and free their space.
"""

import json
import ssl
import urllib.request

API = "https://kubernetes.default.svc"
EXEMPT_CLASSES = {"katalyst-threads"}
ACCOUNT = "/var/run/secrets/kubernetes.io/serviceaccount"

with open(f"{ACCOUNT}/token") as file:
    TOKEN = file.read().strip()
CONTEXT = ssl.create_default_context(cafile=f"{ACCOUNT}/ca.crt")


def request(method, path, body=None):
    call = urllib.request.Request(
        API + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/merge-patch+json"},
    )
    with urllib.request.urlopen(call, context=CONTEXT, timeout=30) as response:
        return json.load(response)


for volume in request("GET", "/api/v1/persistentvolumes")["items"]:
    name = volume["metadata"]["name"]
    policy = volume["spec"].get("persistentVolumeReclaimPolicy")
    if volume["spec"].get("storageClassName") in EXEMPT_CLASSES:
        continue
    if policy != "Retain":
        request("PATCH", f"/api/v1/persistentvolumes/{name}", {"spec": {"persistentVolumeReclaimPolicy": "Retain"}})
        print(f"{name}: {policy} -> Retain")
print(f"Every PersistentVolume outside {sorted(EXEMPT_CLASSES)} is Retain.")
