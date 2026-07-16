"""
Op placement tracer — shows which aten ops run natively on the Vortex device and
which fall back to CPU during a forward pass.

How it decides: torch_vortex registers a per-op kernel for the PrivateUse1
(Vortex) dispatch key for every op it accelerates (see VortexExtra.cpp `m.impl`),
plus a global CPU fallback for everything else (VortexMinimal.cpp). So an op runs
on the device iff the PrivateUse1 key has a real kernel for it, which
`torch._C._dispatch_has_kernel_for_dispatch_key` reports exactly.

Usage:
    from spinquant_inference.utils.op_trace import OpPlacementTracer
    with OpPlacementTracer() as tr:
        model(input_ids, ...)
    tr.report()

Only ops that actually touch a Vortex tensor are counted (CPU-only scaffolding is
ignored). Memory/view ops (empty, view, as_strided, _copy_from ...) are reported
in their own group since they are device-side but not compute.
"""

from __future__ import annotations

from collections import Counter

import torch
from torch.utils._python_dispatch import TorchDispatchMode
from torch.utils._pytree import tree_leaves

_PU1 = "PrivateUse1"

# Device-side bookkeeping ops (registered in VortexMinimal.cpp) that are not
# compute — grouped separately so the compute picture stays clear.
_MEMORY_OPS = {
    "aten::empty.memory_format", "aten::empty_strided", "aten::as_strided",
    "aten::resize_", "aten::_reshape_alias", "aten::_copy_from",
    "aten::_copy_from_and_resize", "aten::_local_scalar_dense",
    "aten::set_.source_Tensor", "aten::set_.source_Storage",
    "aten::set_.source_Storage_storage_offset", "aten::view",
}


def _base_name(func) -> str:
    # func is an OpOverload; .name() -> e.g. "aten::mm.default" ... normalise to
    # the "aten::mm" / "aten::add.Tensor" form the dispatch table is keyed on.
    n = func.name()
    return n[:-len(".default")] if n.endswith(".default") else n


def _has_native_kernel(name: str) -> bool:
    try:
        return bool(torch._C._dispatch_has_kernel_for_dispatch_key(name, _PU1))
    except Exception:
        return False


def _touches_vortex(args, kwargs) -> bool:
    for a in tree_leaves((args, kwargs or {})):
        if isinstance(a, torch.Tensor) and a.device.type in ("privateuseone", "vortex"):
            return True
    return False


class OpPlacementTracer(TorchDispatchMode):
    def __init__(self):
        self.vortex = Counter()    # native compute on device
        self.cpu    = Counter()    # fell back to CPU
        self.memory = Counter()    # device memory/view bookkeeping

    def __torch_dispatch__(self, func, types, args=(), kwargs=None):
        if _touches_vortex(args, kwargs):
            name = _base_name(func)
            if name in _MEMORY_OPS:
                self.memory[name] += 1
            elif _has_native_kernel(name):
                self.vortex[name] += 1
            else:
                self.cpu[name] += 1
        return func(*args, **(kwargs or {}))

    def report(self) -> None:
        def dump(title, counter):
            total = sum(counter.values())
            print(f"\n=== {title}  ({len(counter)} ops, {total} calls) ===")
            for name, n in sorted(counter.items(), key=lambda kv: (-kv[1], kv[0])):
                print(f"  {n:>7}  {name}")
        print("\n" + "=" * 66)
        print(" Op placement during forward (ops touching a Vortex tensor)")
        print("=" * 66)
        dump("VORTEX (native FPGA kernel)", self.vortex)
        dump("CPU FALLBACK (device->CPU->device)", self.cpu)
        dump("device memory / view (bookkeeping)", self.memory)
        nv, nc = sum(self.vortex.values()), sum(self.cpu.values())
        tot = nv + nc
        if tot:
            print(f"\n compute-call split: VORTEX {nv} ({100*nv//tot}%)  |  "
                  f"CPU fallback {nc} ({100*nc//tot}%)")
