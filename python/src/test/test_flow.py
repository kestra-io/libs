import pytest
import requests_mock
import os

from setuptools import setup

from kestra import Flow

class TestFlow:
    API_ENDPOINT_EXECUTION_CREATE: str = "/api/v1/executions/test/test"
    API_ENDPOINT_EXECUTION_STATUS: str = "/api/v1/executions/1"
    API_ENDPOINT_EXECUTION_LOG: str = "/api/v1/logs/1/download"
    dir_path = os.path.dirname(os.path.realpath(__file__))

    def setup_method(self):
        self.user = "test"
        self.password = "test"
        self.hostname = "http://test-kestra"
        self.namespace = "test"
        self.flow = "test"
        self.inputs = {"testData": "test"}
        self.kestra = Flow()

        with open(f"{self.dir_path}/response_failed.json", "r") as response:
            self.mockResponseFailed = response.read()

        with open(f"{self.dir_path}/response_warning.json", "r") as response:
            self.mockResponseWarning = response.read()

        with open(f"{self.dir_path}/response_success.json", "r") as response:
            self.mockResponseSuccess = response.read()

        with open(f"{self.dir_path}/response_execution_ok.json", "r") as response:
            self.mockResponseExecutionOk = response.read()

        with open(f"{self.dir_path}/response_execution_wrong.json", "r") as response:
            self.mockResponseExecutionWrong = response.read()

    def test_execute_flow_failed(self):
        with requests_mock.Mocker() as m:
            m.register_uri(
                "POST",
                self.hostname + TestFlow.API_ENDPOINT_EXECUTION_CREATE,
                text=self.mockResponseExecutionOk,
            )
            m.register_uri(
                "GET",
                self.hostname + TestFlow.API_ENDPOINT_EXECUTION_STATUS,
                text=self.mockResponseFailed,
            )
            m.register_uri(
                "GET",
                self.hostname + TestFlow.API_ENDPOINT_EXECUTION_LOG,
                text="Run failed",
            )
            self.kestra.user = self.user
            self.kestra.password = self.password
            self.kestra.hostname = self.hostname
            result = self.kestra.execute(
                self.namespace,
                self.flow,
                self.inputs,
            )
            assert result.status == "FAILED"
            assert result.log == "Run failed"
            assert result.error is None

    def test_execute_flow_warning(self):
        with requests_mock.Mocker() as m:
            m.register_uri(
                "POST",
                self.hostname + TestFlow.API_ENDPOINT_EXECUTION_CREATE,
                text=self.mockResponseExecutionOk,
            )
            m.register_uri(
                "GET",
                self.hostname + TestFlow.API_ENDPOINT_EXECUTION_STATUS,
                text=self.mockResponseWarning,
            )
            m.register_uri(
                "GET",
                self.hostname + TestFlow.API_ENDPOINT_EXECUTION_LOG,
                text="Run has warnings",
            )
            self.kestra.user = self.user
            self.kestra.password = self.password
            self.kestra.hostname = self.hostname
            result = self.kestra.execute(
                self.namespace,
                self.flow,
                self.inputs,
            )
            assert result.status == "WARNING"
            assert result.log == "Run has warnings"
            assert result.error is None

    def test_execute_flow_success(self):
        with requests_mock.Mocker() as m:
            m.register_uri(
                "POST",
                self.hostname + TestFlow.API_ENDPOINT_EXECUTION_CREATE,
                text=self.mockResponseExecutionOk,
            )
            m.register_uri(
                "GET",
                self.hostname + TestFlow.API_ENDPOINT_EXECUTION_STATUS,
                text=self.mockResponseSuccess,
            )
            m.register_uri(
                "GET",
                self.hostname + TestFlow.API_ENDPOINT_EXECUTION_LOG,
                text="Run was ok",
            )
            self.kestra.user = self.user
            self.kestra.password = self.password
            self.kestra.hostname = self.hostname
            result = self.kestra.execute(
                self.namespace,
                self.flow,
                self.inputs,
            )
            assert result.status == "SUCCESS"
            assert result.log == "Run was ok"
            assert result.error is None

    def test_execute_flow_execution_wrong(self):
        with requests_mock.Mocker() as m:
            m.register_uri(
                "POST",
                self.hostname
                + TestFlow.API_ENDPOINT_EXECUTION_CREATE
                + "_wrong?labels=testData:test",
                text=self.mockResponseExecutionWrong,
            )

            self.kestra.user = self.user
            self.kestra.password = self.password
            self.kestra.hostname = self.hostname

            with pytest.raises(Exception) as context:
                self.kestra.execute(
                    self.namespace,
                    self.flow + "_wrong",
                    self.inputs,
                )
