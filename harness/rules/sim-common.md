---
paths: ["sim/**", "runtime/xrt/**", "hw/rtl/afu/**"]
---

# Simulator / Runtime Rules (Common — all branches)

- Before modifying simulator or XRT runtime code, read `docs/hbm-bank-interleaving.md` to understand HBM address mapping, interleave vs contiguous modes, and the BANK_INTERLEAVE compile flag behavior.
- VCS simv Makefile (`sim/xrtsim_vcs/Makefile`) only depends on TB/DPI sources, NOT RTL. After RTL changes, always run `make -C sim/xrtsim_vcs clean` before rebuilding simv.

## Blackbox Test Debugging

### 1. 항상 DBG_TRACE를 켤 것

blackbox.sh 실행 시 CONFIGS에 다음 DBG_TRACE define을 반드시 포함한다. 이 trace가 없으면 simv.log에 pipeline/memory/AXI 동작이 남지 않아 디버깅이 불가능하다.

```bash
CONFIGS+=" -DDBG_TRACE_PIPELINE"
CONFIGS+=" -DDBG_TRACE_MEM"
CONFIGS+=" -DDBG_TRACE_CACHE"
CONFIGS+=" -DDBG_TRACE_AFU"
CONFIGS+=" -DDBG_TRACE_SCOPE"
CONFIGS+=" -DDBG_TRACE_GBAR"
CONFIGS+=" -DDBG_TRACE_TCU"
CONFIGS+=" -DDBG_TRACE_GEMM"
```

### 2. RTL에 `TRACE 매크로로 충분한 정보를 logging할 것

디버깅에 필요한 signal이 trace에 안 나오면, RTL에 `ifdef DBG_TRACE_*` 블록을 추가해서 logging한다. 예시 (VX_afu_wrap.sv의 AXI trace):

```systemverilog
`ifdef DBG_TRACE_AFU
    always @(posedge clk) begin
        for (integer i = 0; i < C_M_AXI_MEM_NUM_BANKS; ++i) begin
            if (m_axi_mem_arvalid_a[i] && m_axi_mem_arready_a[i]) begin
                `TRACE(2, ("%t: AXI Rd Req [%0d]: addr=0x%0h, id=0x%0h\n", $time, i, m_axi_mem_araddr_a[i], m_axi_mem_arid_a[i]))
            end
            if (m_axi_mem_rvalid_a[i] && m_axi_mem_rready_a[i]) begin
                `TRACE(2, ("%t: AXI Rd Rsp [%0d]: data=0x%h, id=0x%0h\n", $time, i, m_axi_mem_rdata_a[i], m_axi_mem_rid_a[i]))
            end
        end
    end
`endif
```

`$display`/`$isunknown` probe를 임시로 추가하는 것보다 `TRACE` 매크로가 낫다: `DBG_TRACE_*` define이 없으면 컴파일에서 빠지므로 성능 영향 없음.

## xprop Debugging (VCS -xprop=tmerge)

When `xprop=tmerge` simulation fails with X-propagation:

1. **FSDB 생성**: `FSDB_DUMP=1`으로 waveform 캡처
2. **pywellen으로 persistently-X 신호 스캔**: 시뮬레이션 전체에서 X인 신호를 자동으로 찾는다.
3. **해당 신호의 reset 초기화 확인**: `reg` 선언에 `= 0` 초기값이 있는지, `if (reset)` 블록에 포함되는지 확인
4. **tmerge 의미**: reset 전환 시 reset 경로와 non-reset 경로의 값이 다르면 X 발생. INIT_VALUE와 reset 직후 data_in 값이 일치해야 함.

### 흔한 xprop 원인
- `reg` 선언 후 `if (reset)` 블록에서 초기화 누락 (예: `vx_reset_ctr`)
- `BUFFER_EX`/`VX_pipe_register`의 `INIT_VALUE`와 reset 직후 실제 값 불일치
- Third-party AXI 모듈 (axi_mux, axi_demux)의 spill register bypass 모드에서 초기화 미비
