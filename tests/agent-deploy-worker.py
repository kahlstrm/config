import importlib.util
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


if __name__ == "__main__":
    unittest.main()
