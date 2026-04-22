# Vitis hw_emu + VCS — FSDB Dump 문제 현황

## 목표

Vitis 2025.1 hw_emu 빌드(`v++ --target hw_emu --config ... param=hw_emu.simulator=VCS`)
에서 **VCS simv 실행 시 FSDB 파형 파일(`vortex.fsdb`)을 자동 생성**. Verdi로 오프라인
분석 가능하도록.

## 환경

- Vivado/Vitis 2025.1, Synopsys VCS W-2024.09-SP1, Verdi PLI 포함
- Ubuntu 24.04, vg_gnu bundle + libncurses5/libtinfo5 + Vivado fake libtinfo.so.5 심볼릭 링크 완료
- Platform: `xilinx_u55c_gen3x16_xdma_3_202210_1` (Alveo U55C)
- vcs_simlib 정상 컴파일 (`compile_simlib -simulator vcs`), `sim_qdma_sc_v1_0` SIMULATOR_PLATFORM
  메타데이터 패치 포함

## 작동하는 것

- VCS hw_emu 빌드 및 xclbin 생성 성공
- 테스트 `./ci/blackbox.sh --driver=xrt --app=fpint_gemm_ffn_hw_improve --debug=3` PASSED
- simv 정상 실행 (호스트 APP이 XRT 경유로 시뮬레이션 돌려 결과 수신)

## 작동하지 않는 것 — FSDB 미생성

| 항목 | 상태 |
|---|---|
| xrt.ini `[Emulation] user_pre_sim_script` 설정 | 파일에 라인 박혀있음 ✓ |
| `-debug_access+all` at VCS elaborate | vitis.gen.ini에 반영 ✓ (`fileset.sim_1.vcs.elaborate.vcs.more_options`) |
| simv 바이너리 Verdi PLI 링크 | 됐다고 가정(elab flag 기반) |
| `simulate.do`의 `source $::env(USER_PRE_SIM_SCRIPT)` 실행 흔적 | **simulate.log에 없음** ✗ |
| `.run/<pid>/.../vcs/vortex.fsdb` | **생성 안 됨** ✗ |

## 시도한 접근과 결과

### A. xrt.ini `user_pre_sim_script` + `runtime/xrt/vcs_fsdb.tcl`

```ini
# $(BIN_DIR)/xrt.ini
[Emulation]
user_pre_sim_script=<VORTEX_HOME>/runtime/xrt/vcs_fsdb.tcl
```

`vcs_fsdb.tcl`:
```tcl
fsdbDumpfile "vortex.fsdb"
fsdbDumpvars 0 /
```

**결과**: simulate.log에 Tcl 실행 흔적 없음. FSDB 없음.

**원인 추정**: Vitis `launch_emulator.py -help` 출력에서
```
-user-pre-sim-script  Specify the simulator tcl commands like add_wave,
                      log_wave that are to be executed before starting
                      simulation.Used only for hw emu
```
예시 커맨드(`add_wave`, `log_wave`)가 xsim 전용. Vitis VCS 경로에서 xrt.ini의
`user_pre_sim_script` → `USER_PRE_SIM_SCRIPT` env 전파가 이루어지지 않음.

### B. common.mk에서 `USER_PRE_SIM_SCRIPT` 직접 export

호스트 프로세스 환경변수에 직접 세팅해서 체인(XRT → launch_emulator → simulate.sh → simv)
으로 전달 기대.

**결과**: simulate.log에 여전히 Tcl 흔적 없음. Vitis emulation launcher가 env
whitelist 기반 filter를 한다고 추정됨.

### C. `bind pfm_top_wrapper` + `compile.tcl.pre` hook

`runtime/xrt/vcs_fsdb_init.sv` + `hw/scripts/vcs_fsdb_setup.tcl`로
`add_files -fileset sim_1` 호출. xrt.ini / env 경로 배제.

**결과**: 최신 시도는 빌드까지 성공했지만 segfault 발생(simulate.log 2 lines,
3.4MB null bytes로 끝). 원인 불명확.

### D. `pl-sim-args` 또는 `vcs.simulate.vcs.more_options={-ucli -do fsdb.tcl}` (검토만)

