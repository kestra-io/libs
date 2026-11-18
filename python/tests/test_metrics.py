import time

import pytest
from kestra import Kestra


def test_counter_metric(monkeypatch):
    """Test counter metric functionality."""
    calls = []
    
    def mock_send(data):
        calls.append(data)
    
    monkeypatch.setattr(Kestra, '_send', mock_send)
    
    Kestra.counter("test_counter", 5)
    
    expected_call = {
        "metrics": [
            {
                "name": "test_counter",
                "type": "counter",
                "value": 5,
                "tags": {},
            }
        ]
    }
    assert calls == [expected_call]


def test_counter_metric_with_tags(monkeypatch):
    """Test counter metric with tags."""
    calls = []
    
    def mock_send(data):
        calls.append(data)
    
    monkeypatch.setattr(Kestra, '_send', mock_send)
    
    tags = {"environment": "test", "service": "api"}
    Kestra.counter("test_counter", 10, tags)
    
    expected_call = {
        "metrics": [
            {
                "name": "test_counter",
                "type": "counter",
                "value": 10,
                "tags": tags,
            }
        ]
    }
    assert calls == [expected_call]


def test_timer_metric(monkeypatch):
    """Test timer metric functionality."""
    calls = []
    
    def mock_send(data):
        calls.append(data)
    
    monkeypatch.setattr(Kestra, '_send', mock_send)
    
    Kestra.timer("test_timer", 1000)
    
    expected_call = {
        "metrics": [
            {
                "name": "test_timer",
                "type": "timer",
                "value": 1000,
                "tags": {},
            }
        ]
    }
    assert calls == [expected_call]


def test_timer_metric_with_tags(monkeypatch):
    """Test timer metric with tags."""
    calls = []
    
    def mock_send(data):
        calls.append(data)
    
    monkeypatch.setattr(Kestra, '_send', mock_send)
    
    tags = {"operation": "database_query"}
    Kestra.timer("test_timer", 500, tags)
    
    expected_call = {
        "metrics": [
            {
                "name": "test_timer",
                "type": "timer",
                "value": 500,
                "tags": tags,
            }
        ]
    }
    assert calls == [expected_call]


def test_gauge_metric(monkeypatch):
    """Test gauge metric functionality."""
    calls = []
    
    def mock_send(data):
        calls.append(data)
    
    monkeypatch.setattr(Kestra, '_send', mock_send)
    
    Kestra.gauge("test_gauge", 42.5)
    
    expected_call = {
        "metrics": [
            {
                "name": "test_gauge",
                "type": "gauge",
                "value": 42.5,
                "tags": {},
            }
        ]
    }
    assert calls == [expected_call]


def test_gauge_metric_with_tags(monkeypatch):
    """Test gauge metric with tags."""
    calls = []
    
    def mock_send(data):
        calls.append(data)
    
    monkeypatch.setattr(Kestra, '_send', mock_send)
    
    tags = {"instance": "server-1", "region": "us-east-1"}
    Kestra.gauge("memory_usage", 75.3, tags)
    
    expected_call = {
        "metrics": [
            {
                "name": "memory_usage",
                "type": "gauge",
                "value": 75.3,
                "tags": tags,
            }
        ]
    }
    assert calls == [expected_call]


def test_gauge_metric_integer_value(monkeypatch):
    """Test gauge metric with integer value."""
    calls = []
    
    def mock_send(data):
        calls.append(data)
    
    monkeypatch.setattr(Kestra, '_send', mock_send)
    
    Kestra.gauge("active_connections", 150)
    
    expected_call = {
        "metrics": [
            {
                "name": "active_connections",
                "type": "gauge",
                "value": 150,
                "tags": {},
            }
        ]
    }
    assert calls == [expected_call]


def test_gauge_metric_zero_value(monkeypatch):
    """Test gauge metric with zero value."""
    calls = []
    
    def mock_send(data):
        calls.append(data)
    
    monkeypatch.setattr(Kestra, '_send', mock_send)
    
    Kestra.gauge("queue_size", 0)
    
    expected_call = {
        "metrics": [
            {
                "name": "queue_size",
                "type": "gauge",
                "value": 0,
                "tags": {},
            }
        ]
    }
    assert calls == [expected_call]


def test_gauge_metric_negative_value(monkeypatch):
    """Test gauge metric with negative value."""
    calls = []
    
    def mock_send(data):
        calls.append(data)
    
    monkeypatch.setattr(Kestra, '_send', mock_send)
    
    Kestra.gauge("temperature", -5.2)
    
    expected_call = {
        "metrics": [
            {
                "name": "temperature",
                "type": "gauge",
                "value": -5.2,
                "tags": {},
            }
        ]
    }
    assert calls == [expected_call]


