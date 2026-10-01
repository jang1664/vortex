#include <stdio.h>
#define FP32_WIDTH 32
#include "VX_config.h"
int main(void) {
  unsigned long long sockets=(NUM_CORES+SOCKET_SIZE-1)/SOCKET_SIZE;
  unsigned long long icache=(unsigned long long)ICACHE_SIZE*NUM_ICACHES*sockets*NUM_CLUSTERS;
  unsigned long long dcache=(unsigned long long)DCACHE_SIZE*NUM_DCACHES*sockets*NUM_CLUSTERS;
  unsigned long long lmem=(unsigned long long)LMEM_SIZE*NUM_CORES*NUM_CLUSTERS;
  unsigned long long acc=0,tmem=0;
#ifdef ENABLE_GEMM_ACCEL
  acc=(unsigned long long)GEMM_ACC_MEM_TOT_SIZE*NUM_CORES*NUM_CLUSTERS;
#ifdef GEMM_IMPROVE
  tmem=(unsigned long long)NUM_TMEM_BANKS*TMEM_BANK_SIZE*NUM_CORES*NUM_CLUSTERS;
#endif
#endif
  printf("%llu %llu %llu %llu %llu %d %d %d %d\n",icache,dcache,lmem,acc,tmem,L2_ENABLED,L3_ENABLED,ICACHE_ENABLED,DCACHE_ENABLED);
}
