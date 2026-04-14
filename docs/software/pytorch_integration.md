# Vortex PyTorch Integration

## Overview

Vortex PyTorch integration registers Vortex as a custom accelerator backend in PyTorch via the **PrivateUse1** extensibility mechanism. This enables:

```python
import torch
import torch_vortex

# Use Vortex like any other PyTorch device
x = torch.tensor([1.0, 2.0, 3.0], device="vortex")
y = torch.mm(A, B)   # dispatches to Vortex TCU kernel
```

The integration follows a four-layer architecture:

```
┌─────────────────────────────────────────────────────┐
│  PyTorch Python (torch.vortex.*)                    │
│  Device management, tensor.to("vortex")             │
├─────────────────────────────────────────────────────┤
│  C++ Extension (torch_vortex._C)                    │
│  ATen operator dispatch, kernel launch, allocator   │
├─────────────────────────────────────────────────────┤
│  Vortex Runtime (libvortex.so)                      │
│  Device open/close, memory alloc/free, DMA, exec    │
├─────────────────────────────────────────────────────┤
│  Driver Backend (libvortex-{simx|xrt|rtlsim}.so)    │
│  Simulator or FPGA communication                    │
└─────────────────────────────────────────────────────┘
```

---

## 1. Backend Registration

### PrivateUse1 Mechanism

PyTorch provides `PrivateUse1` as a placeholder device type that third-party hardware vendors can claim. Vortex claims it under the name `"vortex"`:

```python
# torch_vortex/__init__.py
torch.utils.rename_privateuse1_backend("vortex")
torch._register_device_module("vortex", torch_vortex.vortex)
torch.utils.generate_methods_for_privateuse1_backend(for_storage=True)
```

After registration, PyTorch recognizes `torch.device("vortex")`, `tensor.to("vortex")`, and `torch.Storage` with vortex device type.

### Autoloading

The package registers itself as a PyTorch backend plugin via the `torch.backends` entry point in `setup.py`:

```python
entry_points={
    "torch.backends": [
        "torch_vortex = torch_vortex:_autoload",
    ],
},
```

When `import torch` runs, PyTorch auto-discovers and calls `_autoload()`, which triggers backend registration. Users only need `import torch_vortex` explicitly when they want to control the import order.

---

## 2. Library Preloading

Before the C++ extension loads, the Python layer preloads all required shared libraries via `ctypes.CDLL(..., mode=ctypes.RTLD_GLOBAL)`:

```
1. libxrt_coreutil.so   (XRT driver only, system library)
2. libxrtsim.so         (XRT simulation driver)
   OR libsimx.so        (functional simulator)
3. libvortex-{driver}.so (driver plugin)
4. libvortex.so          (main runtime stub)
```

**Load order matters**: deepest dependency first, so that `dlopen()` calls inside `libvortex.so` can resolve symbols from already-loaded libraries.

The library search order is:
1. `<torch_vortex>/lib/` — bundled copies (preferred, set by CMake install)
2. `$VORTEX_HOME/build/runtime/` — development tree
3. Relative path `../../build/runtime/` — repo layout fallback

---

## 3. Driver Selection

The `VORTEX_DRIVER` environment variable selects the backend:

| Value | Driver | Use Case |
|-------|--------|----------|
| `simx` | `libvortex-simx.so` | Functional simulation (default) |
| `rtlsim` | `libvortex-rtlsim.so` | Verilator RTL simulation |
| `xrt` | `libvortex-xrt.so` | Xilinx FPGA via XRT |
| `opae` | `libvortex-opae.so` | Intel FPGA via OPAE |

When `FPGA_BIN_DIR` is set or `VORTEX_DRIVER=xrt`, the Python layer auto-configures XRT environment variables (`XRT_XCLBIN_PATH`, `EMCONFIG_PATH`, `XRT_DEVICE_INDEX`).

---

## 4. C++ Extension Architecture

### 4.1 Build System

The build uses a **two-stage** process:

