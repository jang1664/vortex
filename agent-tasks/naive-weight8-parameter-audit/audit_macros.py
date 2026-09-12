"""Expand the exact comparison configurations without simulation or synthesis."""
import json
from pathlib import Path
import re
import shlex
import subprocess

ROOT=Path(__file__).resolve().parents[2]
TASK=Path(__file__).resolve().parent
OUT=TASK/'runs/macro-audit'
OUT.mkdir(parents=True,exist_ok=True)
names='''NUM_THREADS NUM_CORES NUM_HBM_PORTS MXU_PIPE_MUL_EN MXU_PIPE_ALIGN_EN MXU_PIPE_ADD_INTV ACT_REDUCE_PIPE_INTV MXU_ROW MXU_COL MXU_COL_TILE MXU_WLOAD_NUM
GEMM_INPUT_DATA_SIZE GEMM_WEIGHT_DATA_SIZE GEMM_SCALE_ZERO_DATA_SIZE GEMM_OUTPUT_DATA_SIZE
GEMM_FSM_MT GEMM_FSM_NT GEMM_FSM_KT GEMM_ACC_MEM_DEPTH
LMEM_DMA_CMD_FIFO_DEPTH LMEM_DMA_RD_OUTSTANDING_SLOTS I_LMEM_DMA_RD_OUTSTANDING_SLOTS
W_LMEM_DMA_CMD_BEATS W_LMEM_DMA_RESPONSE_SLOTS W_LMEM_DMA_RD_OUTSTANDING_SLOTS
SZ_LMEM_DMA_RD_OUTSTANDING_SLOTS O_LMEM_DMA_RD_OUTSTANDING_SLOTS
I_LMEM_DMA_RESPONSE_DATA_RAM W_LMEM_DMA_RESPONSE_DATA_RAM SZ_LMEM_DMA_RESPONSE_DATA_RAM
LMEM_DMA_RD_PREFETCH_DEPTH DMA_RD_OUTSTANDING_SLOT DMA_NODE_RD_OUTSTANDING_SLOT TMEM_DMA_RD_OUTSTANDING_SLOT
GEMM_TIMING_CUTS GEMM_TIMING_MONOTONIC_SET GEMM_TIMING_REG_CONSUME GEMM_TIMING_REG_LOCAL_DEPS
GEMM_TIMING_REG_ACC_FREE GEMM_TIMING_REG_DMA_DEPS GEMM_TIMING_REG_CAPACITY GEMM_TIMING_DMA_LAUNCH_EB2
GEMM_SLR_PIPELINE TMEM_ARB_URGENCY_ENABLE I_LMEM_DMA_READY_AHEAD_LOW_WATERMARK W_LMEM_DMA_READY_AHEAD_LOW_WATERMARK
LMEM_LOG_SIZE LMEM_NUM_BANKS LMEM_NUM_PORTS NUM_TMEM_BANKS TMEM_BANK_SIZE NUM_DMA_CHANNELS
PLATFORM_MEMORY_NUM_BANKS PLATFORM_MEMORY_NUM_PORTS PLATFORM_MEMORY_INTERLEAVE PLATFORM_MERGED_MEMORY_INTERFACE
ICACHE_SIZE DCACHE_SIZE DCACHE_NUM_BANKS L1_MEM_PORTS MEM_BLOCK_SIZE
'''.split()
probe=OUT/'probe.sv'
probe.write_text('`include "VX_define.vh"\n'+''.join(
    f'`ifdef {name}\nAUDIT {name} = `{name};\n`else\nAUDIT {name} = UNDEFINED;\n`endif\n'
    for name in names))
configs={'naive':'configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh',
         'improve':'agent-tasks/fpint-gemm-latency-compare/improve.sh'}
includes=sorted({p.parent for p in (ROOT/'hw/rtl').rglob('*.vh')})
records={}
for backend,config in configs.items():
    flags=subprocess.check_output(['bash','-c','source "$1"; printf "%s" "$CONFIGS"','bash',config],cwd=ROOT,text=True)
    command=['verilator','-E','-DXLEN_64','-DPERF_ENABLE',*shlex.split(flags),*[f'+incdir+{p}' for p in includes],str(probe)]
    expanded=subprocess.check_output(command,cwd=ROOT,text=True)
    (OUT/f'{backend}.sv').write_text(expanded)
    values=dict(re.findall(r'^AUDIT (\w+) = (.*);$',expanded,re.M))
    assert len(values)==len(names)
    records[backend]=dict(config=config,flags=flags,values=values)
(OUT/'result.json').write_text(json.dumps(records,indent=2)+'\n')
for name in names:
    naive=records['naive']['values'][name];improve=records['improve']['values'][name]
    if naive!=improve:print(f'{name}: naive={naive}; improve={improve}')
