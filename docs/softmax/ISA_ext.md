# Overview
- softmax를 가속하는 것이 목적이다. expf가 상당히 느리기 때문에 expf를 가속한다.
- vortex에서 사용하는 RV core의 ISA에 expf 명령어를 extension 한다. custom field에서 남은 곳을 사용한다.
- softmax에서 vx_expf 부분을 확장한 instruction을 사용해서 가속한다. 나머지 max, recip, mul 등은 기본적인 SIMT를 사용한다.
- DMA node를 사용해서 dram <-> local mem 과 연산을 overlap한다.

# Dataflow
- DMA node를 사용해서 dram에서 row R개를 smem에 load issue.
- double buffering을 할것. 그 다음 row R개를 smem에 load issue.
- 현재 써야하는 row R개에 대한 DMA operation이 끝났는지를 polling해서 확인.
- DMA load가 끝나면 expf instruction을 사용해서 R개의 row에 대해서 softmax를 수행.
- softmax 연산이 끝나면 DMA store를 사용해서 dram에 저장.
- 전체 row에 대해서 반복하기.

# SIMT core 수정 Overview
- decoder 수정. 추가한 instruction을 decoding해야한다.
- expf unit 추가. 다른 unit과 마찬가지로 THREADS가 병렬적으로 사용할 수 있도록 여러개 넣는다.
- EX unit, commit 등 다른 부분도 수정할게 있는지 확인해봐야함.

# compiler 수정 overview
- LLVM의 tablegen 쪽에 custom instruction을 추가해야함. 이미 vortex 전용 instruction이 몇몇 추가되어 있으니까 참고.
- user가 fork한 repo에서 수정하고 /opt/vortex/llvm-vortex/bin/clang에 install 해야함.
- user의 fork repo는 /home/jaeyongjang/project.local/vortex-llvm 를 사용한다. branch는 volt.
- /home/jaeyongjang/project.local/vortex-llvm/llvm/lib/Target/RISCV/RISCVInstrInfoVX.td 를 수정해야함.
- riscv의 custom field중 남은 것을 찾아서 사용해야한다.

# SIMT core 수정 detail
- 목표는 `float vx_expf_hw(float x)` 한 개 명령을 추가해서 현재 `vx_expf()`의 다항식/정수 변환/bit 조작 sequence를 단일 FPU pipeline operation으로 치환하는 것이다.
- 첫 구현은 full softmax node가 아니라 scalar FP32 unary instruction이다. warp의 active thread mask마다 lane 병렬로 실행되고, 결과는 FP register에 writeback된다.
- `max`, `sum`, `recip`, `mul`, `fp16 convert`, shared memory reduction은 기존 SIMT/FPU/LSU 경로를 그대로 사용한다.

## 1. Instruction contract 확정

### 1.1 Encoding
- 신규 명령 이름: `vx_expf`
- 의미: `rd = exp(rs1)` for FP32 input/output.
- 입력: `rs1` floating-point register, FP32.
- 출력: `rd` floating-point register, FP32.
- inactive lane: 기존 FPU처럼 `tmask`가 0인 lane은 fflags merge와 writeback에서 무시된다.
- NaN/Inf/overflow/underflow:
  - functional target은 현재 `kernel/include/vx_math.h`의 `vx_expf()`와 같은 softmax용 approximate expf이다.
  - first pass에서는 input을 `[-87.3, 88.7]`로 clamp해서 finite output을 만든다.
  - IEEE exact `expf()` 호환보다 softmax accuracy/perf를 우선한다.
- RISC-V encoding 후보:

```text
opcode = CUSTOM0 / INST_EXT1 / 0x0B
funct7 = 7'h03
funct3 = 3'h0
rs2    = x0
rd     = FP rd encoded in normal rd field
rs1    = FP rs1 encoded in normal rs1 field
```

기존 사용 현황:
- `funct7=7'h00`: SFU control (`tmc`, `wspawn`, `split`, `join`, `bar`, `pred`)
- `funct7=7'h01`: ALU vote/shuffle
- `funct7=7'h02`: TCU WMMA
- `CUSTOM1`: `vx_tex`, `vx_rop`

