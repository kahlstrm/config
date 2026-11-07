"""Build each agent VM's system from upstream main, so its guest downloads it from this host."""

import json
import re
import subprocess
import sys
from pathlib import Path


def run(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def upstream_main(repository):
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
        raise RuntimeError(f"Upstream main of {repository} did not resolve to one commit")
    return remote[0]


def warm(settings):
    """Build what changed; returns whether every system is built for upstream main."""
    state = Path(settings["state"])
    built = json.loads(state.read_text()) if state.exists() else {}
    revisions = {}
    succeeded = True
    for system in settings["systems"]:
        name, repository = system["name"], system["repository"]
        try:
            if repository not in revisions:
                revisions[repository] = upstream_main(repository)
            revision = revisions[repository]
            if built.get(name) == revision:
                continue
            # The same reference the guest's agent-deploy builds, so the output paths match.
            run(
                "nix",
                "build",
                f"github:{repository}/{revision}#nixosConfigurations."
                f"{system['configuration']}.config.system.build.toplevel",
                "--out-link",
                str(Path(settings["roots"]) / name),
                "--print-out-paths",
            )
        except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
            print(f"{name}: {error}", file=sys.stderr)
            succeeded = False
            continue
        built[name] = revision
        temporary = state.with_name(state.name + ".new")
        temporary.write_text(json.dumps(built) + "\n")
        temporary.replace(state)
        print(f"{name}: built {revision}")
    return succeeded


def main():
    settings = json.loads(Path(sys.argv[1]).read_text())
    sys.exit(0 if warm(settings) else 1)


if __name__ == "__main__":
    main()
