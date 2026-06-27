// Host-side stub. This regression test exists only to drive the Vortex kernel
// compiler so we can inspect kernel.dump for compiler-emit verification of
// the 8-thread MMIO burst pattern (DAE Optimization 2).
//
// Running this binary is NOT part of the verification — only the produced
// kernel.dump matters. We still keep a host main so the standard regression
// scaffolding works (`make`).

#include <cstdio>

int main() {
    std::printf("mmio_burst_proto: compile-only test — inspect kernel.dump\n");
    return 0;
}