따라서 `CUSTOM0/funct7=7'h03`을 softmax/FPU unary instruction group으로 예약한다.

### 1.2 Software-visible API
- Preferred path는 LLVM intrinsic이다. FP register operand를 custom opcode에 직접 연결해야 하므로 LLVM TableGen lowering이 가장 안전하다.
- Bring-up용으로 `kernel/include/vx_intrinsics.h`에 raw `.insn` helper를 둘 수 있지만, assembler가 `.insn r`에서 FP register constraint를 허용하는지 먼저 확인한다.

```c
inline float vx_expf_hw(float x) {
  float ret;
  __asm__ volatile (".insn r %1, 0, 3, %0, %2, x0"
                    : "=f"(ret)
                    : "i"(RISCV_CUSTOM0), "f"(x));
  return ret;
}
```

- 위 raw helper가 compile되지 않으면 GPR bitcast fallback을 임의로 넣지 않는다. RTL decode가 `USED_FREG(rd/rs1)`로 설계되면 GPR fallback은 다른 register file을 읽게 된다. 이 경우 LLVM intrinsic path를 먼저 완성한다.
- `kernel/include/vx_math.h`는 opt-in macro로 기존 approximation과 hardware instruction을 선택한다.

```c
#ifdef VX_ENABLE_HW_EXPF
static inline float vx_expf(float x) {
  return vx_expf_hw(x);
}
#endif
```

기본값은 기존 software `vx_expf()`를 유지한다. RTL/LLVM/toolchain 검증이 끝난 뒤 regression Makefile 또는 compile config에서 `-DVX_ENABLE_HW_EXPF`를 켠다.

## 2. RTL decode path

### Files
- Modify: `hw/rtl/VX_gpu_pkg.sv`
- Modify: `hw/rtl/core/VX_decode.sv`
- Modify: `hw/rtl/VX_trace_pkg.sv`

### 2.1 Add FPU op type
- `hw/rtl/VX_gpu_pkg.sv`의 FPU op type에서 unused slot `4'b0110`을 `INST_FPU_EXP`로 사용한다.

```systemverilog
localparam INST_FPU_EXP = 4'b0110;
```

- `INST_FPU_BITS`는 그대로 4 bit를 유지한다.
- `inst_fpu_is_class()`와 `inst_fpu_is_mvxw()`는 변경하지 않는다.

### 2.2 Decode custom instruction
- `hw/rtl/core/VX_decode.sv`의 `INST_EXT1` case에 `funct7 == 7'h03` branch를 추가한다.
- `funct3 == 3'h0`만 `vx_expf`로 decode한다.
- destination/source는 FP register로 mark한다.
- `rs2 == 0`인 encoding만 허용하는 정책을 trace/assert로 확인할 수 있게 plan에 남긴다. Decode 단계에서는 기존 style처럼 unknown combination은 default no-op decode로 둔다.

Expected decode logic:

```systemverilog
7'h03: begin
    case (funct3)
        3'h0: begin // VX_EXPF
            ex_type = EX_FPU;
            op_type = INST_OP_BITS'(INST_FPU_EXP);
            op_args.fpu.frm = INST_FRM_RNE;
            op_args.fpu.fmt = '0; // FP32
            `USED_FREG (rd);
            `USED_FREG (rs1);
        end
        default:;
    endcase
end
```

### 2.3 Trace support
- `hw/rtl/VX_trace_pkg.sv`의 `EX_FPU` trace case에 `INST_FPU_EXP`를 추가한다.

