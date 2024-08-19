import logging

from kestra import JsonFormatter

def make_record() -> logging.LogRecord:
    record = logging.LogRecord(
        name="logger-name",
        level=logging.DEBUG,
        pathname="/path/file.py",
        lineno=10,
        msg="%d: %s",
        args=(1, "hello"),
        func="test_function",
        exc_info=None,
    )
    record.created = 1584713566
    record.msecs = 123
    return record

def test_formatter():
    formatter = JsonFormatter()
    out = formatter.format(make_record())

    assert out.find("::{\"logs\": ") >= 0
    assert out.find("1: hello") >= 0
