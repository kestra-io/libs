# Kestra Python Client

This Python client provides functionality to interact with the Kestra server for sending metrics, outputs, and logs, as well as executing flows.

## Installation

```bash
pip install kestra
```

## Kestra Class

The `Kestra` class is responsible for sending metrics, outputs, and logs to the Kestra server.

### Methods

- **_send(map_: dict)**: Sends a message to the Kestra server.
- **format(map_: dict) -> str**: Formats a message to be sent to the Kestra server.
- **_metrics(name: str, type_: str, value: int, tags: dict | None = None)**: Sends a metric to the Kestra server.
- **outputs(map_: dict)**: Sends outputs to the Kestra server.
- **counter(name: str, value: int, tags: dict | None = None)**: Sends a counter to the Kestra server.
- **timer(name: str, duration: int | Callable, tags: dict | None = None)**: Sends a timer to the Kestra server.
- **logger() -> Logger**: Retrieves the logger for the Kestra server.

## Flow Class

The `Flow` class is used to execute a Kestra flow and optionally wait for its completion. It can also be used to get the status of an execution and the logs of an execution.

### Initialization

```python
flow = Flow(
  wait_for_completion=True,
  poll_interval=1,
  labels_from_inputs=False,
  tenant=None
)
```


### Methods

- **_make_request(method: str, url: str, \*\*kwargs) -> requests.Response**: Makes a request to the Kestra server with optional authentication and retries.
- **check_status(execution_id: str) -> requests.Response**: Checks the status of an execution.
- **get_logs(execution_id: str) -> requests.Response**: Retrieves the logs of an execution.
- **execute(namespace: str, flow: str, inputs: dict = None) -> namedtuple**: Executes a Kestra flow and optionally waits for its completion.

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

The `Kestra` class provides a method to send outputs to the Kestra server.

```python
Kestra.outputs({"my_output": "my_value"})
```

### Counters

The `Kestra` class provides a method to send counters to the Kestra server.

```python
Kestra.counter("my_counter", 1)
```

### Timers

The `Kestra` class provides a method to send timers to the Kestra server.

```python
Kestra.timer("my_timer", 1)
```