1. **CMake** (`CMakeLists.txt`) compiles the C++ extension into `libtorch_vortex_bindings.so`:
   - Links against `libvortex.so` (Vortex runtime)
   - Links against `libtorch.so` (PyTorch C++ library)
   - Installs runtime libraries → `torch_vortex/lib/`
   - Installs pre-built kernel binaries (`.vxbin`) → `torch_vortex/kernels/`

2. **setuptools** (`setup.py`) packages the Python module:
   - Builds a thin stub extension `torch_vortex._C` that links to `libtorch_vortex_bindings.so`
   - Sets RPATH so the extension can find bundled `.so` files at runtime
   - Patches RPATH on Vortex runtime libs via `patchelf --set-rpath $ORIGIN`

### 4.2 VortexRuntime — Memory Management

`c10::vortex::VortexRuntime` is the central C++ runtime wrapper (singleton pattern):

```
┌──────────────────┐     ┌───────────────────┐     ┌──────────────────┐
│  PyTorch tensor  │     │  Staging buffer   │     │  Device buffer   │
│  data_ptr() ─────┼────►│  (host malloc)    │◄───►│  (vx_mem_alloc)  │
│                  │     │  staging pointer  │     │  vx_buffer_h     │
└──────────────────┘     └───────────────────┘     └──────────────────┘
                              syncToDevice()  ──────►
                              ◄──────  syncFromDevice()
```

**Key design**: PyTorch operates with raw pointers (`data_ptr()`). Vortex uses opaque buffer handles (`vx_buffer_h`). `VortexRuntime` bridges this gap:

- `malloc(nbytes)`: allocates both a device buffer (`vx_mem_alloc`) and a host staging buffer (`std::malloc`). Returns the **staging pointer** to PyTorch.
- `buffer_map_`: maps `staging_ptr → {vx_buffer_h, size, staging}` so that any staging pointer can be resolved to its device buffer.
- `syncToDevice()`: DMA from staging → device (`vx_copy_to_dev`)
- `syncFromDevice()`: DMA from device → staging (`vx_copy_from_dev`)
- `deviceAddress()`: returns the device-side virtual address for a staging pointer (used in kernel arguments)

### 4.3 VortexDeviceAllocator

Implements PyTorch's `c10::Allocator` interface for the Vortex device:

- `allocate(size)`: calls `VortexRuntime::malloc()` → returns a `DataPtr` with the staging pointer
- `deallocate()`: calls `VortexRuntime::free()`
- Supports both **caching** and **non-caching** modes:
  - Caching mode: maintains free block pools per size bucket for allocation reuse
  - Non-caching mode: direct alloc/free on every call

### 4.4 ATen Operator Dispatch

The extension registers operators via PyTorch's dispatch mechanism:

```cpp
// Standard ATen ops → dispatched to PrivateUse1 backend
TORCH_LIBRARY_IMPL(aten, PrivateUse1, m) {
  m.impl("add.Tensor",     &vortex_add_Tensor);
  m.impl("mm",             &vortex_mm);
  m.impl("_softmax",       &vortex_softmax);
  // ...
}

// Custom Vortex ops → new namespace
TORCH_LIBRARY(vortex, m) {
  m.def("rms_norm(Tensor input, Tensor weight, float eps) -> Tensor");
  m.def("mm_w4a16(Tensor input, Tensor weight_int4, ...) -> Tensor");
}
```

When PyTorch encounters `torch.mm(A, B)` with Vortex tensors, the dispatcher routes the call to `vortex_mm()`.

### 4.5 CPU Fallback Strategy

Every Vortex operator includes a graceful CPU fallback for unsupported cases:

```cpp
if (!can_native) {
  auto cpu_self = self.cpu();           // Device → Host
  auto cpu_out = at::add(cpu_self, ...); // Compute on CPU
  return cpu_out.to(self.device());      // Host → Device
}
```

This ensures correctness even when tensors have unsupported dtypes, non-contiguous layouts, or require broadcasting.

---

## 5. Kernel Launch Pipeline

