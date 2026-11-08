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
    "deployment", Path(__file__).parent.parent / "modules/agents/environment/deploy.py"
)
deployment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deployment)


class DarwinDeployment(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name)
        self.candidate = Path("/nix/store/reviewed-darwin-system")
        self.previous = self.state / "previous"
        self.previous.mkdir()
        self.calls = []
        self.failure = False
        self.settings = {
            "repository": "upstream/config",
            "configuration": "agent-mac",
            "bootMode": "system",
            "platform": "darwin",
            "user": "agent",
        }
        (self.state / "current").symlink_to(self.previous)
        for name, value in {
            "STATE": self.state,
            "CURRENT": self.previous,
            "SYSTEM_PROFILE": self.state / "system",
        }.items():
            mock = patch.object(deployment, name, value)
            mock.start()
            self.addCleanup(mock.stop)

    def command(self, *arguments):
        self.calls.append(arguments)
        if arguments[0] == "git":
            return "1" * 40 + "\trefs/heads/main"
        if arguments[0] == "nix":
            (self.state / "pending").symlink_to(self.candidate)
            return str(self.candidate)
        if arguments[0] == "id":
            return "501"
        return ""

    def activate(self, arguments, **kwargs):
        self.calls.append(tuple(arguments))
        if self.failure and str(self.candidate) in arguments[-1]:
            raise subprocess.CalledProcessError(1, arguments)

    def test_builds_reviewed_main_and_activates_in_login_session(self):
        with (
            patch.object(deployment, "run", self.command),
            patch.object(deployment.subprocess, "run", self.activate),
        ):
            deployment.deploy(self.settings)
        build = next(call for call in self.calls if call[0] == "nix")
        self.assertEqual(
            build[2],
            "github:upstream/config/"
            + "1" * 40
            + "#darwinConfigurations.agent-mac.config.system.build.toplevel",
        )
        self.assertIn(
            ("/bin/launchctl", "asuser", "501", str(self.candidate / "activate")),
            self.calls,
        )
        self.assertFalse((self.state / "pending").exists())
        self.assertFalse((self.state / "base").exists())

    def test_failed_activation_restores_profile_and_previous_system(self):
        self.failure = True
        with (
            patch.object(deployment, "run", self.command),
            patch.object(deployment.subprocess, "run", self.activate),
            self.assertRaises(subprocess.CalledProcessError),
        ):
            deployment.deploy(self.settings)
        self.assertIn(
            (
                "nix-env",
                "--profile",
                str(self.state / "system"),
                "--set",
                str(self.previous),
            ),
            self.calls,
        )
        self.assertIn(
            ("/bin/launchctl", "asuser", "501", str(self.previous / "activate")),
            self.calls,
        )


class SubstitutedDeployment(unittest.TestCase):
    """An environment too small to build waits for its host's cache to hold the system."""

    substituter = "http://10.83.0.5:5000?trusted=true"
    system = "/nix/store/" + "s" * 32 + "-nixos-system-ops"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name)
        self.previous = self.state / "previous"
        self.previous.mkdir()
        self.calls = []
        # Each poll the cache does not yet hold the system advances this clock by the wait.
        self.clock = 0
        self.missing_polls = 0
        self.settings = {
            "repository": "upstream/config",
            "configuration": "ops",
            "bootMode": "system",
            "waitForSubstituter": self.substituter,
        }
        for name, value in {
            "STATE": self.state,
            "CURRENT": self.previous,
            "SYSTEM_PROFILE": self.state / "system",
        }.items():
            mock = patch.object(deployment, name, value)
            mock.start()
            self.addCleanup(mock.stop)
        for name, value in {
            "monotonic": lambda: self.clock,
            "sleep": self.sleep,
        }.items():
            mock = patch.object(deployment.time, name, value)
            mock.start()
            self.addCleanup(mock.stop)

    def sleep(self, seconds):
        self.clock += seconds

    def command(self, *arguments):
        self.calls.append(arguments)
        if arguments[0] == "git":
            return "1" * 40 + "\trefs/heads/main"
        if arguments[:2] == ("nix", "eval"):
            return self.system
        if arguments[:2] == ("nix", "path-info"):
            if self.missing_polls > 0:
                self.missing_polls -= 1
                raise subprocess.CalledProcessError(1, arguments)
            return self.system
        if arguments[:2] == ("nix", "build"):
            (self.state / "pending").symlink_to(self.system)
            return self.system
        return ""

    def deploy(self):
        with (
            patch.object(deployment, "run", self.command),
            patch.object(deployment.subprocess, "run", lambda *_, **__: None),
        ):
            deployment.deploy(self.settings)

    def test_builds_only_after_the_substituter_holds_the_system(self):
        self.missing_polls = 3
        self.deploy()
        reference = (
            "github:upstream/config/"
            + "1" * 40
            + "#nixosConfigurations.ops.config.system.build.toplevel"
        )
        self.assertIn(("nix", "eval", "--raw", reference + ".outPath"), self.calls)
        polls = [call for call in self.calls if call[:2] == ("nix", "path-info")]
        self.assertEqual(len(polls), 4)
        self.assertEqual(
            polls[-1],
            (
                "nix",
                "path-info",
                "--option",
                "narinfo-cache-negative-ttl",
                "0",
                "--store",
                self.substituter,
                self.system,
            ),
        )
        last_poll = self.calls.index(polls[-1])
        build = next(i for i, call in enumerate(self.calls) if call[:2] == ("nix", "build"))
        self.assertLess(last_poll, build)
        # Download only: even derivations that never substitute, such as the toplevel.
        self.assertEqual(
            self.calls[build][-5:],
            ("--option", "always-allow-substitutes", "true", "--max-jobs", "0"),
        )
        status = json.loads((self.state / "status.json").read_text())
        self.assertEqual(status["state"], "succeeded")

    def test_gives_up_without_building_when_the_substituter_never_holds_it(self):
        self.missing_polls = 10**6
        with self.assertRaisesRegex(RuntimeError, "rerun agent-deploy"):
            self.deploy()
        self.assertFalse(any(call[:2] == ("nix", "build") for call in self.calls))
        self.assertGreaterEqual(self.clock, deployment.SUBSTITUTE_WAIT_SECONDS)
        status = json.loads((self.state / "status.json").read_text())
        self.assertEqual(status["state"], "failed")
        self.assertIn(self.substituter, status["error"])

    def test_builds_directly_without_a_substituter_to_wait_for(self):
        del self.settings["waitForSubstituter"]
        self.deploy()
        self.assertFalse(
            any(call[:2] in (("nix", "eval"), ("nix", "path-info")) for call in self.calls)
        )
        build = next(call for call in self.calls if call[:2] == ("nix", "build"))
        self.assertNotIn("--max-jobs", build)


if __name__ == "__main__":
    unittest.main()
