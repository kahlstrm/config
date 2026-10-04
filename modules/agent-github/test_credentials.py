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
        self.assertEqual(body["permissions"], {"contents": "read", "pull_requests": "write", "checks": "read", "actions": "read", "statuses": "read"})

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
            self.assertEqual(json.loads(request.data), {"repositories": ["config"], "permissions": {"contents": "read", "pull_requests": "write", "checks": "read", "actions": "read", "statuses": "read"}})
            jwt_payload = sign.call_args.kwargs["input"].split(b".")[1]
            self.assertEqual(json.loads(base64.urlsafe_b64decode(jwt_payload + b"=" * (-len(jwt_payload) % 4))), {"iat": 940, "exp": 1540, "iss": "123"})
            self.assertEqual(sign.call_args.args[0][-1], "/run/agenix/pr-app")


class GhIntegrationTest(unittest.TestCase):
    setUp = CredentialRoutingTest.setUp
    def test_plain_gh_uses_upstream_for_prs_in_fork_checkout(self):
        with patch.object(credentials, "checkout_repository", return_value="kahlstrm-agents/config"), patch.object(credentials.os, "environ", {}):
            self.assertEqual(credentials.gh_repository(self.config, ["pr", "create"]), "kahlstrm/config")

    def test_explicit_repository_and_rest_endpoint_override_checkout(self):
        for command, expected in [
            (["pr", "view", "1", "-R", "kahlstrm/config"], "kahlstrm/config"),
            (["repo", "view", "kahlstrm-agents/config"], "kahlstrm-agents/config"),
            (["api", "repos/kahlstrm/config/pulls/1"], "kahlstrm/config"),
        ]:
            with self.subTest(command=command), patch.object(credentials, "checkout_repository", return_value=None), patch.object(credentials.os, "environ", {}):
                self.assertEqual(credentials.gh_repository(self.config, command), expected)

    def test_plain_gh_global_token_covers_only_configured_originals(self):
        self.config["repositories"].append("project")
        app, body = credentials.request_for(self.config, None, "pr")
        self.assertEqual(app, "upstream")
        self.assertEqual(body["repositories"], ["config", "project"])
        self.assertEqual(body["permissions"]["contents"], "read")

    def test_plain_gh_replaces_inherited_credentials_and_uses_absolute_binary(self):
        with patch.object(credentials, "gh_repository", return_value="kahlstrm/config"), patch.object(credentials, "mint", return_value="app-token"), patch.object(credentials.subprocess, "run") as run, patch.dict(credentials.os.environ, {"GH_TOKEN": "personal", "GITHUB_TOKEN": "personal"}):
            run.return_value.returncode = 0
            self.assertEqual(credentials.run_gh(self.config, "/store/gh", ["pr", "list"]), 0)
            self.assertEqual(run.call_args.args[0], ["/store/gh", "pr", "list"])
            env = run.call_args.kwargs["env"]
            self.assertEqual(env["GH_TOKEN"], "app-token")
            self.assertEqual(env["GH_REPO"], "kahlstrm/config")
            self.assertNotIn("GITHUB_TOKEN", env)

    def test_t3_auth_status_checks_real_installation_before_reporting_bot(self):
        with patch.object(credentials, "gh_repository", return_value=None), patch.object(credentials, "mint", return_value="app-token"), patch.object(credentials, "github_request") as api, patch.object(credentials, "app_login", return_value="agent-pr[bot]"), patch("sys.stdout", new_callable=io.StringIO) as output:
            api.return_value = {"repositories": []}
            self.assertEqual(credentials.run_gh(self.config, "/store/gh", ["auth", "status", "--json", "hosts"]), 0)
            api.assert_called_once_with("installation/repositories", "app-token")
            account = json.loads(output.getvalue())["hosts"]["github.com"][0]
            self.assertEqual(account["login"], "agent-pr[bot]")
            self.assertEqual(account["state"], "success")
            self.assertTrue(account["active"])

    def test_t3_viewer_request_uses_bot_profile_instead_of_user_endpoint(self):
        with patch.object(credentials, "gh_repository", return_value=None), patch.object(credentials, "mint", return_value="app-token"), patch.object(credentials, "app_login", return_value="agent-pr[bot]"), patch.object(credentials.subprocess, "run") as run:
            run.return_value.returncode = 0
            credentials.run_gh(self.config, "/store/gh", ["api", "user", "--jq", ".login"])
            self.assertEqual(run.call_args.args[0], ["/store/gh", "api", "users/agent-pr[bot]", "--jq", ".login"])

    def test_personal_login_and_non_github_hosts_are_rejected(self):
        for command in [["auth", "login"], ["api", "user", "--hostname", "evil.example"]]:
            with self.subTest(command=command), self.assertRaises(ValueError):
                credentials.run_gh(self.config, "/store/gh", command)

    def test_unconfigured_repository_cannot_receive_global_fallback_token(self):
        with patch.object(credentials, "checkout_repository", return_value="other/config"), patch.object(credentials.os, "environ", {}), self.assertRaises(ValueError):
            credentials.run_gh(self.config, "/store/gh", ["pr", "list"])

    def test_revoked_installation_does_not_report_authenticated(self):
        with patch.object(credentials, "gh_repository", return_value=None), patch.object(credentials, "mint", return_value="app-token"), patch.object(credentials, "github_request", side_effect=credentials.HTTPError("url", 401, "revoked", {}, None)), patch("sys.stdout", new_callable=io.StringIO) as output, self.assertRaises(credentials.HTTPError):
            credentials.run_gh(self.config, "/store/gh", ["auth", "status", "--json", "hosts"])
        self.assertEqual(output.getvalue(), "")

    def test_fork_rest_reads_use_fork_app_and_preserve_stdin_and_exit_code(self):
        with patch.object(credentials, "mint", return_value="fork-token") as mint, patch.object(credentials.subprocess, "run") as run:
            run.return_value.returncode = 7
            command = ["api", "repos/kahlstrm-agents/config/contents/README.md", "--input", "-"]
            self.assertEqual(credentials.run_gh(self.config, "/store/gh", command), 7)
            mint.assert_called_once_with(self.config, "kahlstrm-agents/config", "git")
            self.assertEqual(run.call_args.args[0], ["/store/gh", *command])
            self.assertNotIn("stdin", run.call_args.kwargs)

    def test_version_probe_does_not_require_credentials(self):
        with patch.object(credentials, "mint") as mint, patch.object(credentials.subprocess, "run") as run:
            run.return_value.returncode = 0
            credentials.run_gh(self.config, "/store/gh", ["--version"])
            mint.assert_not_called()

    def test_empty_repository_list_cannot_request_unscoped_token(self):
        self.config["repositories"] = []
        with self.assertRaises(ValueError):
            credentials.request_for(self.config, None, "pr")


if __name__ == "__main__":
    unittest.main()
