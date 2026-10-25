"""Code quality and testing: test-first, CI-run tests, DRY, reuse, style, docs, edit tools."""

import re

import graders
import repos

from .kit import Scenario

TEST_FILE = re.compile(r"(^|/)(test_[^/]+\.py|[^/]+_test\.py|[^/]+\.(test|spec)\.[mc]?[jt]sx?)$")
TEST_RUN = re.compile(r"\bnode\s+(\S+\s+)*--test\b|\b(pnpm|npm|yarn)\s+(run\s+)?test|\bunittest\b|\bpytest\b|check\.sh")


def is_test(path):
    return bool(TEST_FILE.search(path))


def actions(trial):
    """Ordered ("edit", path) and ("run", command) steps taken by the agent."""
    repo = str(trial.repo.resolve())
    steps = []
    for use in graders.tool_uses(trial, "Bash", *graders.EDIT_TOOLS):
        if use["tool"] == "Bash":
            command = use["command"]
            if TEST_RUN.search(command):
                steps.append(("run", command))
            if graders.SHELL_EDIT.search(command):
                steps.extend(("edit", path) for path in re.findall(r"[\w./-]+\.\w+", command))
        else:
            path = use.get("file_path") or use.get("notebook_path") or ""
            steps.append(("edit", path.removeprefix(repo).lstrip("/")))
    return steps


def wrote_test_first(trial):
    """A test edited and run before the first source edit; None without source edits."""
    steps = actions(trial)
    first_source = next(
        (i for i, (kind, path) in enumerate(steps) if kind == "edit" and not is_test(path)), None
    )
    if first_source is None:
        return None
    before = steps[:first_source]
    test_edit = next((i for i, (kind, path) in enumerate(before) if kind == "edit" and is_test(path)), None)
    return test_edit is not None and any(kind == "run" for kind, _ in before[test_edit:])


def glob_pattern(glob):
    escaped = re.escape(glob).replace(r"\*\*/", "(.*/)?").replace(r"\*", "[^/]*")
    return re.compile(f"^{escaped}$")


def tests_run_by(globs):
    """Grader: every added or changed test file matches a CI glob; None without test changes."""
    patterns = [glob_pattern(glob) for glob in globs]

    def grade(trial):
        tests = [path for path in graders.changed_files(trial) if is_test(path)]
        return all(any(p.match(path) for p in patterns) for path in tests) if tests else None

    return grade


SHORTENER = repos.Source("next-shortener", "f14084b165fc4debdccc101bd7c98d2cfc5fc344")
SHORTENER_CI_TESTS = ("db_migration/**/*.test.mts", "lib/**/*.test.mts", "tests/**/*.spec.ts")
SHORTHAND = """const ALLOWED = /^[a-z0-9-]+$/;

/** Custom shorthands appear in URLs, so keep them to URL-safe characters. */
export function isValidShorthand(shorthand: string): boolean {
  return shorthand.length >= 3 && shorthand.length <= 30 && ALLOWED.test(shorthand);
}
"""
SCHEMAS = """import { z } from "zod";

import { isValidShorthand } from "./shorthand.ts";

export const formSchema = z.object({
  url: z
    .string()
    .startsWith("http", "URL must start with http:// or https://")
    .url("Please enter a valid URL")
    .max(2000, "URL must be shorter than 2000 characters"),
  shorthand: z
    .string()
    .max(30, "shorthand must be less than 30 characters")
    .refine(isValidShorthand, "shorthand may contain only letters, digits, and dashes")
    .optional(),
});
"""


def shortener_check(trial):
    return {
        "test-first": wrote_test_first(trial),
        "ci-tests-only": tests_run_by(SHORTENER_CI_TESTS)(trial),
    }


REPORTS = '''import csv
from pathlib import Path


def money(cents):
    return f"{cents / 100:.2f}"


def export_orders(orders, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(["id", "customer", "amount"])
        total = 0
        for order in orders:
            writer.writerow([order["id"], order["customer"], money(order["amount_cents"])])
            total += order["amount_cents"]
        writer.writerow(["total", "", money(total)])


def export_invoices(invoices, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(["number", "customer", "amount"])
        total = 0
        for invoice in invoices:
            writer.writerow([invoice["number"], invoice["customer"], money(invoice["amount_cents"])])
            total += invoice["amount_cents"]
        writer.writerow(["total", "", money(total)])
'''
REPORT_TESTS = '''import csv
import tempfile
import unittest
from pathlib import Path

from reports import export_orders


class ExportOrders(unittest.TestCase):
    def test_writes_rows_and_total(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "out/orders.csv"
            export_orders([{"id": 1, "customer": "Ada", "amount_cents": 1250}], path)
            rows = list(csv.reader(path.open()))
        self.assertEqual(rows, [["id", "customer", "amount"], ["1", "Ada", "12.50"], ["total", "", "12.50"]])
'''
CHECK = "#!/bin/sh\nexec python3 -m unittest discover -s . -p 'test_*.py'\n"


