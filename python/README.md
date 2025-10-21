# Kestra Python Client

This Python client provides functionality to interact with the Kestra server for sending metrics, outputs, and logs, as well as executing/polling flows.

## Installation

```bash
pip install kestra
```

## Kestra Class

The `Kestra` class is responsible for sending metrics, outputs, and logs to the Kestra server.

### Methods

- **\_send(map\_: dict)**: Sends a message to the Kestra server.
- **format(map\_: dict) -> str**: Formats a message to be sent to the Kestra server.
- **\_metrics(name: str, type\_: str, value: int, tags: dict | None = None)**: Sends a metric to the Kestra server.
- **outputs(map\_: dict)**: Sends outputs to the Kestra server.
- **counter(name: str, value: int, tags: dict | None = None)**: Sends a counter to the Kestra server.
- **timer(name: str, duration: int | Callable, tags: dict | None = None)**: Sends a timer to the Kestra server.
- **logger() -> Logger**: Retrieves the logger for the Kestra server.

## Flow Class

The `Flow` class is used to execute a Kestra flow and optionally wait for its completion. It can also be used to get the status of an execution and the logs of an execution.

### Initialization

```python
flow = Flow(
  wait_for_completion=True, # default is True
  poll_interval=1, # seconds. default is 1  
  labels_from_inputs=False, # default is False
  tenant=None # default is None
)
```

You can also set the hostname and authentication credentials using environment variables:

```bash
export KESTRA_HOSTNAME=http://localhost:8080
export KESTRA_USER=admin
export KESTRA_PASSWORD=admin
export KESTRA_API_TOKEN=my_api_token
```

It is worth noting that the KESTRA_API_TOKEN or KESTRA_USER and KESTRA_PASSWORD need to be used, you do not need all at once. The possible Authentication patterns are:

1. KESTRA_API_TOKEN
2. KESTRA_USER and KESTRA_PASSWORD
3. No Authentication (not recommended for production environments)

### Methods

- **_make_request(method: str, url: str, \*\*kwargs) -> requests.Response**: Makes a request to the Kestra server with optional authentication and retries.
- **check_status(execution_id: str) -> requests.Response**: Checks the status of an execution.
- **get_logs(execution_id: str) -> requests.Response**: Retrieves the logs of an execution.
- **execute(namespace: str, flow: str, inputs: dict = None) -> namedtuple**: Executes a Kestra flow and optionally waits for its completion. The namedtuple returned is a namedtuple with the following properties:
  - **status**: The status of the execution.
  - **log**: The log of the execution.
  - **error**: The error of the execution.

### Usage Examples

1. **Trigger a flow and wait for its completion:**

    ```python
    from kestra import Flow
    flow = Flow()
    flow.execute('mynamespace', 'myflow', {'param': 'value'})
    ```

2. **Set labels from inputs:**

    ```python
    from kestra import Flow
    flow = Flow(labels_from_inputs=True)
    flow.execute('mynamespace', 'myflow', {'param': 'value'})
    ```

3. **Pass a text file to an input of type FILE named 'myfile':**

    ```python
    from kestra import Flow
    flow = Flow()
    with open('example.txt', 'rb') as fh:
        flow.execute('mynamespace', 'myflow', {'files': ('myfile', fh, 'text/plain')})
    ```

4. **Fire and forget:**

    ```python
    from kestra import Flow
    flow = Flow(wait_for_completion=False)
    flow.execute('mynamespace', 'myflow', {'param': 'value'})
    ```

5. **Overwrite the username and password:**

    ```python
    from kestra import Flow
    flow = Flow()
    flow.user = 'admin'
    flow.password = 'admin'
    flow.execute('mynamespace', 'myflow')
    ```

6. **Set the hostname, username, and password using environment variables:**

    ```python
    from kestra import Flow
    import os

    os.environ["KESTRA_HOSTNAME"] = "http://localhost:8080"
    os.environ["KESTRA_USER"] = "admin"
    os.environ["KESTRA_PASSWORD"] = "admin"
    flow = Flow()
    flow.execute('mynamespace', 'myflow', {'param': 'value'})
    ```

## Error Handling

The client includes retry logic with exponential backoff for certain HTTP status codes, and raises a `FailedExponentialBackoff` exception if the request fails after multiple retries.

## Kestra Class

### Logging

The `Kestra` class provides a logger that formats logs in JSON format, making it easier to integrate with log management systems.

```python
from kestra import Kestra

Kestra.logger().info("Hello, world!")
```

### Outputs

The `Kestra` class provides a method to send key-value-based outputs to
the Kestra server. If you want to output large objects, write them to a
file and specify them within the `outputFiles` property of the Python
script task.

```python
Kestra.outputs({"my_output": "my_value"})
```

### Counters

The `Kestra` class provides a method to send counter metrics to the Kestra server.

```python
Kestra.counter("my_counter", 1)
```

### Timers

The `Kestra` class provides a method to send timer metrics to the Kestra server.

```python
Kestra.timer("my_timer", 1)
```

### Gauges

The `Kestra` class provides a method to send gauge metrics to the Kestra server.

```python
Kestra.gauge("my_gauge", 42.5)
```

## Kestra Ion

The `Kestra` ION extra provides a method to read files and convert them to a list of dictionaries.

### Installation

```bash
pip install kestra[ion]
```
### Methods

- **read(path_: str) -> list[dict[str, Any]]**: Reads an Ion file and converts it to a list of dictionaries.

### Usage Example

```python
import pandas as pd
import requests
from kestra import Kestra

file_path = "employees.ion"
url = "https://huggingface.co/datasets/kestra/datasets/resolve/main/ion/employees.ion"
response = requests.get(url)
if response.status_code == 200:
    with open(file_path, "wb") as file:
        file.write(response.content)
else:
    print(f"Failed to download the file. Status code: {response.status_code}")


data = Kestra.read(file_path)
df = pd.DataFrame(data)
print(df.info())
```