### 5.1 Kernel Binary Format (`.vxbin`)

Vortex kernels are pre-compiled RISC-V binaries stored in `.vxbin` files. The format is:

```
Offset  Size    Content
0x00    8B      min_vma   (lowest virtual memory address)
0x08    8B      max_vma   (highest virtual memory address)
0x10    ...     payload   (binary image)
```

The kernel's code must be loaded at its `min_vma` address in the device's address space.

### 5.2 Kernel Buffer Cache

`VortexExtra.cpp` implements a process-wide kernel cache to avoid redundant uploads:

```
KernelBufferCache
├── images: map<kernel_path, KernelImage>
│   └── KernelImage { min_vma, runtime_size, payload }
└── regions: map<min_vma, ReservedRegion>
    └── ReservedRegion { vx_buffer_h, loaded_kernel_path }
```

- **First launch**: reads `.vxbin`, reserves device memory at `min_vma` via `vx_mem_reserve()`, uploads the binary via `vx_copy_to_dev()`.
- **Subsequent launches**: reuses the cached device buffer. If the same VMA region loads a different kernel, it re-uploads only when the kernel path changes.

### 5.3 Launch Sequence

For each operator call, the launch sequence is:

```
1. Resolve device addresses for all tensors (via VortexRuntime::deviceAddress)
2. Build kernel argument struct (grid/block dims, tensor addresses, op params)
3. Upload args to device: vx_upload_bytes() → args_buf
4. Get or upload kernel binary: get_or_upload_kernel_buffer() → krnl_buf
5. Start execution: vx_start(device, krnl_buf, args_buf)
6. Wait for completion: vx_ready_wait(device, VX_MAX_TIMEOUT)
```

All kernels execute **synchronously** — `vx_ready_wait()` blocks until the device finishes.

### 5.4 Kernel Argument Structures

Each kernel has a matching C struct in `VortexExtra.cpp`:

| Kernel | Struct | Key Fields |
|--------|--------|------------|
| eladd/elmul/elsub/eldiv | `eladd_kernel_arg_t` | `input_a_addr, input_b_addr, output_addr, size` |
| elunary | `elunary_kernel_arg_t` | `input_addr, output_addr, size, kernel_id` |
| softmax | `softmax_kernel_arg_t` | `input_addr, output_addr, batch_size, seq_len_q, seq_len_k, scale` |
| sgemm_tcu | `sgemm_tcu_kernel_arg_t` | `M, N, K, A_addr, B_addr, C_addr` |
| silu | `silu_kernel_arg_t` | `input_addr, output_addr, size` |
| rmsnorm | `rmsnorm_kernel_arg_t` | `input_addr, output_addr, gamma_addr, batch_size, hidden_dim, eps` |
| rope | `rope_kernel_arg_t` | `input_addr, output_addr, cos_addr, sin_addr, batch_size, head_dim` |
| fpint_gemm | `fpint_gemm_kernel_arg_t` | `M, N, K, QBLK, input/weight/output/scale/zp addresses, LMEM layout` |

### 5.5 Kernel Binary Discovery

`find_kernel()` searches for `.vxbin` files in:

1. `$TORCH_VORTEX_PACKAGE_DIR/kernels/<name>.vxbin` — installed package
2. `$VORTEX_HOME/build/tests/regression/<name>/kernel.vxbin` — build tree

---

## 6. Supported Operations

### 6.1 Standard ATen Operations

| Category | Operations | Kernel |
|----------|-----------|--------|
| Binary element-wise | `add`, `mul`, `sub`, `div` | `eladd`, `elmul`, `elsub`, `eldiv` |
| Unary element-wise | `rsqrt`, `sin`, `cos`, `exp`, `log`, `neg`, `abs`, `sqrt` | `elunary` (with `kernel_id`) |
| Scalar ops | `pow`, scalar mul/add | `elscalar` |
| Reduction | `mean` | `elreduce` |
| Matrix multiply | `mm`, `bmm`, `addmm` | `sgemm_tcu` (TCU WMMA, fp16→fp32) |
| Activation | `silu` | `silu` |
| Normalization | `_softmax` | `softmax` |
| Regularization | `native_dropout` | `dropout` |

