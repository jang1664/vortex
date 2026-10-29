#pragma once
#include "../../../kernel/include/vx_flash_attention.h"

// Tail packing only concerns HBM K/V inputs. Attention intermediates stay local.
struct DecoderFlashArgs {
  vx_flash_attention_args_t attention;
  uint64_t key_source;
  uint64_t key_source_bytes;
  uint64_t key_padded_bytes;
  uint64_t value_source;
  uint64_t value_scale_source;
  uint64_t value_zero_source;
  uint32_t value_source_rows;
  uint32_t reserved;
};
