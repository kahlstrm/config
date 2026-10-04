import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import io
import json
import base64

spec = importlib.util.spec_from_file_location("credentials", Path(__file__).with_name("credentials.py"))
credentials = importlib.util.module_from_spec(spec)
spec.loader.exec_module(credentials)


class CredentialRoutingTest(unittest.TestCase):
    def setUp(self):
        self.config = {
            "forkOwner": "kahlstrm-agents",
            "upstreamOwner": "kahlstrm",
            "repositories": ["config"],
            "apps": {"fork": {}, "upstream": {}},
        }

    def test_fork_push_uses_only_fork_app_contents_write(self):
        app, body = credentials.request_for(self.config, "kahlstrm-agents/config", "git")
        self.assertEqual(app, "fork")
        self.assertEqual(body, {"repositories": ["config"], "permissions": {"contents": "write"}})

    def test_original_git_auth_is_read_only(self):
        app, body = credentials.request_for(self.config, "kahlstrm/config", "git")
        self.assertEqual(app, "upstream")
        self.assertEqual(body["permissions"], {"contents": "read"})

    def test_pr_auth_cannot_write_original_contents(self):
        app, body = credentials.request_for(self.config, "kahlstrm/config", "pr")
        self.assertEqual(app, "upstream")
        self.assertEqual(body["permissions"], {"contents": "read", "pull_requests": "write"})

    def test_unlisted_repositories_and_owners_are_rejected(self):
        for repo in ["someone/config", "kahlstrm/other", "kahlstrm/config/extra", "config", "kahlstrm/../config"]:
            with self.subTest(repo=repo), self.assertRaises(ValueError):
                credentials.request_for(self.config, repo, "git")

    def test_pr_token_for_fork_is_rejected(self):
        with self.assertRaises(ValueError):
            credentials.request_for(self.config, "kahlstrm-agents/config", "pr")

    def test_git_protocol_host_and_path_are_checked(self):
        self.assertEqual(credentials.git_repository({"protocol": "https", "host": "github.com", "path": "kahlstrm/config.git"}), "kahlstrm/config")
        for fields in [{"protocol": "http", "host": "github.com", "path": "kahlstrm/config"}, {"protocol": "https", "host": "evil.example", "path": "kahlstrm/config"}, {"protocol": "https", "host": "github.com"}]:
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                credentials.git_repository(fields)

    def test_minted_token_is_repository_scoped_and_jwt_is_short_lived(self):
        self.config["apps"]["upstream"] = {"id": "123", "installationId": "456", "keyFile": "/run/agenix/pr-app"}
        response = io.BytesIO(b'{"token":"test-token"}')
        with patch.object(credentials.time, "time", return_value=1000), patch.object(credentials.subprocess, "run") as sign, patch.object(credentials, "urlopen") as send:
            sign.return_value.stdout = b"signature"
            send.return_value.__enter__.return_value = response
            self.assertEqual(credentials.mint(self.config, "kahlstrm/config", "pr"), "test-token")
            request = send.call_args.args[0]
            self.assertEqual(request.full_url, "https://api.github.com/app/installations/456/access_tokens")
            self.assertEqual(json.loads(request.data), {"repositories": ["config"], "permissions": {"contents": "read", "pull_requests": "write"}})
            jwt_payload = sign.call_args.kwargs["input"].split(b".")[1]
            self.assertEqual(json.loads(base64.urlsafe_b64decode(jwt_payload + b"=" * (-len(jwt_payload) % 4))), {"iat": 940, "exp": 1540, "iss": "123"})
            self.assertEqual(sign.call_args.args[0][-1], "/run/agenix/pr-app")


if __name__ == "__main__":
    unittest.main()
