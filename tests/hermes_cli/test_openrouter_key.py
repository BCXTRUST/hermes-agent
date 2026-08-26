"""OpenRouter management keys must not be used as chat credentials."""

from unittest.mock import patch

from hermes_cli.openrouter_key import (
    ensure_openrouter_inference_in_env,
    is_openrouter_management_key,
    upsert_env_file,
)


def test_management_flag_detects_provisioning_and_management():
    assert is_openrouter_management_key({"is_provisioning_key": True}) is True
    assert is_openrouter_management_key({"is_management_key": True}) is True
    assert is_openrouter_management_key({"is_provisioning_key": False}) is False
    assert is_openrouter_management_key({}) is False


def test_env_file_upsert_replaces_key_and_preserves_neighbors(tmp_path):
    path = tmp_path / ".env"
    path.write_text("FOO=1\nOPENROUTER_API_KEY=old\nBAR=2\n", encoding="utf-8")
    upsert_env_file(path, {"OPENROUTER_API_KEY": "new", "OPENROUTER_PROVISIONING_KEY": "mgmt"})
    text = path.read_text(encoding="utf-8")
    assert "FOO=1" in text
    assert "BAR=2" in text
    assert "OPENROUTER_API_KEY=new" in text
    assert "OPENROUTER_PROVISIONING_KEY=mgmt" in text
    assert "OPENROUTER_API_KEY=old" not in text


def test_ensure_keeps_existing_inference_when_process_has_management(tmp_path):
    path = tmp_path / ".env"
    path.write_text("OPENROUTER_API_KEY=sk-or-inf\n", encoding="utf-8")

    def fake_inspect(key, **_kw):
        if key.endswith("inf"):
            return {"is_provisioning_key": False, "is_management_key": False}
        return {"is_provisioning_key": True, "is_management_key": True}

    with patch("hermes_cli.openrouter_key.inspect_openrouter_key", side_effect=fake_inspect), patch(
        "hermes_cli.openrouter_key.mint_openrouter_inference_key",
        side_effect=AssertionError("must not mint when inference already exists"),
    ), patch.dict("os.environ", {"OPENROUTER_API_KEY": "sk-or-mgmt"}, clear=False):
        result = ensure_openrouter_inference_in_env(path)

    assert result["minted"] is False
    assert result["reason"] == "ok"
    text = path.read_text(encoding="utf-8")
    assert "OPENROUTER_API_KEY=sk-or-inf" in text
    assert "OPENROUTER_PROVISIONING_KEY=sk-or-mgmt" in text


def test_ensure_mints_when_only_management_key_present(tmp_path):
    path = tmp_path / ".env"
    path.write_text("OPENROUTER_API_KEY=sk-or-mgmt\n", encoding="utf-8")

    def fake_inspect(key, **_kw):
        if key.endswith("chat"):
            return {"is_provisioning_key": False}
        return {"is_provisioning_key": True, "is_management_key": True}

    with patch("hermes_cli.openrouter_key.inspect_openrouter_key", side_effect=fake_inspect), patch(
        "hermes_cli.openrouter_key.mint_openrouter_inference_key",
        return_value="sk-or-chat",
    ):
        result = ensure_openrouter_inference_in_env(path)

    assert result["minted"] is True
    text = path.read_text(encoding="utf-8")
    assert "OPENROUTER_API_KEY=sk-or-chat" in text
    assert "OPENROUTER_PROVISIONING_KEY=sk-or-mgmt" in text
