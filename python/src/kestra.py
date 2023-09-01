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
    This class allows you to execute a Kestra flow.

    Trigger a flow and wait for completion:
        from kestra import Flow
        flow = Flow()
        flow.execute('mynamespace', 'myflow', {'param': 'value'})

    Fire and forget:
        from kestra import Flow
        flow = Flow(wait_for_completion=False)
        flow.execute('mynamespace', 'myflow', {'param': 'value'})

    Overwrite the username and password:
        from kestra import Flow
        flow = Flow()
        flow.user = 'admin'
        flow.password = 'admin'
        flow.execute('mynamespace', 'myflow')
    """
    API_ENDPOINT_EXECUTION_CREATE: str = "/api/v1/executions/trigger/PARAM_FLOW_ID"
    API_ENDPOINT_EXECUTION_STATUS: str = "/api/v1/executions/PARAM_EXECUTION_ID"
    API_ENDPOINT_EXECUTION_LOG: str = "/api/v1/logs/PARAM_EXECUTION_ID/download"

    def __init__(self, wait_for_completion: bool = True, poll_interval: int = 1):
        # Get username and password from environment variables, if available
        self.wait_for_completion = wait_for_completion
        self.poll_interval = poll_interval
        self.user = os.environ.get("KESTRA_USER", None)
        self.password = os.environ.get("KESTRA_PASSWORD", None)
        self.hostname = os.environ.get("KESTRA_HOSTNAME", "http://localhost:8080")

    def _make_request(self, method, url, **kwargs) -> requests.Response:
        """
        Make a request to the Kestra server, adding authentication if if username and password are set
        :param method: can be 'get', 'post', 'put', 'delete', etc.
        :param url: the URL of your Kestra server e.g. "http://localhost:8080"
        :param kwargs: additional arguments to pass to the request e.g. json, files, etc.
        :return: the response from the server
        """
        if self.user is not None and self.password is not None:
            kwargs["auth"] = (self.user, self.password)
        response = requests.request(method, url, **kwargs)
        # Check if unauthorized (status code 401)
        if response.status_code == 401:
            raise Exception(
                "Authentication required but not provided. Please set the username and password."
            )

        # If the response indicates another type of error, raise it
        response.raise_for_status()
        return response

    def execute(
        self,
        namespace: str,
        flow: str,
        parameter: dict = None,
    ) -> namedtuple:
        if parameter is None:
            parameter = {}

        logging.info(
            "Starting flow %s in namespace %s with parameters %s",
            flow,
            namespace,
            str(parameter),
        )
        result = namedtuple("FlowExecution", ["status", "log", "error"])
        url_default = self.hostname + Flow.API_ENDPOINT_EXECUTION_CREATE.replace(
            "PARAM_FLOW_ID", namespace + "/" + flow
        )
        try:
            if len(parameter) > 0:
                labels = "?"
                for key in parameter:
                    key_ = urllib.parse.quote(key)
                    value_ = urllib.parse.quote(parameter[key])
                    labels = f"{labels}labels={key_}:{value_}"

                url = url_default + labels
                response = self._make_request("post", url, files=parameter)
                response = response.json()
            else:
                response = self._make_request("post", url_default)
                response = response.json()

            if "id" not in response:
                raise Exception("Starting execution failed: " + str(response))

            execution_id = response["id"]
            if self.wait_for_completion:
                finished = False
                while not finished:
                    response = self._make_request(
                        "get",
                        self.hostname
                        + Flow.API_ENDPOINT_EXECUTION_STATUS.replace(
                            "PARAM_EXECUTION_ID", execution_id
                        ),
                    )
                    response = response.json()

                    if "SUCCESS" in response["state"]["current"]:
                        log = self._make_request(
                            "get",
                            self.hostname
                            + Flow.API_ENDPOINT_EXECUTION_LOG.replace(
                                "PARAM_EXECUTION_ID", execution_id
                            ),
                        )

                        logging.info(
                            "Execution of flow %s in Namespace %s with parameters %s was successful \n%s",
                            flow,
                            namespace,
                            str(parameter),
                            str(log.text),
                        )

                        result.status = response["state"]["current"]
                        result.log = str(log.text)
                        result.error = None
                        finished = True
                    elif "WARNING" in response["state"]["current"]:
                        log = self._make_request(
                            "get",
                            self.hostname
                            + Flow.API_ENDPOINT_EXECUTION_LOG.replace(
                                "PARAM_EXECUTION_ID", execution_id
                            ),
                        )

                        logging.info(
                            "Execution of flow %s in Namespace %s with parameters %s was successful but with warning \n%s",
                            flow,
                            namespace,
                            str(parameter),
                            str(log.text),
                        )

                        result.status = response["state"]["current"]
                        result.log = str(log.text)
                        result.error = None
                        finished = True
                    elif "FAILED" in response["state"]["current"]:
                        log = self._make_request(
                            "get",
                            self.hostname
                            + Flow.API_ENDPOINT_EXECUTION_LOG.replace(
                                "PARAM_EXECUTION_ID", execution_id
                            ),
                        )

                        logging.info(
                            "Execution of flow %s in Namespace %s with parameters %s failed \n%s",
                            flow,
                            namespace,
                            str(parameter),
                            str(log.text),
                        )

                        result.status = response["state"]["current"]
                        result.log = str(log.text)
                        result.error = None
                        finished = True
                    time.sleep(self.poll_interval)
            else:
                logging.info(
                    "Successfully triggered execution: %s/ui/executions/%s/%s/%s",
                    self.hostname,
                    namespace,
                    flow,
                    execution_id,
                )
                result.status = "STARTED"
                result.log = None
                result.error = None
        except Exception as e:
            result.error = e
            result.log = None
            result.status = "ERROR"
            raise e

        return result
