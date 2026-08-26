"""Hosted Railway computer: Daytona is the sandbox, not the replica shell."""

from hermes_cli.railway_online import (
    DAYTONA_SANDBOX_CWD,
    apply_hosted_computer_config,
    apply_hosted_computer_config_file,
)


def test_no_key_leaves_local_config_alone():
    raw = {"model": {"provider": "openrouter"}, "terminal": {"backend": "local", "cwd": "."}}
    out, changed = apply_hosted_computer_config(raw, daytona_key_present=False)
    assert changed is False
    assert out["terminal"]["backend"] == "local"
    assert out["model"]["provider"] == "openrouter"


def test_key_switches_local_backend_to_daytona_and_sandbox_cwd():
    raw = {
        "model": {"provider": "openrouter", "default": "nvidia/nemotron-3-super-120b-a12b:free"},
        "terminal": {"backend": "local", "cwd": "."},
    }
    out, changed = apply_hosted_computer_config(raw, daytona_key_present=True)
    assert changed is True
    assert out["terminal"]["backend"] == "daytona"
    assert out["terminal"]["cwd"] == DAYTONA_SANDBOX_CWD
    assert out["model"]["provider"] == "openrouter"
    assert out["model"]["default"] == "nvidia/nemotron-3-super-120b-a12b:free"


def test_empty_config_gains_daytona_when_keyed():
    out, changed = apply_hosted_computer_config(None, daytona_key_present=True)
    assert changed is True
    assert out["terminal"]["backend"] == "daytona"
    assert out["terminal"]["cwd"] == DAYTONA_SANDBOX_CWD


def test_does_not_override_operator_chosen_remote_backend():
    raw = {"terminal": {"backend": "ssh", "cwd": "/home/ubuntu"}}
    out, changed = apply_hosted_computer_config(raw, daytona_key_present=True)
    assert changed is False
    assert out["terminal"]["backend"] == "ssh"
    assert out["terminal"]["cwd"] == "/home/ubuntu"


def test_already_daytona_with_sandbox_cwd_is_idempotent():
    raw = {"terminal": {"backend": "daytona", "cwd": DAYTONA_SANDBOX_CWD}}
    out, changed = apply_hosted_computer_config(raw, daytona_key_present=True)
    assert changed is False
    assert out["terminal"]["cwd"] == DAYTONA_SANDBOX_CWD


def test_daytona_backend_keeps_custom_cwd():
    raw = {"terminal": {"backend": "daytona", "cwd": "/workspace"}}
    out, changed = apply_hosted_computer_config(raw, daytona_key_present=True)
    assert changed is False
    assert out["terminal"]["cwd"] == "/workspace"


def test_file_roundtrip_preserves_unrelated_yaml(tmp_path):
    path = tmp_path / "config.yaml"
    path.write_text(
        "model:\n  provider: openrouter\nterminal:\n  backend: local\n  cwd: .\n",
        encoding="utf-8",
    )
    assert apply_hosted_computer_config_file(path, daytona_key_present=True) is True
    text = path.read_text(encoding="utf-8")
    assert "provider: openrouter" in text
    assert "backend: daytona" in text
    assert DAYTONA_SANDBOX_CWD in text
    assert apply_hosted_computer_config_file(path, daytona_key_present=True) is False


def test_daytona_key_is_catalogued_for_dashboard_keys_page():
    from hermes_cli.config import OPTIONAL_ENV_VARS

    assert "DAYTONA_API_KEY" in OPTIONAL_ENV_VARS
    meta = OPTIONAL_ENV_VARS["DAYTONA_API_KEY"]
    assert meta["password"] is True
    assert meta["category"] == "tool"
    assert "terminal" in meta.get("tools", [])
    assert OPTIONAL_ENV_VARS["DAYTONA_API_URL"]["password"] is False
