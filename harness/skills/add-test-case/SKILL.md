# Add Test Case

## Steps

1. Choose parameters: M, N, K, QBLK, WTRANS, QDIR
   - QCOL (QDIR=0): no special constraint on QBLK
   - QROW (QDIR=1): QBLK >= 32, QBLK % MXU_KT == 0, QBLK % MXU_NT == 0

2. Edit `hw/unittest/gemm_node_improve/test.sh`:
   - QCOL: append `"M,N,K"` to `QCOL_SHAPES` array (line ~38)
   - QROW: append to `QROW_SHAPES` array (line ~50)
   - New QBLK values: append to `QCOL_QBLKS` or `QROW_QBLKS`
   - New WTRANS values: append to `QCOL_WTRANS` or `QROW_WTRANS`

3. Verify single case:
   ```bash
   ./test.sh single M,N,K,QBLK,WTRANS,QDIR
   ```

4. Run full regression to check no existing tests break:
   ```bash
   ./test.sh all
   ```
