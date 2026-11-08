import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "warm", Path(__file__).parent.parent / "modules/agents/vm/cache-warm.py"
)
warm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(warm)

REVISION = "1" * 40


def reference(configuration, revision=REVISION):
    return (
        f"github:upstream/config/{revision}#nixosConfigurations."
        f"{configuration}.config.system.build.toplevel"
    )


class WarmBuild(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        directory = Path(self.temporary.name)
        self.settings = {
            "systems": [
                {"name": "ops", "repository": "upstream/config", "configuration": "ops"},
                {
                    "name": "agents",
                    "repository": "upstream/config",
                    "configuration": "agents",
                },
            ],
            "roots": str(directory / "roots"),
            "state": str(directory / "built.json"),
        }
        self.state = Path(self.settings["state"])
        self.calls = []
        self.failing = set()
        self.revision = REVISION

    def command(self, *arguments):
        self.calls.append(arguments)
        if arguments[0] == "git":
            return f"{self.revision}\trefs/heads/main"
        if arguments[:2] == ("nix", "build"):
            if any(name in arguments[2] for name in self.failing):
                raise subprocess.CalledProcessError(1, arguments)
            return "/nix/store/" + "s" * 32 + "-system"
        raise AssertionError(arguments)

    def warm(self):
        with patch.object(warm, "run", self.command):
            return warm.warm(self.settings)

    def builds(self):
        return [call for call in self.calls if call[:2] == ("nix", "build")]

    def test_builds_systems_in_order_into_gc_roots(self):
        self.assertTrue(self.warm())
        self.assertEqual(
            self.builds(),
            [
                (
                    "nix",
                    "build",
                    reference(name),
                    "--out-link",
                    str(Path(self.settings["roots"]) / name),
                    "--print-out-paths",
                )
                for name in ["ops", "agents"]
            ],
        )
        # One lookup serves both systems from the same repository.
        self.assertEqual(sum(call[0] == "git" for call in self.calls), 1)
        self.assertEqual(
            json.loads(self.state.read_text()), {"ops": REVISION, "agents": REVISION}
        )

    def test_skips_systems_already_built_for_upstream_main(self):
        self.warm()
        self.calls.clear()
        self.assertTrue(self.warm())
        self.assertEqual(self.builds(), [])

    def test_failed_build_is_retried_and_does_not_block_the_others(self):
        self.failing = {"ops"}
        self.assertFalse(self.warm())
        self.assertEqual(json.loads(self.state.read_text()), {"agents": REVISION})
        self.failing = set()
        self.calls.clear()
        self.assertTrue(self.warm())
        self.assertEqual(self.builds()[0][2], reference("ops"))
        self.assertEqual(len(self.builds()), 1)

    def test_new_upstream_revision_rebuilds(self):
        self.warm()
        self.calls.clear()
        self.revision = "2" * 40
        self.assertTrue(self.warm())
        self.assertEqual(
            [call[2] for call in self.builds()],
            [reference(name, self.revision) for name in ["ops", "agents"]],
        )

    def test_rejects_an_ambiguous_upstream_reference(self):
        self.revision = "not-a-commit"
        self.assertFalse(self.warm())
        self.assertEqual(self.builds(), [])


if __name__ == "__main__":
    unittest.main()
