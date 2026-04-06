# Run GEMM Tests

## Single Test
```bash
cd hw/unittest/gemm_node_improve
make SIM_EXEC=vcs run M=32 N=32 K=128 QBLK=32 EXTRA_SIM_ARGS="+WTRANS=0 +QDIR=0"
```

## Via test.sh
```bash
./test.sh single 32,32,64,32,0,1    # M,N,K,QBLK,WTRANS,QDIR
./test.sh qcol                       # all QCOL cases
./test.sh qrow                       # all QROW cases
./test.sh all                        # full regression
./test.sh stream                     # instruction stream smoke test
./test.sh stream_gemm                # minimal GEMM via instruction stream
```

## Parameters
- M, N, K: matrix dimensions (must be multiples of tile sizes for tiled mode)
- QBLK: quantization block size (32, 64, 128)
- WTRANS: weight transpose (0=normal [K,N], 1=transposed [N,K])
- QDIR: quantization direction (0=QCOL, 1=QROW)

## Environment
- SIM_EXEC: `vcs` (default) or `vlt` (Verilator)
- DO_CLEAN: `1` to clean before build

## Reading Results
- Logs: `hw/unittest/gemm_node_improve/logs/`
- PASS: grep `OUTPUT CHECK PASSED`
- FAIL: look for `Fatal:`, `ERROR`, `MISMATCH` in log
