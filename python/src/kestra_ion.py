import re
from typing import Any
import amazon.ion.simpleion as ion
import dateutil.parser
from amazon.ion.simple_types import (
    IonPyBool,
    IonPyBytes,
    IonPyDecimal,
    IonPyDict,
    IonPyNull,
)


def convert_ion_types(value: Any) -> Any:
    """
    Convert Ion types to Python types.

    Args:
        value (Any): The value to convert.

    Returns:
        Any: returns the converted value
    """
    if isinstance(value, IonPyNull):
        return None
    elif isinstance(value, IonPyDecimal):
        return float(value)
    elif isinstance(value, IonPyBool):
        return bool(value)
    elif isinstance(value, IonPyBytes):
        return value.decode("utf-8")
    elif isinstance(value, IonPyDict) or isinstance(value, dict):
        return {k: convert_ion_types(v) for k, v in value.items()}
    elif isinstance(value, str):
        try:
            # Check if the value follows the expected format e.g. "LocalDateTime::'2024-04-21T13:43:24.34'"
            if value.startswith("LocalDateTime::"):
                date_str = value.split("::")[1].strip('"')
                return dateutil.parser.isoparse(date_str)
            # Use regex to check if the string is a valid ISO 8601 date
            iso_date_pattern = (
                r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"
            )
            if re.match(iso_date_pattern, value):
                return dateutil.parser.isoparse(value)
            else:
                raise ValueError("Not a valid LocalDatetime:: or ISO 8601 date")
        except ValueError:
            return value
    elif isinstance(value, list):
        return [convert_ion_types(item) for item in value]
    else:
        return value


def read_ion(path_: str) -> list[dict[str, Any]]:
    """
    Read an Ion file and convert it to a list of dictionaries.

    Args:
        path_ (str): The path to the Ion file.

    Returns:
        list[dict[str, Any]]: returns the list of dictionaries
    """
    with open(path_, "rb") as file:
        ion_content = file.read()
    ion_data = ion.loads(ion_content, single_value=False)
    list_of_dicts = [dict(record) for record in ion_data]
    list_of_dicts = [
        {k: convert_ion_types(v) for k, v in record.items()} for record in list_of_dicts
    ]
    return list_of_dicts
