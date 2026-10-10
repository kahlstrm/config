"""Apply a fixed NixOS configuration from the upstream main branch."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

STATE = Path("/nix/var/nix/profiles/agent-deploy")
BOOTED = Path("/run/booted-system")
CURRENT = Path("/run/current-system")
SYSTEM_PROFILE = Path("/nix/var/nix/profiles/system")


def run(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def set_profile(profile, system):
    run("nix-env", "--profile", str(profile), "--set", str(system))


def link(target, destination):
    temporary = destination.with_name(destination.name + ".new")
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target)
    temporary.replace(destination)


def status(state, **details):
    temporary = STATE / "status.new"
    temporary.write_text(json.dumps({"state": state, **details}) + "\n")
    temporary.replace(STATE / "status.json")


def compatible(system, baseline):
    for name in ("kernel", "initrd", "kernel-modules"):
        if (system / name).resolve() != (baseline / name).resolve():
            raise RuntimeError(
                f"{name} changed; an operator must deploy the VM boot image"
            )
    if (system / "agent-boot-parameters").read_bytes() != (
        baseline / "agent-boot-parameters"
    ).read_bytes():
        raise RuntimeError(
            "boot parameters changed; an operator must deploy the VM boot image"
        )


def restore():
    saved = STATE / "current"
    # A new operator-provided boot image takes precedence over saved userspace.
    if not saved.exists() or (STATE / "base").resolve() != BOOTED.resolve():
        return
    baseline = CURRENT.resolve()
    try:
        compatible(saved.resolve(), BOOTED.resolve())
        run(str(saved / "activate"))
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        run(str(baseline / "activate"))
        status("restore-failed", error=str(error))
        print(
            f"Saved environment failed; restored boot image: {error}", file=sys.stderr
        )


def deploy(settings):
    revision = None
    previous = CURRENT.resolve()
    native = settings["bootMode"] == "system"
    action = "switch" if native else "test"
    activated = False
    profile_changed = False
    try:
        status("building")
        repository = settings["repository"]
        remote = run(
            "git",
            "ls-remote",
            "--exit-code",
            f"https://github.com/{repository}.git",
            "refs/heads/main",
        ).split()
        if (
            len(remote) != 2
            or remote[1] != "refs/heads/main"
            or not re.fullmatch(r"[0-9a-f]{40}", remote[0])
        ):
            raise RuntimeError("Upstream main did not resolve to one commit")
        revision = remote[0]
        reference = (
            f"github:{repository}/{revision}#nixosConfigurations."
            f"{settings['configuration']}.config.system.build.toplevel"
        )
        output = run(
            "nix",
            "build",
            reference,
            "--out-link",
            str(STATE / "pending"),
            "--print-out-paths",
        )
        candidate = Path(output).resolve()
        if (
            candidate.parent != Path("/nix/store")
            or "\n" in output
            or candidate != (STATE / "pending").resolve()
        ):
            raise RuntimeError("Build did not produce a single pinned system closure")
        if not native:
            compatible(candidate, BOOTED.resolve())
        if native:
            set_profile(SYSTEM_PROFILE, candidate)
            profile_changed = True
        status("activating", revision=revision)
        activated = True
        subprocess.run(
            [str(candidate / "bin/switch-to-configuration"), action], check=True
        )
        set_profile(STATE / "current", candidate)
        link(BOOTED.resolve(), STATE / "base")
        status("succeeded", revision=revision, system=str(candidate))
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        if activated or profile_changed:
            try:
                if native:
                    set_profile(SYSTEM_PROFILE, previous)
                subprocess.run(
                    [str(previous / "bin/switch-to-configuration"), action], check=True
                )
                if (STATE / "current").exists():
                    set_profile(STATE / "current", previous)
            except (OSError, subprocess.CalledProcessError) as rollback_error:
                status(
                    "rollback-failed",
                    revision=revision,
                    error=str(error),
                    rollbackError=str(rollback_error),
                )
                raise
        status("failed", revision=revision, error=str(error))
        raise
    finally:
        (STATE / "pending").unlink(missing_ok=True)


def main():
    if os.geteuid() != 0:
        raise PermissionError("Deployment runner requires root")
    if len(sys.argv) != 3 or sys.argv[2] not in ("deploy", "restore"):
        raise ValueError("Expected fixed configuration and deploy or restore action")
    settings = json.loads(Path(sys.argv[1]).read_text())
    STATE.mkdir(mode=0o755, parents=True, exist_ok=True)
    if sys.argv[2] == "restore":
        restore()
    else:
        deploy(settings)


if __name__ == "__main__":
    main()
