#include "reference.h"

#include <algorithm>
#include <cmath>

void softmax_cpu(const std::vector<float>& input,
                 std::vector<float>&       output,
                 uint32_t batch_size,
                 uint32_t num_heads,
                 uint32_t seq_len_q,
                 uint32_t seq_len_k,
                 bool     use_mask,
                 float    scale) {
  for (uint32_t b = 0; b < batch_size; ++b) {
    for (uint32_t h = 0; h < num_heads; ++h) {
      for (uint32_t q = 0; q < seq_len_q; ++q) {
        uint32_t row_offset = ((b * num_heads + h) * seq_len_q + q) * seq_len_k;

        // Find max for numerical stability
        float max_val = -INFINITY;
        for (uint32_t k = 0; k < seq_len_k; ++k) {
          float val = input[row_offset + k] * scale;
          if (use_mask && k > q) {
            val = -INFINITY;
          }
          max_val = std::max(max_val, val);
        }

        // Compute exp and sum
        float sum = 0.0f;
        for (uint32_t k = 0; k < seq_len_k; ++k) {
          float val = input[row_offset + k] * scale;
          if (use_mask && k > q) {
            val = -INFINITY;
          }
          float exp_val = std::exp(val - max_val);
          output[row_offset + k] = exp_val;
          sum += exp_val;
        }

        // Normalize
        for (uint32_t k = 0; k < seq_len_k; ++k) {
          output[row_offset + k] /= sum;
        }
      }
    }
  }
}