def test_multiple_metrics(monkeypatch):
    """Test sending multiple different metric types."""
    calls = []
    
    def mock_send(data):
        calls.append(data)
    
    monkeypatch.setattr(Kestra, '_send', mock_send)
    
    Kestra.counter("requests", 1)
    Kestra.timer("response_time", 250)
    Kestra.gauge("cpu_usage", 85.7)
    
    expected_calls = [
        {
            "metrics": [
                {
                    "name": "requests",
                    "type": "counter",
                    "value": 1,
                    "tags": {},
                }
            ]
        },
        {
            "metrics": [
                {
                    "name": "response_time",
                    "type": "timer",
                    "value": 250,
                    "tags": {},
                }
            ]
        },
        {
            "metrics": [
                {
                    "name": "cpu_usage",
                    "type": "gauge",
                    "value": 85.7,
                    "tags": {},
                }
            ]
        }
    ]
    assert calls == expected_calls


def test_timer_metric_with_callable(monkeypatch):
    """Test timer metric when passed a callable."""
    calls = []

    def mock_send(data):
        calls.append(data)

    monkeypatch.setattr(Kestra, "_send", mock_send)

    def work():
        time.sleep(0.01)
        return "result_value"

    result = Kestra.timer("timed_work", work, {"op": "work"})

    assert result == "result_value"
    assert len(calls) == 1
    metric = calls[0]["metrics"][0]
    assert metric["name"] == "timed_work"
    assert metric["type"] == "timer"
    assert metric["tags"] == {"op": "work"}
    assert isinstance(metric["value"], float)
    assert metric["value"] >= 0.01


def test_timer_metric_with_callable_exception(monkeypatch):
    """Test timer metric does not send metric when callable raises."""
    calls = []

    def mock_send(data):
        calls.append(data)

    monkeypatch.setattr(Kestra, "_send", mock_send)

    def failing_work():
        raise RuntimeError("boom")

    with pytest.raises(RuntimeError, match="boom"):
        Kestra.timer("failing", failing_work)

    assert calls == []


def test_metric_validation_empty_or_non_string_name():
    """Test metric name validation."""
    with pytest.raises(ValueError, match="Metric name must be a non-empty string"):
        Kestra.counter("", 1)

    with pytest.raises(ValueError, match="Metric name must be a non-empty string"):
        Kestra.gauge(None, 1)


def test_metric_validation_non_finite_value():
    """Test metric rejects NaN, Inf, and non-numeric values."""
    with pytest.raises(ValueError, match="value must be a finite number"):
        Kestra.counter("count", float("nan"))

    with pytest.raises(ValueError, match="value must be a finite number"):
        Kestra.gauge("temp", float("inf"))

    with pytest.raises(ValueError, match="value must be a finite number"):
        Kestra.timer("dur", float("-inf"))

    with pytest.raises(ValueError, match="value must be a finite number"):
        Kestra.counter("count", True)

    with pytest.raises(ValueError, match="value must be a finite number"):
        Kestra.counter("count", "123")


def test_metric_tags_validation(monkeypatch):
    """Test metric tags validation and stringification."""
    calls = []

    def mock_send(data):
        calls.append(data)

    monkeypatch.setattr(Kestra, "_send", mock_send)

    with pytest.raises(ValueError, match="tags must be a dictionary"):
        Kestra.counter("test", 1, tags="not-a-dict")

    with pytest.raises(ValueError, match="must be a single value"):
        Kestra.counter("test", 1, tags={"nested": {"a": "b"}})

    with pytest.raises(ValueError, match="must be a single value"):
        Kestra.counter("test", 1, tags={"list": [1, 2]})

    # Primitive values like ints should be converted to strings
    Kestra.counter("test", 1, tags={"port": 8080, "env": "prod"})
    assert calls[0]["metrics"][0]["tags"] == {"port": "8080", "env": "prod"}


def test_outputs_valid(monkeypatch):
    """Test outputs functionality."""
    calls = []

    def mock_send(data):
        calls.append(data)

    monkeypatch.setattr(Kestra, "_send", mock_send)

    Kestra.outputs({"status": 200, "message": "done"})
    assert calls == [{"outputs": {"status": 200, "message": "done"}}]


def test_outputs_empty_or_invalid():
    """Test outputs validation."""
    with pytest.raises(ValueError, match="Outputs must be a non-empty dictionary"):
        Kestra.outputs({})

    with pytest.raises(ValueError, match="Outputs must be a non-empty dictionary"):
        Kestra.outputs("invalid")


def test_send_flushes_stdout(monkeypatch):
    """Test that _send calls print with flush=True."""
    printed = []

    def mock_print(*args, **kwargs):
        printed.append((args, kwargs))

    monkeypatch.setattr("builtins.print", mock_print)

    Kestra._send({"test": "value"})

    assert len(printed) == 1
    args, kwargs = printed[0]
    assert args == ('::{"test": "value"}::',)
    assert kwargs.get("flush") is True
