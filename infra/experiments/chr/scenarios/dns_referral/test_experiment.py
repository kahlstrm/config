from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from lab import Lab
from scenarios.dns_referral import experiment


class ExperimentTest(unittest.TestCase):
    def test_stopped_lab_starts_before_forwarding_and_completes_queries(self):
        with TemporaryDirectory() as directory:
            lab = Lab.__new__(Lab)
            lab.directory = Path(directory)
            lab.ssh_port = 2222
            lab.running = Mock(return_value=False)
            lab.start = Mock(
                side_effect=lambda: setattr(lab.running, "return_value", True)
            )

            def monitor(command):
                if not lab.running():
                    raise RuntimeError("Lab is stopped; run start first")
                return ""

            lab.monitor = Mock(side_effect=monitor)
            lab.ssh = Mock(return_value="router settings")
            reply = SimpleNamespace(stdout="status: NOERROR\nANSWER: 0, AUTHORITY: 0")
            with patch("scenarios.dns_referral.run", return_value=reply) as query:
                with redirect_stdout(StringIO()):
                    result = experiment(lab)

            lab.start.assert_called_once_with()
            self.assertEqual(
                [call.args[5] for call in query.call_args_list],
                ["AAAA", "NS", "AAAA"],
            )
            self.assertIn(
                "Referral-shaped response change reproduced: False",
                (result / "summary.txt").read_text(),
            )
            self.assertEqual(lab.monitor.call_count, 4)
