import threading
import time
from datetime import date, datetime, timezone
from datetime import time as dt_time

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
    """Test metric rejects NaN, Inf, non-numeric values, and huge overflow ints."""
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

    with pytest.raises(ValueError, match="value must be a finite number"):
        Kestra.counter("count", 10**400)


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


def test_outputs_empty_is_noop(monkeypatch):
    """Test that outputs with empty mapping is a no-op (backward compatible)."""
    calls = []

    def mock_send(data):
        calls.append(data)

    monkeypatch.setattr(Kestra, "_send", mock_send)

    Kestra.outputs({})
    assert calls == []


def test_outputs_invalid():
    """Test outputs validation rejects non-mapping inputs."""
    with pytest.raises(ValueError, match="Outputs must be a dictionary"):
        Kestra.outputs("invalid")

    with pytest.raises(ValueError, match="Outputs must be a dictionary"):
        Kestra.outputs([1, 2, 3])


def test_outputs_non_finite_rejected():
    """Test that non-finite floats in outputs are rejected with ValueError."""
    with pytest.raises(ValueError, match="cannot be sent to Kestra as JSON"):
        Kestra.outputs({"nan_val": float("nan")})

    with pytest.raises(ValueError, match="cannot be sent to Kestra as JSON"):
        Kestra.outputs({"inf_val": float("inf")})


def test_send_writes_one_flushed_line(monkeypatch):
    stdout = RecordingStdout()
    monkeypatch.setattr("sys.stdout", stdout)

    Kestra._send({"test": "value"})

    assert stdout.calls == [("write", '::{"test": "value"}::\n'), ("flush",)]


class RecordingStdout:
    def __init__(self):
        self.calls = []

    def write(self, text):
        self.calls.append(("write", text))
        # Yield to other threads, as a write to a real pipe can.
        time.sleep(0.0001)

    def flush(self):
        self.calls.append(("flush",))


def test_lines_from_several_threads_never_interleave(monkeypatch):
    stdout = RecordingStdout()
    monkeypatch.setattr("sys.stdout", stdout)

    def send():
        for _ in range(20):
            Kestra.outputs({"key": "value"})

    threads = [threading.Thread(target=send) for _ in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    text = "".join(call[1] for call in stdout.calls if call[0] == "write")
    assert text.splitlines() == ['::{"outputs": {"key": "value"}}::'] * 160


def test_timer_checks_name_and_tags_before_running_the_callable():
    calls = []

    with pytest.raises(ValueError, match="Metric name must be a non-empty string"):
        Kestra.timer("", lambda: calls.append("ran"))

    with pytest.raises(ValueError, match="must be a single value"):
        Kestra.timer("timed", lambda: calls.append("ran"), {"list": [1]})

    assert calls == []


def test_outputs_send_dates_and_times_as_iso_text(monkeypatch):
    lines = []
    monkeypatch.setattr(Kestra, "_send", lambda map_: lines.append(Kestra.format(map_)))

    Kestra.outputs(
        {
            "date": date(2024, 1, 2),
            "local": datetime(2024, 1, 2, 3, 4, 5),
            "utc": datetime(2024, 1, 2, 3, 4, 5, tzinfo=timezone.utc),
            "time": dt_time(3, 4, 5),
        }
    )

    assert lines == [
        '::{"outputs": {"date": "2024-01-02", "local": "2024-01-02T03:04:05", '
        '"utc": "2024-01-02T03:04:05+00:00", "time": "03:04:05"}}::'
    ]


def test_outputs_that_contain_themselves_are_rejected():
    value = []
    value.append(value)

    with pytest.raises(ValueError, match="it contains itself"):
        Kestra.outputs({"loop": value})


@pytest.mark.parametrize("outputs", [{"set": {1}}, {(1, 2): "tuple key"}, {"obj": object()}])
def test_outputs_json_cannot_hold_are_rejected_with_a_plain_sentence(outputs):
    with pytest.raises(TypeError, match="cannot be sent to Kestra as JSON: pass str"):
        Kestra.outputs(outputs)
