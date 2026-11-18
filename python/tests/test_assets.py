import pytest

from kestra import Kestra


def test_assets(monkeypatch):
    """Test assets functionality."""
    calls = []

    def mock_send(data):
        calls.append(data)

    monkeypatch.setattr(Kestra, '_send', mock_send)

    Kestra.assets({
        "inputs": [{
            "id": "input_asset",
            "type": "INPUT_ASSET_TYPE"
        }],
        "outputs": [{
            "id": "test_asset",
            "type": "VM",
            "metadata": {
                "owner": "team_a",
            }
        }],
    })

    expected_call = {
        "assets": {
            "inputs": [{
                "id": "input_asset",
                "type": "INPUT_ASSET_TYPE"
            }],
            "outputs": [{
                "id": "test_asset",
                "type": "VM",
                "metadata": {
                    "owner": "team_a",
                }
            }],
        }
    }
    assert calls == [expected_call]


def test_assets_empty_is_noop(monkeypatch):
    """Test that assets with empty mapping is a no-op (backward compatible)."""
    calls = []

    def mock_send(data):
        calls.append(data)

    monkeypatch.setattr(Kestra, "_send", mock_send)

    Kestra.assets({})
    assert calls == []


def test_assets_invalid():
    """Test that assets rejects non-dict inputs."""
    with pytest.raises(ValueError, match="Assets must be a dictionary"):
        Kestra.assets("not-a-dict")

    with pytest.raises(ValueError, match="Assets must be a dictionary"):
        Kestra.assets([1, 2, 3])


def test_assets_non_finite_rejected():
    """Test that non-finite floats in assets are rejected."""
    with pytest.raises(ValueError, match="cannot be sent to Kestra as JSON"):
        Kestra.assets({"outputs": [{"id": "asset1", "value": float("nan")}]})
