#pragma once
#include "common.h"
struct phase_args_t {
    kernel_arg_t original;
    uint64_t entry_cycle;
    uint64_t return_cycle;
    uint64_t before_program;
    uint64_t after_program;
    uint64_t after_wait;
};
