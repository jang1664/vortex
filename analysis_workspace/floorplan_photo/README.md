# Floorplan photo

저장된 FPGA 구현 프로젝트를 Vivado GUI로 열고
`hw/syn/xilinx/xrt/export_photo.tcl`로 Device view에 카테고리별 색상을 적용합니다.
기본 모드에서는 직접 구도를 조정하고 캡처합니다. `--capture`를 지정하면
별도의 가상 디스플레이에서 자동 캡처한 뒤 Vivado를 종료합니다.
자동 캡처가 끝나면 PNG와 색상 범례를 넣은 PowerPoint 슬라이드 한 장도 생성합니다.

Python 의존성은 이 디렉터리의 가상 환경에 설치할 수 있습니다.

```bash
cd analysis_workspace/floorplan_photo
python3 -m venv --system-site-packages .venv
.venv/bin/python -m pip install -r requirements.txt
source .venv/bin/activate
```

```bash
cd analysis_workspace/floorplan_photo
python3 main.py C1
python3 main.py /opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_tcu_94c5b39919
```

첫 번째 인자는 `ci/fpga_bin_alias_map.yaml`의 alias 이름 또는 `bin/`을 포함한
FPGA 빌드 루트 경로입니다. `bin/` 경로를 직접 전달해도 됩니다.
상대 경로는 명령을 호출한 디렉터리를 기준으로 해석합니다.
프로젝트는 빌드 루트의 `_x/link/vivado/vpl/prj/prj.xpr`에서 찾습니다.
`--reuse_impl`로 재패키징하여 `impl_1` 실행 기록이 없는 경우에는 같은 `vpl/`의
`routed.dcp`를 엽니다.
수동 모드의 Vivado 작업 디렉터리는 이 드라이버의 디렉터리이고,
자동 모드에서는 실행별 결과 디렉터리를 사용합니다.

## 자동 캡처

```bash
python3 main.py C1 --capture
python3 main.py C1 --capture --output result/C1_photo
python3 main.py /path/to/fpga_build_root --capture --timeout 1200
```

결과 디렉터리의 기본값은 `result/<이름>_<시각>/`입니다. `--output`으로 지정한
디렉터리는 새 경로여야 합니다. `floorplan.png`에 Device 영역을 저장하고,
`full.png`에 전체 GUI 화면을 보관합니다. 실행 로그도 같은 디렉터리에 저장합니다.
`floorplan.pptx`에는 같은 PNG와 편집 가능한 네모 색상 도형 및 범례 텍스트가 들어갑니다.
구현 데이터 로딩과 색상 적용 후 `pblock_gemm_slr0/1/2` 세 개의 이름·경계·채움을 제외합니다.
Vivado에서 개별 pblock 표시를 끄는 대신, 캡처 전용 세션의 메모리에서 이 세 pblock
제약만 제거합니다. 원본 프로젝트·체크포인트는 저장하지 않으며, 구현을 다시 실행하지
않습니다. 셀 배치·색상, 나머지 pblock 및 격자 표시는 유지합니다.
세 pblock이 없는 빌드에서는 그대로 캡처합니다. 수동 GUI 모드에는 적용하지 않습니다.
캡처 과정에서는 Resource Types 체크박스나 색상 설정을 변경하지 않습니다.
Device view를 확대하고 화면 맞춤을 적용한 뒤, 영역의 픽셀과 적용 색상을 확인하여
화면이 안정됐을 때 캡처하며 상단 안내 배너와 바깥의 검은 여백을 제외합니다. Tcl 오류나 시간 초과는 실패로
처리합니다. `--timeout`의 기본값은 900초이고 `--settle`로 렌더링 대기 시간
(기본 5초)을 지정할 수 있습니다. 큰 프로젝트는 로딩에 수 분이 걸릴 수 있습니다.

자동 모드에는 `Xvfb`, `fluxbox`, ImageMagick의 `import`/`convert`, `libX11`, `libXtst`가
필요합니다. 시스템 `/usr/bin`의 도구를 우선 사용하며, 가상 화면은 1920×1200입니다.
현재 `DISPLAY`와 별도의 디스플레이를 생성하고 완료/실패 시 생성한 프로세스를 종료합니다.
baseline처럼 MXU/DMA 계층이 없는 빌드는 해당 범주의 셀 수를 0으로 처리합니다.
기존 C3 빌드의 `gemm_node_naive/u_VX_gemm_unit` 및 DMA 계층 이름도 분류합니다.
GUI 조작 좌표는 Vivado 2025.1의 기본 레이아웃과 위 화면 크기에서 검증했습니다.
checkpoint 모드는 Flow Navigator가 없는 화면 배치를 사용하므로 확대 버튼 좌표를 구분합니다.
다른 버전에서 UI 배치가 달라지면 `capture.py`의 조작 좌표를 조정해야 합니다.

## 기존 PNG로 PowerPoint 생성

Vivado를 실행하지 않고 저장된 PNG로 슬라이드 한 장을 만들 수 있습니다.

```bash
.venv/bin/python main.py --image result/C1_auto/floorplan_vivado_view.png \
  --title "C1 — FPGA floorplan"
.venv/bin/python main.py --image /path/to/floorplan.png \
  --pptx /path/to/floorplan.pptx --title "FPGA floorplan"
```

기본 PowerPoint 경로는 PNG와 같은 위치에 확장자만 `.pptx`로 바꾼 경로입니다.
기존 `.pptx`는 덮어쓰지 않습니다. `--pptx`와 `--title`은 자동 캡처에도 사용할 수 있습니다.
범례의 이름과 RGB는 `export_util.tcl`의 `category_specs`를 `tclsh`로 직접 읽습니다.
SIMT, Cache / LMEM / TMEM, MXU, DMA, Misc.의 다섯 범주를 사용하며 PNG는 원본 그대로
삽입합니다. Vivado 기본 resource/pblock 색상과 노란 HBM 표시가 이 범례와 별개라는
설명을 슬라이드에 함께 넣습니다. PowerPoint 생성에는 `python-pptx`와 `tclsh`가 필요합니다.

## 기타 옵션

```bash
python3 main.py --list
python3 main.py C1 --dry-run
python3 main.py C1 --display :1 --impl-run impl_1
python3 main.py C1 --vivado /path/to/Vivado/bin/vivado
python3 main.py C1 --alias-map /path/to/fpga_bin_alias_map.yaml
```

`--display`를 생략하면 현재 `DISPLAY`를 유지하고, 설정이 없으면 `:1`을 사용합니다.
Vivado 실행 파일은 기본적으로 `PATH`에서 찾습니다. Python 환경에는 PyYAML이 필요합니다.
alias map 경로는 기존 resolver와 동일하게 `VORTEX_FPGA_BIN_ALIAS_MAP` 환경변수로도
지정할 수 있습니다. `--dry-run`은 입력 경로를 검증한 후 실행하지 않고 종료합니다.