```systemverilog
INST_FPU_EXP: `TRACE(level, ("VX_EXPF"))
```

Trace가 먼저 맞아야 xrt-vcs failure debug에서 decode/dispatch 여부를 빠르게 확인할 수 있다.

## 3. FPU datapath implementation

### Files
- Modify: `hw/rtl/fpu/VX_fpu_unit.sv`
- Modify: `hw/rtl/fpu/VX_fpu_dpi.sv`
- Modify: `hw/rtl/fpu/VX_fpu_dsp.sv`
- Modify: `hw/rtl/fpu/VX_fpu_fpnew.sv`
- Create: `hw/rtl/fpu/VX_fpu_exp.sv`
- Modify: `hw/dpi/float_dpi.cpp`

### 3.1 Reuse existing FPU unit shell
- Keep `vx_expf` under `EX_FPU`.
- Reuse:
  - `VX_dispatch_unit` lane grouping
  - `VX_index_buffer` tag store
  - `VX_gather_unit` commit ordering
  - FPU CSR fflags writeback path
- Do not add a new `EX_EXP` unit in the first implementation. Adding a new EX unit would touch `NUM_EX_UNITS`, dispatch arrays, issue perf counters, commit arbitration, CSR perf counters, and build configs without clear benefit for one unary op.

### 3.2 Add synthesizable exp unit
- Create `hw/rtl/fpu/VX_fpu_exp.sv`.
- Interface mirrors `VX_fpu_sqrt.sv`/`VX_fpu_div.sv` shape:

```systemverilog
module VX_fpu_exp import VX_gpu_pkg::*, VX_fpu_pkg::*; #(
    parameter NUM_LANES = 1,
    parameter TAG_WIDTH = 1
) (
    input wire clk,
    input wire reset,
    input wire valid_in,
    output wire ready_in,
    input wire [NUM_LANES-1:0] mask_in,
    input wire [TAG_WIDTH-1:0] tag_in,
    input wire [NUM_LANES-1:0][31:0] dataa,
    output wire has_fflags,
    output fflags_t fflags,
    output wire [NUM_LANES-1:0][31:0] result,
    output wire [TAG_WIDTH-1:0] tag_out,
    output wire valid_out,
    input wire ready_out
);
```

- Approximation algorithm should match `vx_expf()`:
  1. clamp input to `[-87.3, 88.7]`
  2. multiply by `log2(e)`
  3. convert to floor integer `n`
  4. compute degree-4 polynomial for `2^f`
  5. add `n << 23` to output exponent bits
- Start with FP32-only implementation. If `fmt[0]` requests FP64 later, decode should not generate this op.
- fflags policy:
  - `NX=1` for normal finite approximated result is acceptable for first pass if the implementation cannot prove exactness.
  - `OF/UF` should remain 0 because input is clamped before polynomial.
  - `NV/DZ` should remain 0.
  - masked-off lanes must not contribute fflags.

### 3.3 DPI model for xrt-vcs bring-up
- Add a DPI helper in `hw/dpi/float_dpi.cpp`:

```c++
void dpi_fexp(bool enable, int64_t a, int64_t* result, svBitVecVal* fflags);
```

- It should use the same approximate algorithm as `vx_expf()` rather than host `std::expf`, so simulation and kernel reference match.
- In `hw/rtl/fpu/VX_fpu_dpi.sv`:
  - add a new core select, for example `FPU_EXP`
  - increase `NUM_FPC`
  - route `INST_FPU_EXP` to `FPU_EXP`
  - instantiate a shift-register response path with `DEPTH = LATENCY_FEXP`
- Add `LATENCY_FEXP` in the same config area where `LATENCY_FMA`, `LATENCY_FDIV`, `LATENCY_FSQRT`, and `LATENCY_FNCP` are defined. Initial value can be conservative, for example equal to the implemented pipeline depth of `VX_fpu_exp.sv`.

### 3.4 DSP/FPNEW mode integration
- In `hw/rtl/fpu/VX_fpu_dsp.sv`, add the same `FPU_EXP` core path and instantiate `VX_fpu_exp.sv`.
- In `hw/rtl/fpu/VX_fpu_fpnew.sv`, `fpnew` has no native exponential operation. Do not attempt to map `INST_FPU_EXP` to `fpnew_pkg::operation_e`.
- For `FPU_FPNEW` builds, either:
  - instantiate `VX_fpu_exp.sv` next to `fpnew_top` and arbitrate with fpnew output, or
  - emit a compile-time error if `INST_FPU_EXP` is enabled without `FPU_DSP/FPU_DPI`.
- Preferred first implementation: instantiate `VX_fpu_exp.sv` next to `fpnew_top` so all FPU backend modes accept the same instruction.

## 4. RTL unit tests

### Files
- Create: `hw/unittest/fpu_exp/Makefile`
- Create: `hw/unittest/fpu_exp/vcs.mk`
- Create: `hw/unittest/fpu_exp/vlt.mk`
- Create: `hw/unittest/fpu_exp/test.sh`
- Create: `hw/unittest/fpu_exp/tb_VX_fpu_exp.sv`

### Test cases
- Lane mask:
  - all lanes active
  - alternating lanes active
  - one lane active
- Numeric inputs:
  - `0.0 -> about 1.0`
  - `1.0 -> about 2.71828`
  - `-1.0 -> about 0.367879`
  - `10.0`
  - `-10.0`
  - clamp high input `100.0`
  - clamp low input `-100.0`
- Tolerance:
  - compare bit-level against DPI/reference implementation when testing `VX_fpu_exp.sv`
  - compare relative error `< 2e-4` against host `expf()` for smoke coverage

### Commands
Run from configured build directory:

```bash
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
make -C hw/unittest/fpu_exp -j4
make -C hw/unittest/fpu_exp run
```

Use `/usr/bin/gcc` and `/usr/bin/g++` if the unittest harness needs host compiler overrides.

# compiler 수정 detail
- Compiler work happens in `/home/jaeyongjang/project.local/vortex-llvm` on branch `volt`.
- Install target is `/opt/vortex/llvm-vortex/bin/clang`.
- The hardware header path can use raw `.insn` first, but LLVM TableGen support is still needed for readable assembly, disassembly, and future intrinsic lowering.

## 1. LLVM instruction definition

### Files
- Modify: `/home/jaeyongjang/project.local/vortex-llvm/llvm/lib/Target/RISCV/RISCVInstrInfoVX.td`
- Modify: `/home/jaeyongjang/project.local/vortex-llvm/llvm/include/llvm/IR/IntrinsicsRISCV.td`

### 1.1 Add instruction
- Add a `VX_EXPF` instruction near the existing Vortex custom instructions.

```tablegen
def VX_EXPF : RVInstR<3, 0, RISCV_CUSTOM0,
                      (outs FPR32:$rd), (ins FPR32:$rs1),
                      "vx_expf", "$rd, $rs1">, Sched<[]> {
    let rs2 = 0;
}
```

- Verify operand register class names in the current LLVM tree. If `FPR32` is not the correct class name for scalar single-precision registers in this fork, use the same class used by standard `FADD_S`/`FSQRT_S` definitions.

### 1.2 Add LLVM intrinsic
- Add a unary FP32 intrinsic, for example:

```tablegen
def int_riscv_vx_expf : Intrinsic<[llvm_float_ty], [llvm_float_ty], [IntrNoMem]>;
```

- Add lowering pattern:

```tablegen
def : Pat<(int_riscv_vx_expf FPR32:$rs1), (VX_EXPF FPR32:$rs1)>;
```

- Keep the intrinsic explicit. Do not auto-lower all `llvm.exp.f32` to `vx_expf` until accuracy policy is accepted, because the hardware operation is softmax-oriented approximate exp.

### 1.3 Compiler tests
- Add LLVM MC/CodeGen tests in the fork if the existing tree has Vortex-specific test directories.
- Minimum manual verification:

```bash
cd /home/jaeyongjang/project.local/vortex-llvm
./build/bin/llvm-tblgen --version
./build/bin/llvm-mc -triple=riscv64 -show-encoding < vx_expf.s
./build/bin/llc -mtriple=riscv64 -mattr=+f vx_expf.ll -o -
```

Expected assembly should contain:

```asm
vx_expf fa0, fa0
```

Expected encoding fields:
- opcode `0x0b`
- funct7 `0x03`
- funct3 `0x0`
- rs2 `x0`

## 2. LLVM build/install

### Commands
Use the user's fork and install into the Vortex toolchain location:

```bash
cd /home/jaeyongjang/project.local/vortex-llvm
git checkout volt
cmake --build build --target clang llc llvm-mc llvm-objdump -j$(nproc)
cmake --install build --prefix /opt/vortex/llvm-vortex
```

After install:

```bash
/opt/vortex/llvm-vortex/bin/clang --version
/opt/vortex/llvm-vortex/bin/llvm-objdump --version
```

## 3. Kernel integration

### Files
- Modify: `kernel/include/vx_intrinsics.h`
- Modify: `kernel/include/vx_math.h`
- Modify: `tests/regression/softmax/Makefile`
- Modify: `tests/regression/softmax/kernel.cpp`

### 3.1 Header first path
- Add `vx_expf_hw()` to `vx_intrinsics.h` with raw `.insn`.
- Include `vx_intrinsics.h` from `vx_math.h` only if needed. Avoid cyclic includes.
- Add compile macro:

```c
#ifdef VX_ENABLE_HW_EXPF
static inline float vx_expf(float x) {
  return vx_expf_hw(x);
}
#else
/* existing software vx_expf body */
#endif
```

### 3.2 Softmax app opt-in
- Keep `tests/regression/softmax/kernel.cpp` source unchanged if `vx_math.h` redirects `vx_expf()`.
- Add a build flag in `tests/regression/softmax/Makefile` only after RTL/compiler smoke tests pass:

```make
VX_CFLAGS += -DVX_ENABLE_HW_EXPF
```

## 4. End-to-end verification

### 4.1 Build setup
All commands run from configured build directory:

```bash
cd build
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
```

### 4.2 Kernel disassembly check

```bash
make -C tests/regression/softmax clean
make -C tests/regression/softmax -j4
/opt/vortex/llvm-vortex/bin/llvm-objdump -d tests/regression/softmax/kernel.vxbin | rg "vx_expf|0001011"
```

Expected:
- `vx_expf` appears at both exp sites, or raw custom encoding appears if objdump alias support is not installed yet.
- No accidental replacement of `fmax.s`, `fmin.s`, `fmul.s`, `fdiv.s`.

### 4.3 Functional blackbox

```bash
ci/run_black.sh xrt-vcs-sim --app softmax --args "-batch 1 -heads 1 -seqq 4 -seqk 32 -mask 0"
ci/run_black.sh xrt-vcs-sim --app softmax --args "-batch 1 -heads 1 -seqq 4 -seqk 32 -mask 1"
ci/run_black.sh xrt-vcs-sim --app softmax --args "-batch 1 -heads 2 -seqq 8 -seqk 64 -mask 1"
```

Pass criteria:
- host CPU comparison passes with existing tolerance, or tolerance is explicitly adjusted based on measured `vx_expf_hw()` approximation error.
- xrt-vcs run completes without illegal instruction, decode default no-op, deadlock, or fflags CSR issue.

### 4.4 Performance comparison

Run baseline without `VX_ENABLE_HW_EXPF`, then hardware exp build with the flag:

```bash
ci/run_black.sh xrt-vcs-sim --bench --app softmax --args "--warmup=1 --iterations=5 -batch 1 -heads 1 -seqq 8 -seqk 64 -mask 1"
ci/run_black.sh xrt-vcs-sim --bench --app softmax --args "--warmup=1 --iterations=5 -batch 1 -heads 1 -seqq 16 -seqk 128 -mask 1"
```

Record:
- cycles or elapsed latency from `bench_main.cpp`
- instruction count if perf counters are enabled
- FPU utilization counter if `PERF_ENABLE` is available

## 5. Kernel optimization plan

이 section은 최종 kernel 구조를 정의하지만 구현 순서는 가장 마지막이다. first milestone은 `vx_expf` instruction 자체의 RTL/compiler/kernel opt-in 검증이다. 아래 최적화는 `vx_expf`가 functional/perf blackbox를 통과한 뒤 시작한다.

### 5.1 Current kernel 문제점

현재 `tests/regression/softmax/kernel.cpp`의 `kernel_softmax()`는 correctness-oriented SIMT kernel이다.

- Input/output row를 DRAM에서 직접 load/store한다.
- `__local_mem()`은 reduction용 `float cache[blockDim.x]` 역할로만 사용하고, row data staging buffer로는 사용하지 않는다.
- DMA node를 사용하지 않아서 DRAM transfer와 softmax compute가 overlap되지 않는다.
- `vx_expf()`를 row element마다 두 번 호출한다.
  - Step 2: `exp(x - max)`를 계산해서 sum reduction에 사용한다.
  - Step 3: global-memory RAW hazard를 피하려고 `exp(x - max)`를 다시 계산해서 normalize/store한다.
- 따라서 `vx_expf` instruction을 추가해도, optimized kernel 전에는 exp call count가 `2 * row_elements`로 남는다.

### 5.2 Optimization goal

Dataflow section의 목표 구조로 kernel을 바꾼다.

```text
for row tile T:
  issue DMA load for T into local buffer[next]
  wait/poll DMA load for local buffer[cur]
  compute softmax for rows in local buffer[cur]
  issue DMA store for output rows from local buffer[cur]
  overlap next DMA load with current compute/store when possible
