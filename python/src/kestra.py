import json
from datetime import datetime
import urllib
import logging
import requests
import time
from collections import namedtuple

class Kestra:
    API_ENDPOINT_EXECUTION_CREATE: str = "/api/v1/executions/trigger/PARAM_FLOW_ID"
    API_ENDPOINT_EXECUTION_STATUS: str = "/api/v1/executions/PARAM_EXECUTION_ID"
    API_ENDPOINT_EXECUTION_LOG: str = "/api/v1/logs/PARAM_EXECUTION_ID/download"

    def __init__(self):
        pass

    @staticmethod
    def _send(map):
        print("::" + json.dumps(map) + "::")

    @staticmethod
    def _metrics(name, type, value, tags=None):
        Kestra._send({
            "metrics": [
                {
                    "name": name,
                    "type": type,
                    "value": value,
                    "tags": tags or {}
                }
            ]
        })

    @staticmethod
    def outputs(map):
        Kestra._send({
            "outputs": map
        })

    @staticmethod
    def counter(name, value, tags=None):
        Kestra._metrics(name, "counter", value, tags)

    @staticmethod
    def timer(name, duration, tags=None):
        if callable(duration):
            start = datetime.now()
            duration()
            Kestra._metrics(name, "timer", (datetime.now().microsecond - start.microsecond) / 1000, tags)
        else:
            Kestra._metrics(name, "timer", duration, tags)

    @staticmethod
    def execute_flow(serverUrl: str, namespace: str, flow: str, parameter: dict, user: str, password: str):
        """Method to execute a specific flow on a Kestra server"""

        logging.info('Starting flow "' + flow + '" in namespace "' + namespace + '" with parameters ' + str(parameter))

        result = namedtuple("FlowExecution", ["status", "log", "error"])

        try:

            if len(parameter) > 0:
                labels = "?"
                for key in parameter:
                    labels = labels + "labels=" + urllib.parse.quote(key) + ":" + urllib.parse.quote(parameter[key])

                response = requests.post(
                    serverUrl + Kestra.API_ENDPOINT_EXECUTION_CREATE.replace('PARAM_FLOW_ID', namespace + "/" + flow) + labels, files=parameter).json()
            else:
                response = requests.post(
                    serverUrl + Kestra.API_ENDPOINT_EXECUTION_CREATE.replace('PARAM_FLOW_ID', namespace + "/" + flow)).json()
            
            if not "id" in response:
                raise Exception("Starting execution failed: " + str(response))

            executionId = response['id']

            finished = False

            while not finished:
                response = requests.get(
                    serverUrl + Kestra.API_ENDPOINT_EXECUTION_STATUS.replace('PARAM_EXECUTION_ID', executionId)).json()
                
                if "SUCCESS" in response['state']['current']:
                    log = requests.get(
                        serverUrl + Kestra.API_ENDPOINT_EXECUTION_LOG.replace('PARAM_EXECUTION_ID', executionId))
                    logging.info('Execution of flow ' + flow + ' in Namespace ' + namespace + ' with parameters ' + str(parameter) + ' was successful: \n\n' + str(log.text))
                    result.status = response['state']['current']
                    result.log = str(log.text)
                    result.error = None
                    finished = True
                elif "WARNING" in response['state']['current']:
                    log = requests.get(serverUrl + Kestra.API_ENDPOINT_EXECUTION_LOG.replace('PARAM_EXECUTION_ID', executionId))
                    logging.info('Execution of flow ' + flow + ' in Namespace ' + namespace + ' with parameters ' + str(parameter) + ' was successful but with warning: \n\n' + str(log.text))
                    result.status = response['state']['current']
                    result.log = str(log.text)
                    result.error = None
                    finished = True
                elif "FAILED" in response['state']['current']:
                    log = requests.get(
                        serverUrl + Kestra.API_ENDPOINT_EXECUTION_LOG.replace('PARAM_EXECUTION_ID', executionId))
                    logging.info('Execution of flow ' + flow + ' in Namespace ' + namespace + ' with parameters ' + parameter + ' failed: \n\n' + str(log.text))
                    result.status = response['state']['current']
                    result.log = str(log.text)
                    result.error = None
                    finished = True
                time.sleep(1)

        except Exception as e:
            logging.error(f"An error occurred: {e}")
            result.error = e
            result.log = None
            result.status = "ERROR"

        return result

