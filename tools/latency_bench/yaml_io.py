from __future__ import annotations

from typing import Any

from yaml import CSafeDumper, CSafeLoader, dump, load


def safe_load(stream: Any) -> Any:
    """Load YAML through the required LibYAML safe loader."""
    return load(stream, Loader=CSafeLoader)


def safe_dump(data: Any, stream: Any = None, **kwargs: Any) -> Any:
    """Dump YAML through the required LibYAML safe dumper."""
    return dump(data, stream=stream, Dumper=CSafeDumper, **kwargs)
