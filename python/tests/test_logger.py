import json
import logging

import pytest

from kestra import JsonFormatter


def make_record(msg="%d: %s", args=(1, "hello")) -> logging.LogRecord:
    record = logging.LogRecord(
        name="logger-name",
        level=logging.DEBUG,
        pathname="/path/file.py",
        lineno=10,
        msg=msg,
        args=args,
        func="test_function",
        exc_info=None,
    )
    record.created = 1584713566
    record.msecs = 123
    return record


def test_formatter():
    formatter = JsonFormatter()
    out = formatter.format(make_record())

    assert out.find('::{"logs": [') >= 0
    assert out.find("1: hello") >= 0
    assert out.find("2020-03-20T14:12:46.000Z") >= 0


class RaisingStr:
    def __str__(self):
        raise RuntimeError("boom")


class NonStringStr:
    def __str__(self):
        return 1


def generator():
    while True:
        yield 1


def self_list():
    value = [1]
    value.append(value)
    return value


def self_dict():
    value = {}
    value["self"] = value
    return value


@pytest.mark.parametrize(
    "msg, args, expected",
    [
        (RaisingStr(), None, "RaisingStr object at"),
        (NonStringStr(), None, "NonStringStr object at"),
        ("%s", (RaisingStr(),), "%s ("),
        (None, None, "None"),
        (self_list(), None, "[1, [...]]"),
        (self_dict(), None, "{'self': {...}}"),
        (generator(), None, "<generator object"),
    ],
)
def test_formatter_never_fails(msg, args, expected):
    out = JsonFormatter().format(make_record(msg, args))

    message = json.loads(out[2:-2])["logs"][0]["message"]
    assert message.startswith("2020-03-20T14:12:46.000Z - ")
    assert expected in message