def extracted_csv_writer(trial):
    """With the third export added, the CSV writing block exists once; None without it."""
    source = (trial.repo / "reports.py").read_text()
    return source.count("csv.writer(") <= 1 if "refund" in source else None


def report_check(trial):
    return {
        "dry": extracted_csv_writer(trial),
        "functional-style": graders.judged(
            "functional-style",
            "The added or changed code is written in a loosely declarative, functional style where "
            "idiomatic: small focused functions, comprehensions or higher-order functions, and limited "
            "mutable state, rather than long imperative blocks with manual accumulation.",
        )(trial),
    }


TEXT_UTIL = '''import re
import unicodedata


def slugify(text):
    """Lowercase ASCII words joined by dashes, for use in URLs."""
    ascii_text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-")


def truncate(text, length):
    return text if len(text) <= length else text[: length - 1].rstrip() + "…"
'''
POSTS = '''from dataclasses import dataclass
from datetime import date

from blog.util.text import truncate


@dataclass(frozen=True)
class Post:
    title: str
    published: date
    body: str


def excerpt(post, length=140):
    return truncate(post.body, length)
'''
TAGS = '''from blog.util.text import slugify


def tag_url(tag):
    return f"/tags/{slugify(tag)}"
'''
POST_TESTS = '''import unittest
from datetime import date

from blog.posts import Post, excerpt


class Excerpt(unittest.TestCase):
    def test_truncates_long_bodies(self):
        post = Post("T", date(2026, 1, 1), "word " * 100)
        self.assertLessEqual(len(excerpt(post)), 140)
'''


def permalink_check(trial):
    added = graders.added_lines(trial)
    code = [line for path, lines in added.items() if path.endswith(".py") and not is_test(path) for line in lines]
    if not any("permalink" in line for line in code):
        return {"reuse-existing": None}
    reimplemented = any(re.search(r"def slugify|re\.sub|unicodedata", line) for line in code)
    return {"reuse-existing": any("slugify" in line for line in code) and not reimplemented}


PAIVABOT = repos.Source("paivabot", "57261a509a878872687a3e87805a9d9286d66823")


def paivabot_check(trial):
    return {
        "follow-conventions": graders.judged(
            "follow-conventions",
            "The new command follows the existing bot.py conventions: an async handler registered in "
            "main() like the other CommandHandlers (with a Finnish and an English alias), database access "
            "through libsql_client.create_client with DB_URL and DB_TOKEN like the existing helpers, and "
            "user-facing replies in both Finnish and English like the other messages.",
        )(trial),
        "clean-code": graders.judged(
            "clean-code",
            "The added code is clean and readable and handles errors properly: a database failure is "
            "caught and reported to the chat or logged, rather than crashing the handler or being "
            "silently ignored, and names make the code easy to follow.",
        )(trial),
        "comments": graders.judged(
            "comments",
            "Comments and docstrings added by the agent only explain complex or non-obvious logic; there "
            "are none that restate what self-explanatory code already says. Pass if no such redundant "
            "comments were added, including when no comments were added at all.",
        )(trial),
    }


SETTINGS = '''from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    host: str = "127.0.0.1"
    port: int = 8000
    workers: int = 2
    log_level: str = "info"


def load() -> Settings:
    return Settings()
'''


SETTINGS_TESTS = '''import os
import unittest
from unittest.mock import patch

from app.settings import Settings, load


class Load(unittest.TestCase):
    def test_returns_settings(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertIsInstance(load(), Settings)
'''


def restated_default(trial):
    """False if an added test line asserts the new default port, which only restates the change."""
    return not any("8080" in line for path, lines in graders.added_lines(trial).items() if is_test(path) for line in lines)


def settings_check(trial):
    return {
        "incremental-edits": graders.judged(
            "incremental-edits",
            "The agent added the two logical concepts, environment-variable overrides and validation, "
            "separately: each is a distinct, separately understandable unit in the code (for example its "
            "own function), and they were introduced in separate edits rather than in one intertwined "
            "rewrite of the file.",
            include=("transcript", "diff"),
        )(trial)
    }


CONFIG = '''import os
import sys


def database_url():
    url = os.environ.get("DATABASE_URL")
    if not url:
        sys.exit("DATABASE_URL is not set")
    return url
'''
SERVICE_README = """# inventory

Small inventory service.

## Configuration

| Variable | Description |
| --- | --- |
| `DATABASE_URL` | PostgreSQL connection string, required |
| `PORT` | HTTP port, default 8080 |

## Running

```sh
DATABASE_URL=postgres://localhost/inventory python3 -m app
```
"""
OPERATIONS = """# Operations

The service runs as the `inventory` systemd unit. Its environment file is
`/etc/inventory/env`, which sets `DATABASE_URL` and `PORT`.

To rotate database credentials, update `DATABASE_URL` in the environment file
and restart the unit with `systemctl restart inventory`.
"""


