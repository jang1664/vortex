"""Random number generation utilities for Vortex device."""

import torch

import torch_vortex._C  # type: ignore[misc]
from . import _lazy_init, current_device, device_count


__all__ = [
    "get_rng_state",
    "set_rng_state",
    "manual_seed",
    "manual_seed_all",
    "initial_seed",
]


def get_rng_state(device="vortex"):
    """Get the random number generator state for a Vortex device."""
    if isinstance(device, str):
        device = torch.device(device)
    elif isinstance(device, int):
        device = torch.device("vortex", device)
    idx = device.index
    if idx is None:
        idx = current_device()
    default_generator = torch_vortex._C._get_default_generator(idx)
    return default_generator.get_state()


def set_rng_state(new_state, device="vortex"):
    """Set the random number generator state for a Vortex device."""
    if isinstance(device, str):
        device = torch.device(device)
    elif isinstance(device, int):
        device = torch.device("vortex", device)
    idx = device.index
    if idx is None:
        idx = current_device()
    default_generator = torch_vortex._C._get_default_generator(idx)
    default_generator.set_state(new_state)


def initial_seed() -> int:
    """Return the initial seed of the current Vortex device."""
    _lazy_init()
    idx = current_device()
    default_generator = torch_vortex._C._get_default_generator(idx)
    return default_generator.initial_seed()


def manual_seed(seed: int) -> None:
    """Set the seed for the current Vortex device."""
    seed = int(seed)
    idx = current_device()
    default_generator = torch_vortex._C._get_default_generator(idx)
    default_generator.manual_seed(seed)


def manual_seed_all(seed: int) -> None:
    """Set the seed for all Vortex devices."""
    seed = int(seed)
    for idx in range(device_count()):
        default_generator = torch_vortex._C._get_default_generator(idx)
        default_generator.manual_seed(seed)
