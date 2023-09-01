import json
from datetime import datetime
import urllib
import logging
import requests
import time
from collections import namedtuple
import os


logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)


class Kestra:
    def __init__(self):
        pass

    @staticmethod
    def _send(map_):
        print("::" + json.dumps(map_) + "::")

    @staticmethod
    def _metrics(name, type_, value, tags=None):
        Kestra._send(
            {
                "metrics": [
                    {"name": name, "type": type_, "value": value, "tags": tags or {}}
                ]
            }
        )

    @staticmethod
    def outputs(map_):
        Kestra._send({"outputs": map_})

    @staticmethod
    def counter(name, value, tags=None):
        Kestra._metrics(name, "counter", value, tags)

    @staticmethod
    def timer(name, duration, tags=None):
        if callable(duration):
            start = datetime.now()
            duration()
            Kestra._metrics(
                name,
                "timer",
                (datetime.now().microsecond - start.microsecond) / 1000,
                tags,
            )
        else:
            Kestra._metrics(name, "timer", duration, tags)


class Flow:
    """
    Execute a Kestra flow and optionally wait for its completion.

    Example — trigger a flow and wait for its completion:
        from kestra import Flow
        flow = Flow()
        flow.execute('mynamespace', 'myflow', {'param': 'value'})

    Example — set labels from inputs:
        from kestra import Flow
        flow = Flow(labels_from_inputs=True)
        flow.execute('mynamespace', 'myflow', {'param': 'value'})

    Example — pass a text file to an input of type FILE named 'myfile':
        from kestra import Flow
        flow = Flow()
        with open('example.txt', 'rb') as fh:
            flow.execute('mynamespace', 'myflow', {'files': ('myfile', fh, 'text/plain')})

    Example — fire and forget:
        from kestra import Flow
        flow = Flow(wait_for_completion=False)
        flow.execute('mynamespace', 'myflow', {'param': 'value'})

    Example — overwrite the username and password:
        from kestra import Flow
        flow = Flow()
        flow.user = 'admin'
        flow.password = 'admin'
        flow.execute('mynamespace', 'myflow')

    Example — set the hostname, username and password using environment variables:
        from kestra import Flow
        import os

        os.environ["KESTRA_HOSTNAME"] = "http://localhost:8080"
        os.environ["KESTRA_USER"] = "admin"
        os.environ["KESTRA_PASSWORD"] = "admin"
        flow = Flow()
        flow.execute('mynamespace', 'myflow', {'param': 'value'})
    """

    API_ENDPOINT_EXECUTION_CREATE: str = "/api/v1/executions/trigger/PARAM_FLOW_ID"
    API_ENDPOINT_EXECUTION_STATUS: str = "/api/v1/executions/PARAM_EXECUTION_ID"
    API_ENDPOINT_EXECUTION_LOG: str = "/api/v1/logs/PARAM_EXECUTION_ID/download"

    def __init__(
        self,
        wait_for_completion: bool = True,
        poll_interval: int = 1,
        labels_from_inputs: bool = False,
    ) -> None:
        """
        Get username and password from environment variables, if available
        :param wait_for_completion: whether to wait for the flow to complete
        :param poll_interval: how often to poll the server for the status of the flow
        :param labels_from_inputs: whether to use the inputs as execution labels
        """
        self.wait_for_completion = wait_for_completion
        self.poll_interval = poll_interval
        self.labels_from_inputs = labels_from_inputs
        self.user = os.environ.get("KESTRA_USER", None)
        self.password = os.environ.get("KESTRA_PASSWORD", None)
        self.hostname = os.environ.get("KESTRA_HOSTNAME", "http://localhost:8080")

    def _make_request(self, method: str, url: str, **kwargs) -> requests.Response:
        """
        Make a request to the Kestra server, add 'auth' if username and password are set
        :param method: can be 'get', 'post', 'put', 'delete', etc.
        :param url: the URL of your Kestra server e.g. "http://localhost:8080"
        :param kwargs: additional arguments to pass to the request e.g. json, files, etc.
        :return: the response from the server
        """
        if self.user is not None and self.password is not None:
            kwargs["auth"] = (self.user, self.password)
        response = requests.request(method, url, **kwargs)
        if response.status_code == 401:
            raise Exception(
                "Authentication required but not provided. Please set the username and password."
            )

        response.raise_for_status()
        return response

    def check_status(self, execution_id: str) -> requests.Response:
        """
        Check the status of the execution
        :param execution_id: the ID of the execution
        :return: the response from the server
        """
        return self._make_request(
            "get",
            self.hostname
            + Flow.API_ENDPOINT_EXECUTION_STATUS.replace(
                "PARAM_EXECUTION_ID", execution_id
            ),
        )

    def get_logs(self, execution_id: str) -> requests.Response:
        """
        Get the execution logs
        :param execution_id: the ID of the execution
        :return: the response from the server
        """
        return self._make_request(
            "get",
            self.hostname
            + Flow.API_ENDPOINT_EXECUTION_LOG.replace(
                "PARAM_EXECUTION_ID", execution_id
            ),
        )

    def execute(
        self,
        namespace: str,
        flow: str,
        inputs: dict = None,
    ) -> namedtuple:
        if inputs is None:
            inputs = {}

        logging.debug(
            "Starting a flow %s in the namespace %s with parameters %s",
            flow,
            namespace,
            str(inputs),
        )
        result = namedtuple("FlowExecution", ["status", "log", "error"])
        url_default = self.hostname + Flow.API_ENDPOINT_EXECUTION_CREATE.replace(
            "PARAM_FLOW_ID", namespace + "/" + flow
        )
        if self.labels_from_inputs and len(inputs) > 0:
            if inputs.get("files") is not None:
                raise Exception(
                    "Labels from inputs is not supported with inputs of type FILE"
                )
            labels = "?"
            for key in inputs:
                key_ = urllib.parse.quote(key)
                value_ = urllib.parse.quote(inputs[key])
                labels = f"{labels}labels={key_}:{value_}"

            url = url_default + labels
            response = self._make_request("post", url, files=inputs).json()
        elif len(inputs) > 0:
            response = self._make_request("post", url_default, files=inputs).json()
        else:
            response = self._make_request("post", url_default).json()

        if "id" not in response:
            raise Exception("Starting execution failed: " + str(response))

        execution_id = response["id"]
        logging.info(
            "Successfully triggered the execution: %s/ui/executions/%s/%s/%s",
            self.hostname,
            namespace,
            flow,
            execution_id,
        )
        if self.wait_for_completion:
            finished = False
            while not finished:
                response = self.check_status(execution_id).json()
                log = self.get_logs(execution_id)
                if "SUCCESS" in response["state"]["current"]:
                    logging.info(
                        "Execution of the flow %s in the namespace %s with parameters %s was successful \n%s",
                        flow,
                        namespace,
                        str(inputs),
                        str(log.text),
                    )
                    result.status = response["state"]["current"]
                    result.log = str(log.text)
                    result.error = None
                    finished = True
                elif "WARNING" in response["state"]["current"]:
                    logging.info(
                        "Execution of the flow %s in the namespace %s with parameters %s finished with warnings \n%s",
                        flow,
                        namespace,
                        str(inputs),
                        str(log.text),
                    )
                    result.status = response["state"]["current"]
                    result.log = str(log.text)
                    result.error = None
                    finished = True
                elif "FAILED" in response["state"]["current"]:
                    logging.info(
                        "Execution of the flow %s in the namespace %s with parameters %s failed \n%s",
                        flow,
                        namespace,
                        str(inputs),
                        str(log.text),
                    )
                    result.status = response["state"]["current"]
                    result.log = str(log.text)
                    result.error = None
                    finished = True
                time.sleep(self.poll_interval)
        else:
            result.status = "STARTED"
            result.log = None
            result.error = None

        return result
