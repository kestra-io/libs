import base64
import json

import pytest

import kestra
from kestra import ExecutionContext, load_execution_context

CONTEXT = {
    "labels": {"env": "prod"},
    "inputs": {"my_input": "a\nmultiline \"value\""},
    "vars": {"my_var": 42},
    "trigger": {"startDate": "2025-01-01T00:00:00Z"},
    "outputs": {"prev_task": {"uri": "kestra:///my/file.csv"}},
}


@pytest.fixture
def context_file(tmp_path, monkeypatch):
    path = tmp_path / ".kestra-execution-context.json"
    path.write_text(json.dumps(CONTEXT))
    monkeypatch.setenv("KESTRA_EXECUTION_CONTEXT_FILE", str(path))
    monkeypatch.setattr(kestra, "_context", None)

    return path


def test_context_from_file(context_file):
    assert kestra.context.labels == {"env": "prod"}
    assert kestra.context.inputs.my_input == 'a\nmultiline "value"'
    assert kestra.context.vars.my_var == 42
    assert kestra.context.trigger.startDate == "2025-01-01T00:00:00Z"
    assert kestra.context.outputs.prev_task.uri == "kestra:///my/file.csv"


def test_context_is_loaded_once(context_file):
    context = kestra.context
    context_file.unlink()

    assert kestra.context is context


def test_explicit_path(tmp_path):
    path = tmp_path / "context.json"
    path.write_text(json.dumps(CONTEXT))

    assert load_execution_context(str(path)).labels.env == "prod"


def test_base64_env_fallback(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("KESTRA_CONTEXT", base64.b64encode(json.dumps(CONTEXT).encode()).decode())

    assert load_execution_context().outputs.prev_task.uri == "kestra:///my/file.csv"


def test_missing_context(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("KESTRA_CONTEXT", raising=False)
    monkeypatch.delenv("KESTRA_EXECUTION_CONTEXT_FILE", raising=False)

    with pytest.raises(FileNotFoundError, match="No Kestra execution context found"):
        load_execution_context()


def test_missing_key_lists_available_keys():
    context = ExecutionContext({"labels": {}, "inputs": {}})

    with pytest.raises(AttributeError, match="'vars' is not available.*inputs, labels"):
        context.vars


def test_dict_helpers():
    context = ExecutionContext(CONTEXT)

    assert "labels" in context
    assert sorted(context) == ["inputs", "labels", "outputs", "trigger", "vars"]
    assert context.to_dict() is CONTEXT
    assert context["labels"] == {"env": "prod"}
    assert context.get("nope", "default") == "default"
    assert context.get("labels").env == "prod"


def test_module_getattr_still_raises_for_unknown():
    with pytest.raises(AttributeError, match="has no attribute 'nope'"):
        kestra.nope
