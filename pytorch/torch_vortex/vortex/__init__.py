"""Vortex device module — registered via torch._register_device_module("vortex", ...).

Provides the Python-level device management API:
    torch.vortex.device_count()
    torch.vortex.current_device()
    torch.vortex.set_device(0)
    with torch.vortex.device(0): ...
"""

import torch

import torch_vortex._C  # type: ignore[misc]
from . import meta  # noqa: F401
from .amp import get_amp_supported_dtype  # noqa: F401


_initialized = False
_is_in_bad_fork = getattr(torch_vortex._C, "_isInBadFork", lambda: False)


class device:
    """Context-manager that selects a Vortex device.

    Args:
        device: device index to select. No-op if negative or None.
    """

    def __init__(self, device):
        self.idx = torch.accelerator._get_device_index(device, optional=True)
        self.prev_idx = -1

    def __enter__(self):
        self.prev_idx = torch_vortex._C._exchangeDevice(self.idx)

    def __exit__(self, type, value, traceback):
        torch_vortex._C._set_device(self.prev_idx)
        return False


def is_available() -> bool:
    """Return True if at least one Vortex device is available."""
    return device_count() > 0


def device_count() -> int:
    """Return the number of Vortex devices."""
    return torch_vortex._C._get_device_count()


def current_device() -> int:
    """Return the index of the currently selected Vortex device."""
    return torch_vortex._C._get_device()


def set_device(device) -> None:
    """Set the current Vortex device."""
    if isinstance(device, int) and device >= 0:
        torch_vortex._C._set_device(device)


def get_device_properties(device=None):
    """Return a dict of Vortex device properties."""
    _lazy_init()
    props = {}
    try:
        props["global_mem_size"] = torch_vortex._C._get_global_mem_size()
    except Exception:
        pass
    return props


def _resolve_device_index(device=None):
    if device is None:
        return current_device()
    if isinstance(device, int):
        return device
    return torch.accelerator._get_device_index(device, optional=False)


def empty_cache() -> None:
    """Release all currently cached free blocks back to the Vortex runtime."""
    _lazy_init()
    torch_vortex._C._empty_cache()


def memory_allocated(device=None) -> int:
    """Return active tensor memory (bytes) on the selected Vortex device."""
    _lazy_init()
    return torch_vortex._C._memory_allocated(_resolve_device_index(device))


def memory_reserved(device=None) -> int:
    """Return memory (bytes) held by the allocator on the selected device."""
    _lazy_init()
    return torch_vortex._C._memory_reserved(_resolve_device_index(device))


def max_memory_allocated(device=None) -> int:
    """Return peak active tensor memory (bytes) since last reset."""
    _lazy_init()
    return torch_vortex._C._max_memory_allocated(_resolve_device_index(device))


def max_memory_reserved(device=None) -> int:
    """Return peak allocator-reserved memory (bytes) since last reset."""
    _lazy_init()
    return torch_vortex._C._max_memory_reserved(_resolve_device_index(device))


def reset_peak_memory_stats(device=None) -> None:
    """Reset peak memory statistics for the selected Vortex device."""
    _lazy_init()
    torch_vortex._C._reset_peak_memory_stats(_resolve_device_index(device))


def is_allocator_caching_enabled() -> bool:
    """Return True when allocator runs in cached mode."""
    _lazy_init()
    return bool(torch_vortex._C._is_allocator_caching_enabled())


def synchronize(device=None):
    """Wait for all pending Vortex operations to complete."""
    _lazy_init()
    # Vortex runtime is synchronous by default, but this ensures
    # any background work is done.
    # In future, call vortexDeviceSynchronize() via _C binding


def init():
    """Initialize the Vortex backend."""
    _lazy_init()


def is_initialized() -> bool:
    return _initialized and not _is_in_bad_fork()


def _lazy_init():
    global _initialized
    if is_initialized():
        return
    if _is_in_bad_fork():
        raise RuntimeError(
            "Cannot re-initialize Vortex in forked subprocess. "
            "Use the 'spawn' start method for multiprocessing."
        )
    torch_vortex._C._init()
    _initialized = True


from .random import *  # noqa: F403


__all__ = [
    "device",
    "device_count",
    "current_device",
    "set_device",
    "get_device_properties",
    "synchronize",
    "is_available",
    "init",
    "is_initialized",
    "empty_cache",
    "memory_allocated",
    "memory_reserved",
    "max_memory_allocated",
    "max_memory_reserved",
    "reset_peak_memory_stats",
    "is_allocator_caching_enabled",
    "initial_seed",
    "manual_seed",
    "manual_seed_all",
    "get_rng_state",
    "set_rng_state",
]
