"""Checked host adapter for the versioned CUDA numerical kernel."""
import ctypes
import numpy as np
from fpint_versions import RTL_C4_V1, validate_inputs


class CudaModel:
    def __init__(self, library, *, version):
        self.lib = ctypes.CDLL(str(library))
        self.lib.fpint_cuda_version.restype = ctypes.c_char_p
        self.lib.fpint_cuda_error.argtypes = [ctypes.c_int]
        self.lib.fpint_cuda_error.restype = ctypes.c_char_p
        self.lib.fpint_cuda_gemm.argtypes = [ctypes.c_char_p] + [ctypes.c_int]*3 + [ctypes.c_void_p]*7
        self.lib.fpint_cuda_gemm.restype = ctypes.c_int
        if version != RTL_C4_V1 or self.lib.fpint_cuda_version().decode() != version:
            raise ValueError("CUDA model version mismatch")
        self.version = version

    def gemm(self, a, w, s, z, *, qdir, initial_psum=None):
        m, k = validate_inputs(a, w, s, z, qdir, initial_psum)
        args = [np.ascontiguousarray(x) for x in (a, w, s, z)]
        initial = None if initial_psum is None else np.ascontiguousarray(initial_psum)
        result = np.empty((m, 16), dtype=np.uint16)
        trace = np.empty((k//16, m, 16), dtype=np.uint32)
        pointers = [x.ctypes.data if x is not None else None for x in (*args, initial, result, trace)]
        status = self.lib.fpint_cuda_gemm(self.version.encode(), qdir, m, k, *pointers)
        if status:
            raise RuntimeError(self.lib.fpint_cuda_error(status).decode())
        if not np.all(np.isfinite(result.view(np.float16))) or not np.all(np.isfinite(trace.view(np.float32))):
            raise ValueError("CUDA output outside finite, non-overflow scope")
        return result, trace
