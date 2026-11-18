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


def test_assets_empty_or_invalid():
    """Test that assets rejects empty or non-dict inputs."""
    with pytest.raises(ValueError, match="Assets must be a non-empty dictionary"):
        Kestra.assets({})

    with pytest.raises(ValueError, match="Assets must be a non-empty dictionary"):
        Kestra.assets("not-a-dict")
