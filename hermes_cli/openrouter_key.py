"""OpenRouter key kinds: management/provisioning vs inference.

OpenRouter management keys authenticate ``GET /api/v1/key`` (so the dashboard
probe looks green) but chat completions return HTTP 401 ``User not found.``
When the operator pastes a management key we mint a child inference key via
the Management API and keep the management key as ``OPENROUTER_PROVISIONING_KEY``.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Optional

_AUTH_KEY_URL = "https://openrouter.ai/api/v1/auth/key"
_CREATE_KEY_URL = "https://openrouter.ai/api/v1/keys"
_INFERENCE_NAME = "Hermes inference"


def inspect_openrouter_key(api_key: str, *, timeout: float = 15.0) -> dict[str, Any]:
    """Return the ``data`` object from ``GET /api/v1/auth/key``."""
    key = (api_key or "").strip()
    if not key:
        raise ValueError("empty OpenRouter key")
    req = urllib.request.Request(_AUTH_KEY_URL)
    req.add_header("Authorization", f"Bearer {key}")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    data = payload.get("data") if isinstance(payload, dict) else None
    return data if isinstance(data, dict) else {}


def is_openrouter_management_key(info: dict[str, Any]) -> bool:
    return bool(info.get("is_provisioning_key") or info.get("is_management_key"))


def mint_openrouter_inference_key(
    management_key: str,
    *,
    name: str = _INFERENCE_NAME,
    timeout: float = 30.0,
) -> str:
    """Create a chat-capable key. Plaintext is only in this response."""
    payload = json.dumps({"name": name}).encode("utf-8")
    req = urllib.request.Request(_CREATE_KEY_URL, data=payload, method="POST")
    req.add_header("Authorization", f"Bearer {management_key.strip()}")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    key = ""
    if isinstance(body, dict):
        key = str(body.get("key") or "").strip()
    if not key.startswith("sk-or-"):
        raise RuntimeError("OpenRouter did not return an inference key")
    return key


def read_env_file(path: Path) -> dict[str, str]:
    kv: dict[str, str] = {}
    if not path.exists():
        return kv
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.strip().startswith("#"):
            name, value = line.split("=", 1)
            kv[name] = value.strip()
    return kv


def upsert_env_file(path: Path, updates: dict[str, str]) -> None:
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    skip = set(updates)
    lines = []
    for line in text.splitlines():
        if "=" in line and not line.strip().startswith("#"):
            name = line.split("=", 1)[0]
            if name in skip:
                continue
        lines.append(line)
    for name, value in updates.items():
        if value:
            lines.append(f"{name}={value}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def ensure_openrouter_inference_in_env(
    env_path: Path,
    *,
    api_key: Optional[str] = None,
) -> dict[str, Any]:
    """Mint/swap keys on a Hermes ``.env`` file. Safe to call on every boot.

    A Railway variable may hold a management key. We never overwrite an
    existing inference ``OPENROUTER_API_KEY`` in the env file with that
    management key — that would mint a new child key on every deploy.
    """
    path = Path(env_path)
    kv = read_env_file(path)
    proc_key = (api_key or os.environ.get("OPENROUTER_API_KEY") or "").strip()
    file_key = (kv.get("OPENROUTER_API_KEY") or "").strip()
    provisioning = (
        os.environ.get("OPENROUTER_PROVISIONING_KEY")
        or kv.get("OPENROUTER_PROVISIONING_KEY")
        or ""
    ).strip()

    def _kind(key: str) -> str:
        if not key:
            return "missing"
        info = inspect_openrouter_key(key)
        if is_openrouter_management_key(info):
            return "management"
        return "inference"

    try:
        proc_kind = _kind(proc_key) if proc_key else "missing"
        file_kind = _kind(file_key) if file_key else "missing"
    except Exception as exc:
        return {
            "changed": False,
            "minted": False,
            "reason": "error",
            "error": type(exc).__name__,
        }

    if proc_kind == "management":
        provisioning = proc_key
    if file_kind == "management" and not provisioning:
        provisioning = file_key

    inference = ""
    if file_kind == "inference":
        inference = file_key
    elif proc_kind == "inference":
        inference = proc_key

    minted = False
    if not inference:
        if not provisioning:
            return {"changed": False, "minted": False, "reason": "missing"}
        try:
            inference = mint_openrouter_inference_key(provisioning)
            minted = True
        except Exception as exc:
            return {
                "changed": False,
                "minted": False,
                "reason": "error",
                "error": type(exc).__name__,
            }

    updates = {"OPENROUTER_API_KEY": inference}
    if provisioning:
        updates["OPENROUTER_PROVISIONING_KEY"] = provisioning
    changed = (
        kv.get("OPENROUTER_API_KEY") != inference
        or (provisioning and kv.get("OPENROUTER_PROVISIONING_KEY") != provisioning)
        or minted
    )
    if changed:
        upsert_env_file(path, updates)
    os.environ["OPENROUTER_API_KEY"] = inference
    if provisioning:
        os.environ["OPENROUTER_PROVISIONING_KEY"] = provisioning
    return {"changed": changed, "minted": minted, "reason": "ok"}


def main(argv: Optional[list[str]] = None) -> int:
    from hermes_constants import get_hermes_home

    result = ensure_openrouter_inference_in_env(get_hermes_home() / ".env")
    if result.get("minted"):
        print("[railway] minted OpenRouter inference key from management key")
    elif result.get("changed"):
        print("[railway] stored OpenRouter inference key (management key kept as OPENROUTER_PROVISIONING_KEY)")
    elif result.get("reason") == "missing":
        print("[railway] no OPENROUTER_API_KEY")
    elif result.get("reason") == "error":
        print(f"[railway] warning: OpenRouter key check failed ({result.get('error')})")
    else:
        print("[railway] OpenRouter key is already an inference key")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