```

핵심 목표:
- DRAM input row를 local memory로 stage한다.
- exp result를 local memory에 저장해서 normalization 단계에서 재사용한다.
- DMA load/store와 SIMT softmax compute를 double buffering으로 overlap한다.
- `vx_expf()` 또는 `vx_expf_hw()` 호출 수를 element당 2회에서 1회로 줄인다.

### 5.3 Local memory layout

Per buffer layout:

```text
input_buf:  R * seq_len_k * sizeof(fp16)
exp_buf:    R * seq_len_k * sizeof(float)
output_buf: R * seq_len_k * sizeof(fp16)
reduce_buf: R * blockDim.x * sizeof(float)
```

Double buffering:

```text
buffer 0: input0, exp0, output0, reduce0
buffer 1: input1, exp1, output1, reduce1
```

Constraints:
- `R` is the number of rows staged per tile.
- Choose `R` so both buffers fit in available local memory.
- `seq_len_k` may be runtime-sized; host/kernel args should include either selected `R` or enough metadata to derive it safely.
- Use row-major local layout first. Do not introduce fused/tiled layout conversion in this phase unless softmax_layout_fused requires it later.

### 5.4 Optimized compute flow

For each staged row:

1. Read fp16 input from `input_buf`.
2. Apply scale and causal mask.
3. Reduce max using `reduce_buf`.
4. Compute `exp(x - max)` exactly once with `vx_expf_hw()` and store FP32 result into `exp_buf`.
5. Reduce sum from the same exp values.
6. Compute `inv_sum = 1.0f / sum`.
7. Read `exp_buf`, multiply by `inv_sum`, convert to fp16, write `output_buf`.
8. DMA store `output_buf` to DRAM.

Pseudo-code shape:

```c
for (uint32_t tile = 0; tile < row_tiles; ++tile) {
  uint32_t next = tile & 1;
  uint32_t cur = next ^ 1;

  issue_dma_load(input_dram_for(tile), input_buf[next], tile_rows * seq_len_k * sizeof(fp16_t));

  if (tile != 0) {
    wait_dma_load(cur);
    softmax_compute_local(input_buf[cur], exp_buf[cur], output_buf[cur], reduce_buf[cur]);
    issue_dma_store(output_buf[cur], output_dram_for(tile - 1), prev_rows * seq_len_k * sizeof(fp16_t));
  }
}

