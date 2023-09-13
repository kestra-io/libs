from unittest import TestCase
import requests_mock

from kestra import Flow


class TestFlow(TestCase):
    API_ENDPOINT_EXECUTION_CREATE: str = "/api/v1/executions/trigger/test/test"
    API_ENDPOINT_EXECUTION_STATUS: str = "/api/v1/executions/1"
    API_ENDPOINT_EXECUTION_LOG: str = "/api/v1/logs/1/download"

    def setUp(self):
        self.user = "test"
        self.password = "test"
        self.hostname = "http://test-kestra"
        self.namespace = "test"
        self.flow = "test"
        self.inputs = {"testData": "test"}
        self.kestra = Flow()

        with open("test/response_failed.json", "r") as response:
            self.mockResponseFailed = response.read()

        with open("test/response_warning.json", "r") as response:
            self.mockResponseWarning = response.read()

        with open("test/response_success.json", "r") as response:
            self.mockResponseSuccess = response.read()

        with open("test/response_execution_ok.json", "r") as response:
            self.mockResponseExecutionOk = response.read()

        with open("test/response_execution_wrong.json", "r") as response:
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
            self.assertEqual(result.status, "FAILED")
            self.assertEqual(result.log, "Run failed")
            self.assertIsNone(result.error)

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
            self.assertEqual(result.status, "WARNING")
            self.assertEqual(result.log, "Run has warnings")
            self.assertIsNone(result.error)

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
            self.assertEqual(result.status, "SUCCESS")
            self.assertEqual(result.log, "Run was ok")
            self.assertIsNone(result.error)

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

            with self.assertRaises(Exception) as context:
                self.kestra.execute(
                    self.namespace,
                    self.flow + "_wrong",
                    self.inputs,
                )


if __name__ == "__main__":
    unittest.main()
