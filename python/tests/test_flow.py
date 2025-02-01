import pytest
import requests_mock

from kestra import Flow


def test_check_status():
    with requests_mock.Mocker() as m:
        m.get(
            "http://localhost:8080/api/v1/executions/123",
            text="OK",
            status_code=200,
        )

        flow = Flow()

        response = flow.check_status(execution_id="123")

        assert response.status_code == 200
        assert m.call_count == 1


def test_get_logs():
    with requests_mock.Mocker() as m:
        m.get(
            "http://localhost:8080/api/v1/logs/123/download",
            text="OK",
            status_code=200,
        )

        flow = Flow()

        response = flow.get_logs(execution_id="123")

        assert response.status_code == 200
        assert m.call_count == 1


def test_execute_success():
    with requests_mock.Mocker() as m:
        # Mock the execution creation
        m.post(
            "http://localhost:8080/api/v1/executions/namespace-test/flow-test",
            json={"id": "123"},
            status_code=200,
        )
        # Mock the status check
        m.get(
            "http://localhost:8080/api/v1/executions/123",
            json={"state": {"current": "SUCCESS"}},
            status_code=200,
        )
        # Mock the logs
        m.get(
            "http://localhost:8080/api/v1/logs/123/download",
            text="Execution logs",
            status_code=200,
        )

        flow = Flow(poll_interval=0)
        result = flow.execute(namespace="namespace-test", flow="flow-test")

        assert result.status == "SUCCESS"
        assert result.log == "Execution logs"
        assert result.error is None
        assert m.call_count == 3


def test_execute_failure():
    with requests_mock.Mocker() as m:
        # Mock the execution creation
        m.post(
            "http://localhost:8080/api/v1/executions/namespace-test/flow-test",
            json={"id": "123"},
            status_code=200,
        )
        # Mock the status check
        m.get(
            "http://localhost:8080/api/v1/executions/123",
            json={"state": {"current": "FAILED"}},
            status_code=200,
        )
        # Mock the logs
        m.get(
            "http://localhost:8080/api/v1/logs/123/download",
            text="Error logs",
            status_code=200,
        )

        flow = Flow(poll_interval=0)
        result = flow.execute(namespace="namespace-test", flow="flow-test")

        assert result.status == "FAILED"
        assert result.log == "Error logs"
        assert result.error is None
        assert m.call_count == 3


def test_execute_fire_and_forget():
    with requests_mock.Mocker() as m:
        # Mock the execution creation
        m.post(
            "http://localhost:8080/api/v1/executions/namespace-test/flow-test",
            json={"id": "123"},
            status_code=200,
        )

        flow = Flow(wait_for_completion=False, poll_interval=0)
        result = flow.execute(namespace="namespace-test", flow="flow-test")

        assert result.status == "STARTED"
        assert result.log is None
        assert result.error is None
        assert m.call_count == 1


def test_execute_with_inputs():
    with requests_mock.Mocker() as m:
        # Mock the execution creation
        m.post(
            "http://localhost:8080/api/v1/executions/namespace-test/flow-test",
            json={"id": "123"},
            status_code=200,
        )
        # Mock the status check
        m.get(
            "http://localhost:8080/api/v1/executions/123",
            json={"state": {"current": "SUCCESS"}},
            status_code=200,
        )
        # Mock the logs
        m.get(
            "http://localhost:8080/api/v1/logs/123/download",
            text="Execution logs",
            status_code=200,
        )

        flow = Flow(poll_interval=0)
        result = flow.execute(
            namespace="namespace-test", flow="flow-test", inputs={"param1": "value1"}
        )

        assert result.status == "SUCCESS"
        assert result.log == "Execution logs"
        assert result.error is None
        assert m.call_count == 3