### 6.2 Custom Vortex Operations

| Operation | Signature | Kernel |
|-----------|-----------|--------|
| `vortex.rms_norm` | `(input, weight, eps) → Tensor` | `rmsnorm` |
| `vortex.apply_rotary_pos_emb` | `(input, cos, sin, pos_offset) → Tensor` | `rope` |
| `vortex.mm_w4a16` | `(input, weight_int4, scales, zeros, ...) → Tensor` | `fpint_gemm_ffn` |

### 6.3 TCU Matrix Multiply Details

The `sgemm_tcu` kernel uses the Tensor Compute Unit (TCU) with hardware WMMA instructions:

- **Input**: fp16 (auto-converted from fp32 if needed)
- **Output**: fp32
- **Tile alignment**: M/N must be multiples of 8/4 respectively, K must be multiple of 8
- **Padding**: non-aligned dimensions are automatically zero-padded; results are sliced back
- **Batch mm (`bmm`)**: uses device-address arithmetic (zero-copy) when no padding needed

### 6.4 W4A16 Mixed-Precision GEMM

`vortex.mm_w4a16` performs 4-bit weight × 16-bit activation matrix multiply using the GEMM accelerator:

- **Weight format**: packed int4 (`uint8`, two values per byte)
- **Scales**: fp16 per quantization group
- **Zero-points**: int16 per quantization group
- **Output**: fp16
- **LMEM layout**: double-buffered scratchpads for input, weight, scales, zero-points computed at runtime based on device local memory size

---

## 7. Data Flow Example: `torch.mm(A, B)`

```
Python:  C = torch.mm(A, B)    # A, B on "vortex" device
   │
   ▼
PyTorch Dispatcher
   │  (A.device == PrivateUse1)
   ▼
C++: vortex_mm(VortexExtra.cpp)
   │
   ├─ 1. Convert to fp16 if needed:  A.to(kHalf), B.to(kHalf)
   ├─ 2. Pad dimensions to TCU tile alignment (M%8, N%4, K%8)
   ├─ 3. Allocate output tensor C [M, N] fp32
   ├─ 4. Resolve device addresses via VortexRuntime::deviceAddress()
   ├─ 5. Build sgemm_tcu_kernel_arg_t {M, N, K, A_addr, B_addr, C_addr}
   ├─ 6. launch_kernel():
   │      ├─ vx_upload_bytes(args) → args_buf
   │      ├─ get_or_upload_kernel_buffer("sgemm_tcu.vxbin") → krnl_buf
   │      ├─ vx_start(device, krnl_buf, args_buf)
   │      └─ vx_ready_wait(device, timeout)
   └─ 7. If padded: syncFromDevice, slice valid region, syncToDevice
   │
   ▼
Return C to Python
```

---

## 8. Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VORTEX_HOME` | auto-detected | Vortex source tree root |
| `VORTEX_DRIVER` | `simx` | Driver backend (`simx`, `rtlsim`, `xrt`, `opae`) |
| `FPGA_BIN_DIR` | auto-detected | Directory with `vortex_afu.xclbin` (xrt only) |
| `XRT_XCLBIN_PATH` | derived from `FPGA_BIN_DIR` | Full path to FPGA bitstream |
| `XRT_DEVICE_INDEX` | `0` | FPGA device index |
| `TORCH_VORTEX_PACKAGE_DIR` | auto-set | Package dir for kernel binary lookup |
| `TORCH_VORTEX_KERNEL_DEBUG` | `0` | Print kernel launch info to stderr |
| `TORCH_VORTEX_KERNEL_RESERVE_FLOOR_MB` | `32` | Minimum VMA reservation for kernel code (MiB) |

---

## 9. Directory Structure

