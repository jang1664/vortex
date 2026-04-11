# How to Test — vecadd (xrt_vcs, BANK_INTERLEAVE ON)

## Prerequisites

```bash
cd /home/jaeyongjang/project.local/vortex/build
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
```

## Run

```bash
cd /home/jaeyongjang/project.local/vortex/build

CONFIGS=""
CONFIGS+=" -DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MERGED_MEMORY_INTERFACE"
CONFIGS+=" -DDCACHE_DISABLE -DL2_ENABLE -DNUM_THREADS=8"
CONFIGS+=" -DLMEM_LOG_SIZE=22 -DSTACK_BASE_ADDR=8585740288"
CONFIGS+=" -DAFU_DONE_WAIT_CACHE_DRAIN"
PATH=/usr/bin:$PATH CONFIGS="$CONFIGS" timeout 300 ./ci/blackbox.sh --driver=xrt_vcs --app=vecadd --args="-n64" --cores=1 --threads=8 --debug=3
```

debug trace가 필요하면 CONFIGS에 추가:
```
CONFIGS+=" -DDBG_TRACE_PIPELINE -DDBG_TRACE_MEM -DDBG_TRACE_CACHE -DDBG_TRACE_AFU -DDBG_TRACE_SCOPE -DDBG_TRACE_GBAR -DDBG_TRACE_TCU -DDBG_TRACE_GEMM"
```

## Pass Criteria

- `PASSED` 출력, exit code 0
- `info: device name=..., memory_banks=32` (32 HBM banks 확인)
- `allocated bank0/32` ~ `allocated bank31/32` (interleaved allocation 확인)

## Notes

- `PATH=/usr/bin:$PATH` — conda linker 충돌 방지 (필수)
- `PLATFORM_MERGED_MEMORY_INTERFACE` — VX_axi_adapter만 single output, 이후 demux가 8 port로 분배
- `BANK_INTERLEAVE` — `runtime/xrt/vortex.cpp` line 50에서 활성화됨 (compile time)
