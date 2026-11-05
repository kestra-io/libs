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
- **files(data) -> str**: Writes mapping records to an Ion file and announces it for worker collection.
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

## Execution Context

The `context` object exposes the metadata of the current execution, so scripts stay
plain Python instead of embedding Pebble expressions:

```python
import pandas as pd
from kestra import context

my_labels = context.labels
my_inputs = context.inputs
my_vars = context.vars
start_date = context.trigger.startDate
csv_path = context.outputs.prev_task.uri  # outputs from previous tasks

df = pd.read_csv(csv_path)
```

The context is read from the `.kestra-execution-context.json` file that Kestra injects
into the task working directory. Use `KESTRA_EXECUTION_CONTEXT_FILE` to read it from
another path, or set the base64-encoded `KESTRA_CONTEXT` environment variable when no
file is available.

It is loaded lazily on first access and raises a `FileNotFoundError` when the script
does not run inside a Kestra task.

Nested objects are wrapped, including those inside lists, so any depth can be
traversed with attributes: `context.inputs.my_list[0].my_key`.

`context` is a read-only `Mapping`, so `len()`, `in`, iteration, `keys()`, `values()`,
`items()`, `get()` and `dict(context)` all work as expected.

### Methods

- **context[name]**: Same as attribute access. Required for keys that are not valid Python identifiers, or that collide with a method name such as `context["items"]`.
- **context.get(name, default=None)**: Returns `default` instead of raising when the key is missing.
- **context.to_dict()**: Returns the raw context as a plain `dict`, ready for `json.dumps`.
- **load_execution_context(path=None) -> ExecutionContext**: Loads the context explicitly, from `path` when given.

## Kestra Ion

Amazon Ion support is included in `pip install kestra`; `amazon.ion` is a runtime dependency.

### Writing and announcing files

```python
from pathlib import Path
from kestra import Kestra

path = Kestra.files([
    {"id": 1, "name": "Ada", "tags": ["python", "数据"]},
    {"id": 2, "name": "Grace", "active": True},
])
Kestra.outputs({"filename": Path(path).name})
```

`files(data)` accepts an iterable of mappings, including generators (consumed once).
A single mapping, strings, bytes, scalars, and non-mapping records raise `TypeError`.
Each record is written as a separate top-level Ion struct, preserving nested values
supported by `amazon.ion`. Text Ion (`binary=False`) is intentional: newline-separated
records remain human-readable and compatible with Kestra's text Ion streams and
`Kestra.read()`. Binary Ion can be smaller, but is not emitted by this helper.
No pandas conversion or custom serialization is performed.
An empty iterable creates and announces an empty file; `Kestra.read(path)` returns `[]`.
Serialization, iteration, and write failures propagate without a successful
announcement. Partial-file removal is best effort: a missing file or another OS
cleanup error never masks the original exception. If deletion fails, the partial
file may remain until the task working directory is cleaned up.

The method returns an absolute **local file path**, not a Kestra storage URI. It creates
a unique `.ion` file in `WORKING_DIR`, falling back to the current directory outside
Kestra, closes it, then prints `::{"outputFiles": ["<filename>.ion"]}::`.
The file remains available after return. The worker may remove it during collection;
otherwise it is removed with the task working directory. Downstream tasks use the URI from
`outputs.producer.outputFiles[outputs.producer.vars.filename]` through `inputFiles`,
then call `Kestra.read()` on that local input file.

Automatic persistence requires the companion worker functionality in
[kestra-io/kestra#22272](https://github.com/kestra-io/kestra/pull/22272) for top-level
`outputFiles` announcements. Do not release this helper before that core functionality
is released; no minimum compatible worker version is claimed yet. Installing a client
library that emits the marker alone does not enable persistence.
The companion implementation supports Process and
Docker with `wait: true` and `fileHandlingStrategy: VOLUME`. Received announcements
from remote runners or other Docker configurations are rejected; remote directory
synchronization alone does not enable this feature. Asynchronous Docker does not
consume task logs, so it cannot observe or persist these announcements.

Dynamic collection requires a worker filesystem with Java `SecureDirectoryStream`
support and rejects symbolic links. Filesystems without that capability fail closed
instead of using unsafe path-based uploads; Windows workers are not supported.
Docker dynamic extraction also requires a worker-controlled staging parent and
same-filesystem atomic moves. Ordinary Docker VOLUME downloads without announcements
retain their existing support and do not require secure directory streams.
Without companion support, declare a matching task-level `outputFiles` pattern.
With this companion implementation on an unsupported runner, write Ion files directly
and use configured `outputFiles` instead of emitting `Kestra.files()` announcements.

The helper retains `NamedTemporaryFile`'s private POSIX permissions (`0600`); it does
not make generated data group- or world-readable. With Docker VOLUME, the daemon
returns an archive and the worker creates its own local files with those permissions,
so a different producer-container UID alone does not prevent worker collection.
Another unprivileged UID reading the original file inside the container volume can
receive `PermissionError`; direct shared-filesystem access also requires compatible
ownership or explicit access provisioning. Docker MOUNT announcements remain unsupported.
Do not broaden file permissions merely to bypass this restriction.

JavaScript parity is a follow-up requirement tracked by
[kestra-io/libs#8](https://github.com/kestra-io/libs/issues/8); the equivalent helper
in `javascript/` and a dedicated follow-up issue remain to be completed.

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


