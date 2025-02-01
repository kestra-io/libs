import pytest
import requests_mock
from pytest_mock import MockerFixture

from exceptions import FailedExponentialBackoff
from kestra import Flow


def test_failed_exponential_backoff(mocker: MockerFixture):
    mock_sleep = mocker.patch("time.sleep")

    with requests_mock.Mocker() as m:
        m.get(
            "http://localhost:8080/api/v1/executions/123",
            status_code=500,
        )

        flow = Flow()

        with pytest.raises(FailedExponentialBackoff):
            flow._make_request(
                "GET",
                "http://localhost:8080/api/v1/executions/123",
            )

        assert m.call_count == 5
        mock_sleep.assert_has_calls(
            [
                mocker.call(1),
                mocker.call(2),
                mocker.call(4),
                mocker.call(8),
                mocker.call(16),
            ]
        )


@pytest.mark.parametrize(
    "tenant",
    [
        None,
        "skylord-prod",
    ],
)
def test_check_status(tenant):
    with requests_mock.Mocker() as m:
        if tenant is not None:
            url = f"http://localhost:8080/api/v1/{tenant}/executions/123"
        else:
            url = "http://localhost:8080/api/v1/executions/123"

        m.get(
            url,
            text="OK",
            status_code=200,
        )

        flow = Flow(tenant=tenant)

        response = flow.check_status(execution_id="123")

        assert response.status_code == 200
        assert m.call_count == 1


@pytest.mark.parametrize(
    "tenant",
    [
        None,
        "skylord-prod",
    ],
)
def test_get_logs(tenant):
    with requests_mock.Mocker() as m:
        if tenant is not None:
            url = f"http://localhost:8080/api/v1/{tenant}/logs/123/download"
        else:
            url = "http://localhost:8080/api/v1/logs/123/download"

        m.get(
            url,
            text="OK",
            status_code=200,
        )

        flow = Flow(tenant=tenant)

        response = flow.get_logs(execution_id="123")

        assert response.status_code == 200
        assert m.call_count == 1


@pytest.mark.parametrize(
    "tenant",
    [
        None,
        "skylord-prod",
    ],
)
def test_execute_success(tenant):
    with requests_mock.Mocker() as m:
        # Mock the execution creation
        if tenant is not None:
            url = (
                f"http://localhost:8080/api/v1/{tenant}/executions/namespace-test"
                "/flow-test"
            )
        else:
            url = "http://localhost:8080/api/v1/executions/namespace-test/flow-test"

        m.post(
            url,
            json={"id": "123"},
            status_code=200,
        )

        # Mock the status check
        if tenant is not None:
            url = f"http://localhost:8080/api/v1/{tenant}/executions/123"
        else:
            url = "http://localhost:8080/api/v1/executions/123"

        m.get(
            url,
            json={"state": {"current": "SUCCESS"}},
            status_code=200,
        )

        # Mock the logs
        if tenant is not None:
            url = f"http://localhost:8080/api/v1/{tenant}/logs/123/download"
        else:
            url = "http://localhost:8080/api/v1/logs/123/download"

        m.get(
            url,
            text="Execution logs",
            status_code=200,
        )

        flow = Flow(tenant=tenant, poll_interval=0)
        result = flow.execute(namespace="namespace-test", flow="flow-test")

        assert result.status == "SUCCESS"
        assert result.log == "Execution logs"
        assert result.error is None
        assert m.call_count == 3


@pytest.mark.parametrize(
    "tenant",
    [
        None,
        "skylord-prod",
    ],
)
def test_execute_failure(tenant):
    with requests_mock.Mocker() as m:
        # Mock the execution creation
        if tenant is not None:
            url = f"http://localhost:8080/api/v1/{tenant}/executions/namespace-test/flow-test"
        else:
            url = "http://localhost:8080/api/v1/executions/namespace-test/flow-test"

        m.post(
            url,
            json={"id": "123"},
            status_code=200,
        )

        # Mock the status check
        if tenant is not None:
            url = f"http://localhost:8080/api/v1/{tenant}/executions/123"
        else:
            url = "http://localhost:8080/api/v1/executions/123"

        m.get(
            url,
            json={"state": {"current": "FAILED"}},
            status_code=200,
        )

        # Mock the logs
        if tenant is not None:
            url = f"http://localhost:8080/api/v1/{tenant}/logs/123/download"
        else:
            url = "http://localhost:8080/api/v1/logs/123/download"

        m.get(
            url,
            text="Error logs",
            status_code=200,
        )

        flow = Flow(tenant=tenant, poll_interval=0)
        result = flow.execute(namespace="namespace-test", flow="flow-test")

        assert result.status == "FAILED"
        assert result.log == "Error logs"
        assert result.error is None
        assert m.call_count == 3


@pytest.mark.parametrize(
    "tenant",
    [
        None,
        "skylord-prod",
    ],
)
def test_execute_fire_and_forget(tenant):
    with requests_mock.Mocker() as m:
        # Mock the execution creation
        if tenant is not None:
            url = f"http://localhost:8080/api/v1/{tenant}/executions/namespace-test/flow-test"
        else:
            url = "http://localhost:8080/api/v1/executions/namespace-test/flow-test"

        m.post(
            url,
            json={"id": "123"},
            status_code=200,
        )

        flow = Flow(tenant=tenant, wait_for_completion=False, poll_interval=0)
        result = flow.execute(namespace="namespace-test", flow="flow-test")

        assert result.status == "STARTED"
        assert result.log is None
        assert result.error is None
        assert m.call_count == 1


@pytest.mark.parametrize(
    "tenant",
    [
        None,
        "skylord-prod",
    ],
)
def test_execute_with_inputs(tenant):
    with requests_mock.Mocker() as m:
        # Mock the execution creation
        if tenant is not None:
            url = f"http://localhost:8080/api/v1/{tenant}/executions/namespace-test/flow-test"
        else:
            url = "http://localhost:8080/api/v1/executions/namespace-test/flow-test"

        m.post(
            url,
            json={"id": "123"},
            status_code=200,
        )

        # Mock the status check
        if tenant is not None:
            url = f"http://localhost:8080/api/v1/{tenant}/executions/123"
        else:
            url = "http://localhost:8080/api/v1/executions/123"

        m.get(
            url,
            json={"state": {"current": "SUCCESS"}},
            status_code=200,
        )

        # Mock the logs
        if tenant is not None:
            url = f"http://localhost:8080/api/v1/{tenant}/logs/123/download"
        else:
            url = "http://localhost:8080/api/v1/logs/123/download"

        m.get(
            url,
            text="Execution logs",
            status_code=200,
        )

        flow = Flow(tenant=tenant, poll_interval=0)
        result = flow.execute(
            namespace="namespace-test", flow="flow-test", inputs={"param1": "value1"}
        )

        assert result.status == "SUCCESS"
        assert result.log == "Execution logs"
        assert result.error is None
        assert m.call_count == 3
