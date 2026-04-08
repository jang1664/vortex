---
paths: ["sim/**", "runtime/xrt/**"]
---

# Simulator / Runtime Rules (Common — all branches)

- Before modifying simulator or XRT runtime code, read `docs/hbm-bank-interleaving.md` to understand HBM address mapping, interleave vs contiguous modes, and the BANK_INTERLEAVE compile flag behavior.
- VCS simv Makefile (`sim/xrtsim_vcs/Makefile`) only depends on TB/DPI sources, NOT RTL. After RTL changes, always run `make -C sim/xrtsim_vcs clean` before rebuilding simv.

## xprop Debugging (VCS -xprop=tmerge)

When `xprop=tmerge` simulation fails with X-propagation:

1. **FSDB 생성**: `FSDB_DUMP=1`으로 waveform 캡처
2. **pywellen으로 persistently-X 신호 스캔**: 시뮬레이션 전체에서 X인 신호를 자동으로 찾는다. `$display` probe보다 훨씬 빠르다.
   ```python
   import pywellen
   db = pywellen.open("vcs_cosim.fsdb")
   # 전체 시뮬레이션에서 X 비율이 높은 신호 찾기
   ```
3. **해당 신호의 reset 초기화 확인**: `reg` 선언에 `= 0` 초기값이 있는지, `if (reset)` 블록에 포함되는지 확인
4. **tmerge 의미**: reset 전환 시 reset 경로와 non-reset 경로의 값이 다르면 X 발생. INIT_VALUE와 reset 직후 data_in 값이 일치해야 함.
5. `$display`/`$isunknown` probe는 최후 수단 — 먼저 waveform 분석 도구 사용

### 흔한 xprop 원인
- `reg` 선언 후 `if (reset)` 블록에서 초기화 누락 (예: `vx_reset_ctr`)
- `BUFFER_EX`/`VX_pipe_register`의 `INIT_VALUE`와 reset 직후 실제 값 불일치
- Third-party AXI 모듈 (axi_mux, axi_demux)의 spill register bypass 모드에서 초기화 미비
