
#!/bin/bash
CONFIGS="-DDBG_TRACE_GEMM -DNUM_CORES=1 -DLMEM_LOG_SIZE=17 -DLMEM_BASE_ADDR=8589803520" \
./ci/blackbox.sh --driver=rtlsim --app=fpint_gemm_ffn_hw --debug=3 --log=run.log