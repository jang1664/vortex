#pragma once
#include "common.h"
// Original argument layout is a prefix; the original source remains unchanged.
struct phase_args_t {
    kernel_arg_t original;
    uint64_t entry_cycle;
    uint64_t return_cycle;
};
