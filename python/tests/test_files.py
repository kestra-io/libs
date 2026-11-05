import json
import os
import stat
import tempfile
from collections import UserDict
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

import amazon.ion.simpleion as ion
import pytest
from amazon.ion.core import IonType
from kestra import Kestra


@pytest.fixture(autouse=True)
def working_directory(tmp_path, monkeypatch):
    monkeypatch.setenv("WORKING_DIR", str(tmp_path))


@pytest.mark.parametrize("count", [0, 1, 3])
def test_files_writes_top_level_records(count, tmp_path, capsys):
    records = [
        {"id": index, "nested": {"name": "你好", "values": [True, None]}}
        for index in range(count)
    ]

    path = Path(Kestra.files(records))

    assert path.parent == tmp_path
    assert path.suffix == ".ion"
    assert path.is_file()
    if count:
        assert path.read_text(encoding="utf-8").startswith("{")
    values = ion.loads(path.read_bytes(), single_value=False)
    assert len(values) == count
    assert all(value.ion_type == IonType.STRUCT for value in values)
    assert Kestra.read(str(path)) == records
    assert capsys.readouterr().out == Kestra.format({"outputFiles": [path.name]}) + "\n"


def test_files_preserves_ion_values_and_accepts_iterators(capsys):
    timestamp = datetime(2026, 11, 3, tzinfo=timezone.utc)
    records = iter(
        [UserDict({"amount": Decimal("1.25"), "time": timestamp, "blob": b"abc"})]
    )

    path = Path(Kestra.files(records))

    value = ion.loads(path.read_bytes(), single_value=False)[0]
    assert value["amount"] == Decimal("1.25")
    assert value["time"] == timestamp
    assert value["blob"] == b"abc"
    assert list(records) == []
    assert json.loads(capsys.readouterr().out.strip()[2:-2]) == {
        "outputFiles": [path.name]
    }


def test_files_uses_unique_names():
    first = Path(Kestra.files([]))
    second = Path(Kestra.files([]))

    assert first != second
    assert first.read_bytes() == second.read_bytes()


def test_files_is_closed_before_announcement(tmp_path, monkeypatch):
    original = tempfile.NamedTemporaryFile
    created = []

    def create_file(**kwargs):
        file = original(**kwargs)
        created.append(file)
        return file

    def announce(payload):
        file = created[0]
        assert file.closed
        assert Kestra.read(file.name) == [{"id": 1}]
        assert payload == {"outputFiles": [Path(file.name).name]}

    monkeypatch.setattr(tempfile, "NamedTemporaryFile", create_file)
    monkeypatch.setattr(Kestra, "_send", announce)

    assert Path(Kestra.files([{"id": 1}])).parent == tmp_path


def test_files_honors_working_dir_even_after_chdir(tmp_path, monkeypatch):
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    monkeypatch.chdir(elsewhere)

    path = Path(Kestra.files([{"id": 1}]))

    assert path.parent == tmp_path
    assert not list(elsewhere.iterdir())


def test_files_falls_back_to_current_directory(tmp_path, monkeypatch):
    monkeypatch.delenv("WORKING_DIR")
    monkeypatch.chdir(tmp_path)

    assert Path(Kestra.files([])).parent == tmp_path


@pytest.mark.parametrize(
    "data", [None, 1, "abc", b"abc", {"id": 1}, [1], [{"id": 1}, None]]
)
def test_files_rejects_invalid_inputs_without_announcement(data, tmp_path, capsys):
    with pytest.raises(TypeError):
        Kestra.files(data)

    assert not list(tmp_path.iterdir())
    assert capsys.readouterr().out == ""


def test_files_cleans_up_after_serialization_failure(tmp_path, capsys):
    with pytest.raises(TypeError):
        Kestra.files([{"id": 1}, {"unsupported": object()}])

    assert not list(tmp_path.iterdir())
    assert capsys.readouterr().out == ""


def test_files_cleans_up_after_iterator_failure(tmp_path, capsys):
    def records():
        yield {"id": 1}
        raise RuntimeError("source failed")

    with pytest.raises(RuntimeError, match="source failed"):
        Kestra.files(records())

    assert not list(tmp_path.iterdir())
    assert capsys.readouterr().out == ""


def test_files_cleans_up_after_write_failure(tmp_path, capsys, monkeypatch):
    def fail_write(data, file, **kwargs):
        file.write(b"partial")
        raise OSError("disk full")

    monkeypatch.setattr(ion, "dump", fail_write)
    with pytest.raises(OSError, match="disk full"):
        Kestra.files([{"id": 1}])

    assert not list(tmp_path.iterdir())
    assert capsys.readouterr().out == ""


@pytest.mark.parametrize("original_error", [TypeError, OSError])
@pytest.mark.parametrize("cleanup_error", [FileNotFoundError, PermissionError])
def test_files_preserves_original_error_when_cleanup_fails(
    original_error, cleanup_error, tmp_path, capsys, monkeypatch
):
    original = original_error("serialization or write failed")
    unlink = os.unlink

    def fail_write(data, file, **kwargs):
        file.write(b"partial")
        raise original

    def fail_unlink(path):
        if cleanup_error is FileNotFoundError:
            unlink(path)
        raise cleanup_error("cleanup failed")

    monkeypatch.setattr(ion, "dump", fail_write)
    monkeypatch.setattr(os, "unlink", fail_unlink)

    with pytest.raises(type(original)) as error:
        Kestra.files([{"id": 1}])

    assert error.value is original
    assert capsys.readouterr().out == ""
    assert bool(list(tmp_path.iterdir())) is (cleanup_error is PermissionError)


@pytest.mark.skipif(os.name != "posix", reason="POSIX file permissions")
def test_files_keeps_temporary_file_private():
    path = Path(Kestra.files([{"id": 1}]))

    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_files_does_not_announce_when_creation_fails(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("WORKING_DIR", str(tmp_path / "missing"))

    with pytest.raises(FileNotFoundError):
        Kestra.files([])

    assert not list(tmp_path.iterdir())
    assert capsys.readouterr().out == ""
