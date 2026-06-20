from __future__ import annotations

import re

from pathlib import Path
from typing import Any, Iterable

FAILURE_MARKERS = (
    "Command exited with code ",
    "Command timed out",
    "ERROR task failed",
    "timed out after",
)

SECRET_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"github_pat_[A-Za-z0-9_]+"), "github_pat_[REDACTED]"),
    (re.compile(r"gh[pousr]_[A-Za-z0-9_]+"), "gh*_REDACTED"),
    (re.compile(r"sk-[A-Za-z0-9_-]{16,}"), "sk-[REDACTED]"),
    (re.compile(r"(?i)\b(GITHUB_TOKEN|GH_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY|API_KEY|TOKEN|PASSWORD|SECRET)=(['\"])[^'\"]*\2"), r"\1=\2[REDACTED]\2"),
    (re.compile(r"(?i)\b(GITHUB_TOKEN|GH_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY|API_KEY|TOKEN|PASSWORD|SECRET)=([^\s'\"]+)"), r"\1=[REDACTED]"),
    (re.compile(r"(?i)(Authorization:\s*(?:Bearer|Basic)\s+)[^'\"\s]+"), r"\1[REDACTED]"),
    (re.compile(r"(?i)(--(?:api-key|password|secret|token)\s+)[^'\"\s]+"), r"\1[REDACTED]"),
    (re.compile(r"-----BEGIN [^-]+-----.*?-----END [^-]+-----", re.DOTALL), "[REDACTED PEM BLOCK]"),
]

TEST_RE = re.compile(r"\b(mise\s+run\s+(?:-q\s+)?test|bats\b|mix\s+test|bun\s+test|cargo\s+test|pytest\b|npm\s+test)\b")
LINT_RE = re.compile(r"\b(codebase\s+lint|shellcheck\b|actionlint\b|git\s+diff\s+--check|bash\s+-n|readme\s+build\s+--check|cargo\s+fmt|mix\s+format|pre-commit|pre-push)\b")
GIT_GH_RE = re.compile(r"^\s*(git|gh)\b|\bgh\s+(pr|issue|api|run)\b|\bgit\s+(status|diff|log|show|fetch|pull|push|commit|checkout|switch|merge|rev-parse)\b")
SEARCH_RE = re.compile(r"^\s*(rg|grep|find|ls|wc|jq)\b|\b(rg|grep|find)\b")
INSTALL_RE = re.compile(r"\b(mise\s+(trust|install|x|exec)|npm\s+install|bun\s+install|cargo\s+build|mix\s+deps|get)\b")
SESSION_RE = re.compile(r"\b(sessions|sphincters|shimmer|shell\s+(status|wait|attach))\b")
FILE_RE = re.compile(r"^\s*(cp|mv|rm|mkdir|chmod|touch|tee|cat)\b|\b(chmod|mkdir|rm\s+-rf)\b")
SCRIPT_RE = re.compile(r"^\s*(python3?|node|bun|ruby|perl)\b|<<'?(PY|EOF|JS|SH)'?")
EXIT_RE = re.compile(r"Command exited with code (\d+)")
