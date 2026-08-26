"""Hosted (Railway / public URL) adjustments that the local-first defaults skip.

Hermes ships with ``terminal.backend: local`` because a laptop install *is*
the computer. A Railway replica is a thin API process: the useful computer
for bots is a remote sandbox (Daytona), not the container's own shell.

This module is the merge layer. It never overwrites inference/model keys,
and it never switches away from an operator-chosen remote backend (docker,
ssh, modal, vercel_sandbox, singularity).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Mapping, MutableMapping, Optional

import yaml

DAYTONA_SANDBOX_CWD = "/home/daytona"
_LOCAL_BACKENDS = {"", "local"}
_LOCAL_CWD_SENTINELS = {".", "", "auto", "cwd"}
_REMOTE_BACKENDS_KEEP = {
    "docker",
    "ssh",
    "modal",
    "vercel_sandbox",
    "singularity",
}


def apply_hosted_computer_config(
    config: Optional[Mapping[str, Any]],
    *,
    daytona_key_present: bool,
) -> tuple[dict[str, Any], bool]:
    """Return ``(new_config, changed)`` with Daytona as the computer when keyed.

    ``changed`` is True only when a field we own actually differs. Callers
    should skip the write when it is False so we do not bump mtime on every
    boot.
    """
    raw: dict[str, Any] = dict(config) if config else {}
    if not daytona_key_present:
        return raw, False

    terminal_in = raw.get("terminal")
    terminal: dict[str, Any] = dict(terminal_in) if isinstance(terminal_in, dict) else {}
    backend = str(terminal.get("backend") or "").strip().lower()
    if backend in _REMOTE_BACKENDS_KEEP:
        return raw, False

    cwd = str(terminal.get("cwd") or "").strip()
    next_terminal = dict(terminal)
    next_terminal["backend"] = "daytona"
    if backend in _LOCAL_BACKENDS or cwd in _LOCAL_CWD_SENTINELS:
        next_terminal["cwd"] = DAYTONA_SANDBOX_CWD

    if next_terminal == terminal:
        return raw, False

    out = dict(raw)
    out["terminal"] = next_terminal
    return out, True


def apply_hosted_computer_config_file(
    path: Path,
    *,
    daytona_key_present: bool,
) -> bool:
    """Load YAML at *path*, merge, write if needed. Returns whether a write happened."""
    existing: MutableMapping[str, Any] | None = None
    if path.is_file():
        text = path.read_text(encoding="utf-8")
        loaded = yaml.safe_load(text) if text.strip() else None
        if isinstance(loaded, dict):
            existing = loaded
        elif loaded is not None:
            return False

    updated, changed = apply_hosted_computer_config(
        existing,
        daytona_key_present=daytona_key_present,
    )
    if not changed:
        return False

    path.parent.mkdir(parents=True, exist_ok=True)
    dumped = yaml.safe_dump(
        updated,
        sort_keys=False,
        allow_unicode=True,
        default_flow_style=False,
    )
    path.write_text(dumped, encoding="utf-8")
    return True


def main(argv: Optional[list[str]] = None) -> int:
    """CLI for docker/railway-start.sh: merge Daytona into $HERMES_HOME/config.yaml."""
    import os

    from hermes_constants import get_hermes_home

    key = (os.environ.get("DAYTONA_API_KEY") or "").strip()
    home = get_hermes_home()
    wrote = apply_hosted_computer_config_file(
        home / "config.yaml",
        daytona_key_present=bool(key),
    )
    if wrote:
        print("[railway] terminal.backend=daytona (DAYTONA_API_KEY present; computer is a Daytona sandbox)")
    elif key:
        print("[railway] DAYTONA_API_KEY present; leaving existing remote terminal.backend unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