simv는 이미 `-do pfm_top_wrapper_simulate.do`로 호출됨. VCS는 `-do`를 하나만
honor → `pfm_top_wrapper_simulate.do`(Vitis emulation 제어 필수)와 충돌.
미채택.

## 현재 진행 중인 접근 — `bind vortex_afu` + `sources.txt`

### 왜 바꾸는가

`bind pfm_top_wrapper`는 target이 **커널 scope 외부**라 `gen_xo.tcl` →
`package_kernel.tcl` (line 194 `add_files -norecurse ${vsources_list}`)의 IP
packaging 단계에서 Vivado가 silently drop (실제로 이전 시도에서 `vlogan.log`에
`vcs_fsdb_init.sv` parsing 흔적 0건). `bind vortex_afu`는 커널 scope 내 → IP
packager가 bundle → vlogan이 sim에서 compile → bind 활성화 기대.

### 현재 구성

- `runtime/xrt/vcs_fsdb_init.sv` — `bind vortex_afu u_fsdb ()` + `$fsdbDumpfile`
  + `$fsdbDumpvars(0)` + `$fsdbDumpMDA()`, `ifdef VCS_FSDB_DUMP` 가드
- `hw/syn/xilinx/xrt/Makefile` — `SIM_FSDB_SOURCES` 변수 (VCS+hw_emu+DEBUG
  조건부), `sources.txt`에 append
- `hw/syn/xilinx/xrt/gen_vitis_ini.py` — VCS+DEBUG 시 `+define+VCS_FSDB_DUMP`
  + `-debug_access+all` emit, `compile.tcl.pre` 훅 제거
- `compile.tcl.pre` 훅 파일(`hw/scripts/vcs_fsdb_setup.tcl`)은 더 이상 사용
  안 함 (삭제 대기)

### 검증 필요 항목

재빌드 후 확인:
1. `sources.txt`에 `vcs_fsdb_init.sv` 포함
2. `vlogan.log`에 `Parsing design file .../vcs_fsdb_init.sv` 라인 존재
3. `elaborate.log`에 `-debug_access+all` 포함 + bind instance 생성 흔적
4. 테스트 run 후 `.run/<pid>/.../vcs/vortex.fsdb` 생성

만약 1–3은 OK인데 4가 실패하면 `$fsdbDumpvars(0)`의 scope 문제일 수 있어
`$fsdbDumpvars(0, $root)` 같은 형태로 조정 필요.

## 미해결 의문

1. **Vitis의 xrt.ini `user_pre_sim_script` 키가 VCS 경로로 env propagation을
   진짜로 안 하는지** 공식 문서엔 명시 없음. CLI 예시가 xsim 전용이라는 간접
   증거만 있음. AMD 포럼/Answer Record에서 공식 확인 필요.
2. **이전 segfault의 정확한 원인**. `simulate.log` 2라인 + 3.4MB null bytes
   + "Completed context dump phase data" 종결은 simv가 초기화 중 이상 종료했다는
   신호. `-debug_access+all`의 메모리 오버헤드 / `-kdb -lca` 없이 일부 기능
   부재 / Vitis emulation launcher의 환경 불일치 등이 의심되지만 확정 안 됨.
3. **`bind vortex_afu`의 FSDB 범위**. `$fsdbDumpvars(0)`가 `u_fsdb` 내부
   scope에서 호출될 때 실제로 vortex_afu 상위(부모 모듈) dump를 얻는지, 아니면
   빈 dump가 되는지 VCS 버전(W-2024.09-SP1) 동작 확인 필요.

## 정리된 문서 경로 / 참고

- AMD UG1393 `Simulator Support` (2024.1) — VCS hw_emu enable 절차, `hw_emu.simulator=VCS`, 경로 prop 예시
- AMD UG900 (2025.2) — VCS compile/elaborate/simulate more_options, `Dumping VCD in VCS` (FSDB 예시 없음)
- AMD UG1393 `launch_emulator Utility` — `-user-pre-sim-script` xsim 전용 언급
- Xilinx TclStore `tclapp/xilinx/vcs/register_options.tcl` — VCS simulator integration에서 등록된 hook은 `compile.tcl.pre` / `simulate.tcl.post` 두 개뿐
- Synopsys VCS/Verdi 문서 — `$fsdbDump*` 시스템 태스크 사용법, `-debug_access+all` 필요성
