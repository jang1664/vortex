"""torch_vortex — PyTorch backend for the Vortex GPGPU.

This package registers 'vortex' as a PrivateUse1 device backend, enabling:
    torch.device("vortex")
    torch.tensor([1, 2, 3], device="vortex")
    tensor.to("vortex")

Environment variables (optional — auto-detected when possible):
    VORTEX_HOME       Root of the Vortex source tree.
    VORTEX_DRIVER     Driver backend: simx (default), rtlsim, opae, xrt.
"""

import ctypes
import os
import sys

import torch


# ---------------------------------------------------------------------------
#  Locate the Vortex runtime libraries and pre-load them so that the native
#  extension (_C) can find ``libvortex.so`` and the driver plug-in
#  (``libvortex-<driver>.so`` / ``libsimx.so`` etc.) without requiring the
#  user to set LD_LIBRARY_PATH manually.
# ---------------------------------------------------------------------------

def _find_vortex_runtime_dir() -> str:
    """Return the directory that contains the Vortex runtime shared libraries.

    Search order
    1. ``<torch_vortex>/lib``  (bundled copies — preferred)
    2. ``$VORTEX_HOME/build/runtime``
    3. ``<torch_vortex>/../../build/runtime``   (relative to this package when
       the repo layout is ``vortex/pytorch/torch_vortex``)
    """
    _this_dir = os.path.dirname(os.path.abspath(__file__))

    # 1. Bundled inside the package (copied at install time by CMake)
    candidate = os.path.join(_this_dir, "lib")
    if os.path.isfile(os.path.join(candidate, "libvortex.so")):
        return candidate

    # 2. Explicit env-var
    vhome = os.environ.get("VORTEX_HOME", "")
    if vhome:
        candidate = os.path.join(vhome, "build", "runtime")
        if os.path.isfile(os.path.join(candidate, "libvortex.so")):
            return candidate

    # 3. Relative to this file:  torch_vortex/ -> pytorch/ -> vortex/
    candidate = os.path.normpath(os.path.join(_this_dir, "..", "..", "build", "runtime"))
    if os.path.isfile(os.path.join(candidate, "libvortex.so")):
        return candidate

    return ""


def _preload_vortex_libs() -> None:
    """Pre-load the Vortex runtime libraries with ctypes so that the C++
    extension and its ``dlopen`` calls succeed."""
    rt_dir = _find_vortex_runtime_dir()
    if not rt_dir:
        return  # best-effort — fall through to normal linker search

    driver = os.environ.get("VORTEX_DRIVER", "simx")

    # Load order matters: deepest dependency first.
    # libvortex-simx.so  ->  libsimx.so
    # libvortex-rtlsim.so -> librtlsim.so  (etc.)
    _inner_lib = {
        "simx": "libsimx.so",
        "rtlsim": "librtlsim.so",
        "opae": "libopae-c-sim.so",
        "xrt": "libxrtsim.so",
    }

    for name in [
        _inner_lib.get(driver, ""),       # e.g. libsimx.so
        f"libvortex-{driver}.so",         # e.g. libvortex-simx.so
        "libvortex.so",                   # the main stub library
    ]:
        if not name:
            continue
        path = os.path.join(rt_dir, name)
        if os.path.isfile(path):
            ctypes.CDLL(path, mode=ctypes.RTLD_GLOBAL)


_preload_vortex_libs()

# ---------------------------------------------------------------------------
# Tell the C++ native kernels where to find bundled .vxbin files
# ---------------------------------------------------------------------------
_this_dir = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault("TORCH_VORTEX_PACKAGE_DIR", _this_dir)

# ---------------------------------------------------------------------------

import torch_vortex._C  # type: ignore[misc]
import torch_vortex.vortex


_registered = False


def _register_backend():
    """Register 'vortex' as the PrivateUse1 backend name (idempotent)."""
    global _registered
    if _registered:
        return
    torch.utils.rename_privateuse1_backend("vortex")
    torch._register_device_module("vortex", torch_vortex.vortex)
    torch.utils.generate_methods_for_privateuse1_backend(for_storage=True)
    _registered = True


def _autoload():
    """Entry point for torch.backends autoloading.

    When ``import torch`` triggers autoloading, the module body above has
    already executed (loading ``_C`` and ``vortex`` submodules), but the
    registration calls are deferred to here so that ``torch`` is fully
    initialized.
    """
    _register_backend()


# When the user does ``import torch_vortex`` explicitly (after torch is
# fully loaded), register immediately.  During autoload (from inside
# ``import torch``), this may fail and will be retried by ``_autoload()``.
try:
    _register_backend()
except Exception:
    pass