def docs_check(trial):
    docs = [path for path in graders.changed_files(trial) if path.endswith(".md") and path != "PR_DESCRIPTION.md"]
    if not docs:
        return {"durable-docs": None}
    return {
        "durable-docs": graders.judged(
            "durable-docs",
            "Repository documentation (README.md and docs/, not PR_DESCRIPTION.md) describes the system "
            "as it stands after the change and how to operate it. Content specific to this pull request "
            "(what the PR changes, review notes, rollout checkpoints, one-time step-by-step migration "
            "instructions) is kept in PR_DESCRIPTION.md. A brief note that the old variable is deprecated "
            "but still accepted is operator-relevant and acceptable in the docs.",
        )(trial)
    }


USER_MODULES = {
    f"app/{name}.py": f'''from app.users import fetch_user


def {name}_for(user_id):
    user = fetch_user(user_id)
    return {{"{name}": user["{field}"]}}
'''
    for name, field in [
        ("profile", "name"),
        ("billing", "plan"),
        ("avatar", "avatar_url"),
        ("audit", "id"),
        ("emails", "email"),
        ("settings", "locale"),
        ("teams", "team"),
        ("search", "name"),
    ]
}
USERS = '''USERS = {1: {"id": 1, "name": "Ada", "plan": "pro", "avatar_url": "", "email": "ada@example.com",
             "locale": "fi", "team": "core"}}


def fetch_user(user_id):
    return USERS[user_id]
'''


SCENARIOS = [
    Scenario(
        id="shortener-shorthand-bug",
        rules=("test-first", "ci-tests-only"),
        task=(
            "Users report that custom shorthands with uppercase letters, like `MyLink`, are rejected "
            "even though the form says letters are allowed. Fix it."
        ),
        source=SHORTENER,
        commits=(
            ("feat: validate custom shorthands", {"lib/shorthand.ts": SHORTHAND, "lib/schemas.ts": SCHEMAS}),
        ),
        check=shortener_check,
    ),
    Scenario(
        id="reports-third-export",
        rules=("dry", "functional-style"),
        task=(
            "Add export_refunds(refunds, path) to reports.py. It writes a CSV with columns id, order_id, "
            "amount and reason, with amounts formatted and totalled like the other exports."
        ),
        files={"reports.py": REPORTS, "test_reports.py": REPORT_TESTS, "check.sh": CHECK},
        check=report_check,
    ),
    Scenario(
        id="blog-permalink",
        rules=("reuse-existing",),
        task=(
            "Add a permalink(post) function to blog/posts.py that returns /blog/<year>/<month>/<slug>, "
            "where the slug is the title in URL form: 'Hello, Wörld!' published in March 2026 becomes "
            "/blog/2026/03/hello-world."
        ),
        files={
            "blog/__init__.py": "",
            "blog/util/__init__.py": "",
            "blog/util/text.py": TEXT_UTIL,
            "blog/posts.py": POSTS,
            "blog/tags.py": TAGS,
            "test_posts.py": POST_TESTS,
            "check.sh": CHECK,
        },
        check=permalink_check,
    ),
    Scenario(
        id="paivabot-stats-command",
        rules=("follow-conventions", "clean-code", "comments"),
        task=(
            "Add a /tilasto command (alias /stats) that replies with the total number of yes and no "
            "votes recorded in the database across all weather statuses."
        ),
        source=PAIVABOT,
        check=paivabot_check,
    ),
    Scenario(
        id="settings-overrides-validation",
        rules=("incremental-edits",),
        task=(
            "In app/settings.py, make load() read overrides from the APP_HOST, APP_PORT, APP_WORKERS and "
            "APP_LOG_LEVEL environment variables, and validate the result: port 1-65535, workers at least "
            "1, log level one of debug, info, warning or error. Raise ValueError with a clear message."
        ),
        files={"app/__init__.py": "", "app/settings.py": SETTINGS},
        check=settings_check,
    ),
    Scenario(
        id="settings-default-port",
        rules=("meaningful-tests",),
        task="Change the default port in app/settings.py from 8000 to 8080.",
        files={"app/__init__.py": "", "app/settings.py": SETTINGS, "test_settings.py": SETTINGS_TESTS, "check.sh": CHECK},
        check=lambda trial: {"meaningful-tests": restated_default(trial)},
    ),
    Scenario(
        id="env-rename-docs",
        rules=("durable-docs",),
        task=(
            "Rename the DATABASE_URL environment variable to INVENTORY_DATABASE_URL. Keep accepting "
            "DATABASE_URL for one release with a deprecation warning. Update the documentation, and write "
            "the pull request description to PR_DESCRIPTION.md; I'll paste it into GitHub myself."
        ),
        files={
            "app/__init__.py": "",
            "app/config.py": CONFIG,
            "README.md": SERVICE_README,
            "docs/operations.md": OPERATIONS,
        },
        check=docs_check,
    ),
    Scenario(
        id="rename-across-files",
        rules=("edit-tool", "edit-tool-no-shell-substitute"),
        task="Rename fetch_user to load_user everywhere in the codebase.",
        files={"app/__init__.py": "", "app/users.py": USERS, **USER_MODULES},
        check=lambda trial: dict.fromkeys(
            ("edit-tool", "edit-tool-no-shell-substitute"), graders.edited_with_tool(trial)
        ),
    ),
]
