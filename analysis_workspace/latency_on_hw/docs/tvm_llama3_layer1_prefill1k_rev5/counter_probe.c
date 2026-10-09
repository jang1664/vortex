#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* Measurement-only interposer. Query the completed kernel's core-0 MCYCLE
 * snapshot before the next launch can overwrite it. No DUT/runtime edits. */
static int enabled;
static uint64_t cycles, launches;
static void *runtime;

static void *symbol(const char *name) {
    if (!runtime) runtime = dlopen("libvortex.so", RTLD_NOW | RTLD_NOLOAD);
    void *p = runtime ? dlsym(runtime, name) : NULL;
    if (!p) { fprintf(stderr, "counter probe: missing %s\n", name); abort(); }
    return p;
}

void bench_profile_enable(int value) { enabled = value; cycles = launches = 0; }
uint64_t bench_cycles(void) { return cycles; }
uint64_t bench_launches(void) { return launches; }

int vx_ready_wait(void *device, uint64_t timeout) {
    typedef int (*wait_fn)(void *, uint64_t);
    typedef int (*query_fn)(void *, uint32_t, uint32_t, uint64_t *);
    static wait_fn wait_real;
    static query_fn query;
    if (!wait_real) wait_real = (wait_fn)symbol("vx_ready_wait");
    int status = wait_real(device, timeout);
    if (enabled && status == 0) {
        if (!query) query = (query_fn)symbol("vx_mpm_query");
        uint64_t value = 0;
        if (query(device, 0xB00, 0, &value) != 0 || !value) {
            fprintf(stderr, "counter probe: invalid MCYCLE snapshot\n"); abort();
        }
        cycles += value;
        launches++;
    }
    return status;
}
