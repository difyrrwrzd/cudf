# Copyright (c) 2022, NVIDIA CORPORATION.

from dataclasses import dataclass
from typing import Any, Callable, Dict, Optional


@dataclass
class Option:
    default: Any
    value: Any
    description: str
    validator: Callable


_OPTIONS: Dict[str, Option] = {}


def _register_option(
    name: str, default_value: Any, description: str, validator: Callable
):
    """Register an option.

    Parameters
    ----------
    name : str
        The name of the option.
    default_value : Any
        The default value of the option.
    description : str
        A text description of the option.
    validator : Callable
        Called on the option value to check its validity. Should raise an
        error if the value is invalid.

    Raises
    ------
    BaseException
        Raised by validator if the value is invalid.
    """
    validator(default_value)
    _OPTIONS[name] = Option(
        default_value, default_value, description, validator
    )


def get_option(name: str) -> Any:
    """Get the value of option.

    Parameters
    ----------
    key : str
        The name of the option.

    Returns
    -------
    The value of the option.

    Raises
    ------
    KeyError
        If option ``name`` does not exist.
    """
    try:
        return _OPTIONS[name].value
    except KeyError:
        raise KeyError(f'"{name}" does not exist.')


def set_option(name: str, val: Any):
    """Set the value of option.

    Parameters
    ----------
    name : str
        The name of the option.
    val : Any
        The value to set.

    Raises
    ------
    KeyError
        If option ``name`` does not exist.
    BaseException
        Raised by validator if the value is invalid.
    """
    try:
        option = _OPTIONS[name]
    except KeyError:
        raise KeyError(f'"{name}" does not exist.')
    option.validator(val)
    option.value = val


def _build_option_description(name, opt):
    return (
        f"{name}:\n"
        f"\t{opt.description}\n"
        f"\t[Default: {opt.default}] [Current: {opt.value}]"
    )


def describe_option(name: Optional[str] = None):
    """Prints the description of an option.

    If `name` is unspecified, prints the description of all available options.

    Parameters
    ----------
    name : Optional[str]
        The name of the option.
    """
    names = _OPTIONS.keys() if name is None else [name]
    for name in names:
        print(_build_option_description(name, _OPTIONS[name]))
