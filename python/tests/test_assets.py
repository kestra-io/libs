import pytest

from kestra import Kestra


def test_assets(monkeypatch):
    """Test counter metric functionality."""
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
