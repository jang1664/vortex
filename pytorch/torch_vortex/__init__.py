"""torch_vortex — PyTorch backend for the Vortex GPGPU.

This package registers 'vortex' as a PrivateUse1 device backend, enabling:
    torch.device("vortex")
    torch.tensor([1, 2, 3], device="vortex")
    tensor.to("vortex")

Environment variables (optional — auto-detected when possible):
    VORTEX_HOME       Root of the Vortex source tree.
    VORTEX_DRIVER     Driver backend: simx (default), rtlsim, opae, xrt, xrt_vcs.
    FPGA_BIN_DIR      Directory containing vortex_afu.xclbin (xrt only;
                      auto-detected from VORTEX_HOME if not set).
    XRT_XCLBIN_PATH   Full path to the FPGA bitstream (derived from
                      FPGA_BIN_DIR when not set explicitly).
    XRT_DEVICE_INDEX  FPGA device index (default: 0).
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


def _find_fpga_bin_dir() -> str:
    """Auto-detect the FPGA binary directory containing ``vortex_afu.xclbin``.

    Search order
    1. ``$FPGA_BIN_DIR``  (explicit)
    2. ``$VORTEX_HOME/hw/syn/xilinx/xrt/*_hw/bin/``  (most recent first)
    """
    fpga_bin = os.environ.get("FPGA_BIN_DIR", "")
    if fpga_bin and os.path.isfile(os.path.join(fpga_bin, "vortex_afu.xclbin")):
        return fpga_bin

    vhome = os.environ.get("VORTEX_HOME", "")
    if vhome:
        xrt_syn = os.path.join(vhome, "hw", "syn", "xilinx", "xrt")
        if os.path.isdir(xrt_syn):
            candidates = []
            for entry in os.listdir(xrt_syn):
                xclbin = os.path.join(xrt_syn, entry, "bin", "vortex_afu.xclbin")
                if entry.endswith("_hw") and os.path.isfile(xclbin):
                    candidates.append(xclbin)
            if candidates:
                candidates.sort(key=os.path.getmtime, reverse=True)
                return os.path.dirname(candidates[0])
    return ""


def _find_xilinx_xrt_lib() -> str:
    """Find the Xilinx XRT library directory containing ``libxrt_coreutil.so``.

    Search order
    1. ``$XILINX_XRT/lib``
    2. ``/opt/xilinx/xrt/lib``
    3. ``/opt/xilinx/xrt_versions/*/lib``  (latest version first)
    """
    xrt = os.environ.get("XILINX_XRT", "")
    if xrt:
        d = os.path.join(xrt, "lib")
        if os.path.isfile(os.path.join(d, "libxrt_coreutil.so")):
            return d
    for d in ["/opt/xilinx/xrt/lib"]:
        if os.path.isfile(os.path.join(d, "libxrt_coreutil.so")):
            return d
    versions_dir = "/opt/xilinx/xrt_versions"
    if os.path.isdir(versions_dir):
        for entry in sorted(os.listdir(versions_dir), reverse=True):
            d = os.path.join(versions_dir, entry, "lib")
            if os.path.isfile(os.path.join(d, "libxrt_coreutil.so")):
                return d
    return ""


def _setup_xrt_env() -> None:
    """Auto-configure environment variables for XRT FPGA execution.

    Derives ``XRT_XCLBIN_PATH``, ``EMCONFIG_PATH``, ``XRT_DEVICE_INDEX``,
    ``XRT_INI_PATH``, and ``SCOPE_JSON_PATH`` from ``FPGA_BIN_DIR``
    (auto-detected if not set).  Users can override any variable by setting
    it before ``import torch_vortex``.
    """
    fpga_bin = _find_fpga_bin_dir()
    if fpga_bin:
        os.environ.setdefault(
            "XRT_XCLBIN_PATH",
            os.path.join(fpga_bin, "vortex_afu.xclbin"))
        os.environ.setdefault("EMCONFIG_PATH", fpga_bin)
        scope_json = os.path.join(fpga_bin, "scope.json")
        if os.path.isfile(scope_json):
            os.environ.setdefault("SCOPE_JSON_PATH", scope_json)

    os.environ.setdefault("XRT_DEVICE_INDEX", "0")

    vhome = os.environ.get("VORTEX_HOME", "")
    if vhome:
        xrt_ini = os.path.join(vhome, "build", "runtime", "xrt", "xrt.ini")
        if os.path.isfile(xrt_ini):
            os.environ.setdefault("XRT_INI_PATH", xrt_ini)


def _resolve_driver() -> str:
    """Determine the Vortex driver backend and ensure env vars are consistent.

    Rules:
    * ``FPGA_BIN_DIR`` is set  →  driver = ``xrt``  (implicit).
    * ``VORTEX_DRIVER=xrt``    →  driver = ``xrt``, ``FPGA_BIN_DIR``
      auto-detected (default: newest ``*_hw/bin`` → typically 16-core).
    * Otherwise               →  honour ``VORTEX_DRIVER`` (default ``simx``).
    """
    fpga_bin = os.environ.get("FPGA_BIN_DIR", "")
    explicit_driver = os.environ.get("VORTEX_DRIVER", "")

    if fpga_bin:
        # User explicitly points to an FPGA directory → imply xrt
        os.environ.setdefault("VORTEX_DRIVER", "xrt")
        return "xrt"

    if explicit_driver == "xrt":
        # Driver is xrt but no FPGA_BIN_DIR given → auto-detect
        if os.environ.get("TORCH_VORTEX_XRT_VCS") == "1":
            return "xrt_vcs"
        detected = _find_fpga_bin_dir()
        if detected:
            os.environ["FPGA_BIN_DIR"] = detected
        return "xrt"

    if explicit_driver == "xrt_vcs":
        # VCS RTL simulation — same libvortex-xrt.so, just linked with
        # libxrtsim_vcs.so instead of libxrtsim.so at build time.
        # Override to "xrt" so the stub finds libvortex-xrt.so.
        # Keep TORCH_VORTEX_XRT_VCS=1 so preloading picks libxrtsim_vcs.so.
        os.environ["VORTEX_DRIVER"] = "xrt"
        os.environ["TORCH_VORTEX_XRT_VCS"] = "1"
        return "xrt_vcs"

    # Default / explicit non-xrt driver
    driver = explicit_driver if explicit_driver else "simx"
    os.environ.setdefault("VORTEX_DRIVER", driver)
    return driver


def _preload_vortex_libs() -> None:
    """Pre-load the Vortex runtime libraries with ctypes so that the C++
    extension and its ``dlopen`` calls succeed."""
    rt_dir = _find_vortex_runtime_dir()
    if not rt_dir:
        return  # best-effort — fall through to normal linker search

    os.environ.setdefault("VORTEX_RUNTIME_DIR", rt_dir)

    driver = _resolve_driver()

    # --- XRT-specific: set up FPGA env vars and preload system XRT lib ---
    xrt_system_loaded = False
    if driver == "xrt":
        _setup_xrt_env()
        xrt_lib_dir = _find_xilinx_xrt_lib()
        if xrt_lib_dir:
            xrt_core = os.path.join(xrt_lib_dir, "libxrt_coreutil.so")
            if os.path.isfile(xrt_core):
                try:
                    ctypes.CDLL(xrt_core, mode=ctypes.RTLD_GLOBAL)
                    xrt_system_loaded = True
                except OSError:
                    pass

    # Load order matters: deepest dependency first.
    # libvortex-simx.so  ->  libsimx.so
    # libvortex-rtlsim.so -> librtlsim.so  (etc.)
    _inner_lib = {
        "simx": "libsimx.so",
        "rtlsim": "librtlsim.so",
        "opae": "libopae-c-sim.so",
        "xrt": "libxrtsim.so",
    }

    # xrt_vcs uses the same libvortex-xrt.so but preloads libxrtsim_vcs.so
    is_xrt_vcs = os.environ.get("TORCH_VORTEX_XRT_VCS") == "1"
    # Note: libxrtsim_vcs.so must NOT be preloaded here — its static
    # constructors open a TCP connection to simv immediately on dlopen.
    # It is found via LD_LIBRARY_PATH / VORTEX_RUNTIME_DIR at runtime.
    inner_name = "" if is_xrt_vcs else _inner_lib.get(driver, "")

    for name in [
        # Skip bundled libxrtsim.so when system XRT is loaded to avoid
        # symbol conflicts, but always load libxrtsim_vcs.so (VCS sim).
        "" if (xrt_system_loaded and not is_xrt_vcs) else inner_name,
        f"libvortex-{driver}.so",         # e.g. libvortex-xrt.so
        "libvortex.so",                   # the main stub library
    ]:
        if not name:
            continue
        path = os.path.join(rt_dir, name)
        if os.path.isfile(path):
            try:
                ctypes.CDLL(path, mode=ctypes.RTLD_GLOBAL)
            except OSError:
                pass


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