```
pytorch/
├── CMakeLists.txt              # CMake build: compile C++ extension, install libs/kernels
├── setup.py                    # Python packaging: build wheel, bundle runtime .so files
├── pyproject.toml              # Build dependencies and metadata
├── cmake/
│   └── TorchPythonTargets.cmake
├── csrc/
│   ├── aten/
│   │   ├── VortexExtra.cpp     # ATen/custom op implementations + kernel launch
│   │   ├── VortexMinimal.cpp   # Mandatory PrivateUse1 backend ops (copy, reshape)
│   │   └── native/
│   │       └── Minimal.h/cpp   # Tensor creation, copy, reshape implementations
│   └── runtime/
│       ├── VortexRuntime.h/cpp # Core runtime wrapper (device handle, memory mapping)
│       ├── VortexDeviceAllocator.h/cpp  # PyTorch c10::Allocator interface
│       ├── VortexFunctions.h/cpp        # Device management functions
│       ├── VortexHooks.h/cpp            # PyTorch PrivateUse1 hooks registration
│       ├── VortexGuard.h/cpp            # RAII guard, atexit cleanup
│       ├── VortexGenerator.h/cpp        # RNG generator
│       ├── VortexHostAllocator.h/cpp    # Host pinned memory allocator
│       ├── VortexSerialization.h/cpp    # Tensor serialization
│       └── VortexException.h            # Error checking macros
├── include/
│   └── Macros.h                # VORTEX_EXPORT macro
├── torch_vortex/
│   ├── __init__.py             # Backend registration, library preloading
│   ├── vortex/
│   │   ├── __init__.py         # Device management API (device_count, set_device, ...)
│   │   ├── random.py           # RNG utilities
│   │   ├── meta.py             # torch.compile meta implementations
│   │   └── amp/__init__.py     # AMP supported dtypes
│   └── csrc/
│       └── stub.c              # Thin C stub → links to libtorch_vortex_bindings.so
└── test/
    └── test_loop.sh
```

---

## 10. Vortex Runtime API (vortex.h)

The C API that the PyTorch extension calls into:

| Function | Purpose |
|----------|---------|
| `vx_dev_open()` / `vx_dev_close()` | Open/close device connection |
| `vx_dev_caps()` | Query device capabilities (num cores, memory size, ISA flags) |
| `vx_mem_alloc()` / `vx_mem_free()` | Allocate/free device memory |
| `vx_mem_reserve()` | Reserve device memory at a specific virtual address |
| `vx_mem_address()` | Get device-side virtual address of a buffer |
| `vx_copy_to_dev()` / `vx_copy_from_dev()` | Host ↔ Device DMA |
| `vx_start()` | Start kernel execution |
| `vx_ready_wait()` | Wait for kernel completion |
| `vx_upload_bytes()` | Upload data (kernel args) to device |
| `vx_smi_set_kernel_name()` | Set kernel name for monitoring |

---

## 11. Key Design Decisions

### Staging Buffer Model

Unlike CUDA where `cudaMalloc` returns a device pointer and `cudaMemcpy` handles transfers explicitly, Vortex uses a **staging buffer** model:

- Every `malloc()` allocates both a device buffer **and** a host staging buffer
- PyTorch's `data_ptr()` returns the staging pointer
- Data must be explicitly synced between staging ↔ device via `syncToDevice()` / `syncFromDevice()`
- This enables CPU fallback (compute on host using staging buffer) without moving data off-device first

### Synchronous Kernel Execution

All kernel launches are synchronous — `vx_ready_wait()` blocks until completion. This simplifies correctness but means no kernel-level pipelining. The Vortex runtime handles the blocking wait internally via the driver backend.

### Pre-built Kernel Binaries

Kernels are **not** JIT-compiled. They are pre-built RISC-V binaries (`.vxbin`) compiled as part of the Vortex test regression suite. The CMake install step copies them into `torch_vortex/kernels/`. This means:

- Adding a new operation requires building a corresponding kernel binary first
- Kernel binaries must be rebuilt when the Vortex ISA or hardware config changes
- The kernel cache avoids re-uploading the same binary across calls
