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