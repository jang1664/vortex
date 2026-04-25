// reference.h — CPU golden softmax for validation. Not used by the bench
// binary; only by the functional test.

#pragma once

#include <cstdint>
#include <vector>

void softmax_cpu(const std::vector<float>& input,
                 std::vector<float>&       output,
                 uint32_t batch_size,
                 uint32_t num_heads,
                 uint32_t seq_len_q,
                 uint32_t seq_len_k,
                 bool     use_mask,
                 float    scale);