wait_dma_load(last);
softmax_compute_local(input_buf[last], exp_buf[last], output_buf[last], reduce_buf[last]);
issue_dma_store(output_buf[last], output_dram_for(last_tile), last_rows * seq_len_k * sizeof(fp16_t));
wait_all_dma_store();
```

The function names above are illustrative. Before implementation, identify the current kernel-side DMA control interface and use that API rather than inventing a new one.

### 5.5 Files for last-phase implementation

- Modify: `tests/regression/softmax/common.h`
  - add tile/local-memory parameters if host must pass `rows_per_tile`, lmem base offsets, or DMA config.
- Modify: `tests/regression/softmax/main.cpp`
  - choose safe `rows_per_tile` based on `seq_len_k`, local memory capacity, and double-buffer footprint.
  - preserve CPU reference comparison.
- Modify: `tests/regression/softmax/bench_main.cpp`
  - report baseline vs `vx_expf` vs DMA/local-memory optimized kernel as separate benchmark labels.
- Modify: `tests/regression/softmax/kernel.cpp`
  - split current direct-DRAM implementation from optimized local-memory implementation.
  - keep direct-DRAM path available behind a compile flag until optimized path is stable.
- Modify: kernel DMA helper headers only if the existing DMA node lacks a clean C/C++ kernel-side wrapper.

### 5.6 Verification for optimized kernel

Run these only after `vx_expf` instruction verification passes.

Functional:

```bash
ci/run_black.sh xrt-vcs-sim --app softmax --args "-batch 1 -heads 1 -seqq 4 -seqk 32 -mask 0"
ci/run_black.sh xrt-vcs-sim --app softmax --args "-batch 1 -heads 1 -seqq 4 -seqk 32 -mask 1"
ci/run_black.sh xrt-vcs-sim --app softmax --args "-batch 1 -heads 2 -seqq 8 -seqk 64 -mask 1"
ci/run_black.sh xrt-vcs-sim --app softmax --args "-batch 1 -heads 2 -seqq 16 -seqk 128 -mask 1"
```

Performance:

```bash
ci/run_black.sh xrt-vcs-sim --bench --app softmax --args "--warmup=1 --iterations=5 -batch 1 -heads 1 -seqq 8 -seqk 64 -mask 1"
ci/run_black.sh xrt-vcs-sim --bench --app softmax --args "--warmup=1 --iterations=5 -batch 1 -heads 1 -seqq 16 -seqk 128 -mask 1"
```

Pass criteria:
- output still matches CPU reference within accepted tolerance.
- no global-memory RAW workaround is needed because exp intermediates live in local memory.
- exp instruction count is one per unmasked element per softmax pass, not two.
- DMA traces/perf counters show load/store activity and overlap with compute.

## 6. Rollout order

1. Add encoding documentation and raw `vx_expf_hw()` header.
2. Add LLVM `VX_EXPF` TableGen support and verify assembly encoding.
3. Add RTL decode for `CUSTOM0/funct7=7'h03/funct3=0` into `EX_FPU`.
4. Add `INST_FPU_EXP` trace support.
5. Add DPI implementation and pass an instruction-level xrt-vcs smoke test.
6. Add synthesizable `VX_fpu_exp.sv` and unittest it.
7. Integrate `VX_fpu_exp.sv` into FPU backend modes.
8. Enable `VX_ENABLE_HW_EXPF` in softmax regression app.
9. Run functional blackbox matrix.
10. Run benchmark matrix and compare against software `vx_expf()` baseline.
11. Only after steps 1-10 pass, implement the DMA/local-memory optimized softmax kernel.
12. Run optimized-kernel functional and benchmark matrix, then compare against both software `vx_expf()` and hardware-`vx_expf` direct-DRAM baselines.

## 7. Known risks

- The hardware approximation may not match CPU `std::expf()` tightly enough for existing softmax tolerance. Keep the first reference aligned with current `vx_expf()` and measure relative error before changing tolerances.
- LLVM register class names for FP operands may differ in the fork. Confirm against existing `FADD_S`/`FSQRT_S` TableGen definitions before adding `VX_EXPF`.
- `FPU_FPNEW` has no native exp operation. The plan must instantiate the local exp pipeline rather than trying to encode it as an fpnew op.
- If `vx_expf_hw()` is emitted only with raw `.insn`, objdump may not print `vx_expf` until LLVM install is complete. Treat encoding-field match as sufficient in that intermediate state.
- Adding a new EX unit is intentionally avoided for first pass. If profiling later shows FPU contention dominates, split `vx_expf` into a separate EX unit in a second design.
- Kernel DMA/local-memory optimization is deliberately last because it can hide or confound bugs in the new exp instruction. Keep the direct-DRAM kernel path until the instruction is independently verified.
