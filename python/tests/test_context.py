import base64
import copy
import json
import pickle

import pytest

import kestra
from kestra import ExecutionContext, load_execution_context

CONTEXT = {
    "labels": {"env": "prod"},
    "inputs": {"my_input": "a\nmultiline \"value\"", "files": [{"name": "first"}, 2]},
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


def test_objects_nested_in_lists_are_wrapped():
    context = ExecutionContext(CONTEXT)

    assert context.inputs.files[0].name == "first"
    assert context.inputs.files[1] == 2


def test_is_a_mapping():
    context = ExecutionContext(CONTEXT)

    assert "labels" in context
    assert len(context) == 5
    assert sorted(context) == ["inputs", "labels", "outputs", "trigger", "vars"]
    assert dict(context.labels) == {"env": "prod"}
    assert list(context.labels.items()) == [("env", "prod")]
    assert context["labels"] == {"env": "prod"}
    assert context.get("nope", "default") == "default"
    assert context.get("labels").env == "prod"


def test_to_dict_returns_plain_types():
    context = ExecutionContext(CONTEXT)

    assert context.to_dict() is CONTEXT
    assert json.loads(json.dumps(context.to_dict())) == CONTEXT


def test_keys_shadowing_a_method_stay_reachable():
    context = ExecutionContext({"items": "not the method", "get": "neither"})

    assert context["items"] == "not the method"
    assert context["get"] == "neither"


def test_can_be_copied_and_pickled():
    context = ExecutionContext(CONTEXT)

    assert copy.copy(context).labels.env == "prod"
    assert copy.deepcopy(context).labels.env == "prod"
    assert pickle.loads(pickle.dumps(context)).labels.env == "prod"


def test_module_getattr_still_raises_for_unknown():
    with pytest.raises(AttributeError, match="has no attribute 'nope'"):
        kestra.nope


def test_repr_mirrors_the_wrapped_data():
    context = ExecutionContext({"labels": {"env": "prod"}})

    assert repr(context) == "{'labels': {'env': 'prod'}}"
    assert repr(dict(context)) == "{'labels': {'env': 'prod'}}"
