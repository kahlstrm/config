"""Prompt variants: the instructions with one rule's text removed."""

import re

EMPTY_BULLET = re.compile(r"^-\s*$")


def span(text):
    return re.compile(r"\s+".join(map(re.escape, text.split())))


def tidy(text):
    lines = [re.sub(r"^- +", "- ", line).rstrip() for line in text.splitlines()]
    kept = "\n".join(line for line in lines if not EMPTY_BULLET.match(line))
    return re.sub(r"\n{3,}", "\n\n", kept).strip() + "\n"


def without(text, rule_text):
    matches = list(span(rule_text).finditer(text))
    if not matches:
        raise ValueError(f"no text matches {rule_text[:60]!r}")
    if len(matches) > 1:
        raise ValueError(f"{len(matches)} places match {rule_text[:60]!r}")
    [match] = matches
    return tidy(text[: match.start()] + text[match.end() :])
