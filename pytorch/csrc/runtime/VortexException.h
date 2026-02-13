#pragma once

#include <c10/util/Exception.h>

/// Check Vortex return codes.  On failure, reports file/line to PyTorch error system.
#define VORTEX_CHECK(EXPR, ...)                                                        \
  do {                                                                                 \
    const int __err = (EXPR);                                                          \
    if (C10_UNLIKELY(__err != 0)) {                                                    \
      TORCH_CHECK(false,                                                               \
          "Vortex runtime error (code ", __err, ") at ",                                \
          __FILE__, ":", __LINE__, " in ", __func__, ". ", ##__VA_ARGS__);              \
    }                                                                                  \
  } while (0)
