#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>
#include <unistd.h>
#include <vector>

#include <vortex.h>

#include "common.h"
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../vector_common/fp16.h"

namespace {

constexpr uint32_t kHeadDim = 128;
constexpr uint32_t kKvTile = 128;
constexpr uint64_t kDramAlign = 512;
constexpr uint64_t kTmemAlign = 512;

constexpr uint32_t log2_pow2(uint32_t value) {
  uint32_t result = 0;
  while ((uint32_t(1) << result) != value)
    ++result;
  return result;
}

uint32_t g_query_rows = 16;
uint32_t g_kv_length = 128;
bool g_causal = false;
bool g_pv_only = false;
uint32_t g_query_position_base = 0;
bool g_position_explicit = false;

vx_device_h g_device = nullptr;
vx_buffer_h g_kernel = nullptr;
vx_buffer_h g_args = nullptr;
vx_buffer_h g_q = nullptr;
vx_buffer_h g_k_weight = nullptr;
vx_buffer_h g_k_scale = nullptr;
vx_buffer_h g_k_zero = nullptr;
vx_buffer_h g_v_weight = nullptr;
vx_buffer_h g_v_scale = nullptr;
vx_buffer_h g_score = nullptr;
vx_buffer_h g_probability = nullptr;
vx_buffer_h g_partial = nullptr;
vx_buffer_h g_accumulator = nullptr;
vx_buffer_h g_row_max = nullptr;
vx_buffer_h g_row_sum = nullptr;
vx_buffer_h g_output = nullptr;

void cleanup() {
  vx_buffer_h buffers[] = {
      g_output, g_row_sum, g_row_max, g_accumulator, g_partial,
      g_probability, g_score, g_v_scale, g_v_weight,
      g_k_zero, g_k_scale, g_k_weight, g_q, g_args, g_kernel,
  };
  for (auto buffer : buffers) {
    if (buffer)
      vx_mem_free(buffer);
  }
  if (g_device)
    vx_dev_close(g_device);
}

#define RT_CHECK(expr)                                                        \
  do {                                                                        \
    const int status_ = (expr);                                               \
    if (status_ != 0) {                                                       \
      std::cerr << "Error: " #expr " returned " << status_ << std::endl;     \
      cleanup();                                                              \
      return 1;                                                               \
    }                                                                         \
  } while (false)

uint64_t align_up(uint64_t value, uint64_t alignment) {
  return (value + alignment - 1) / alignment * alignment;
}

uint8_t pack_int4(int8_t low, int8_t high) {
  return uint8_t(uint8_t(low) & 0xfu) | uint8_t((uint8_t(high) & 0xfu) << 4);
}

void usage(const char *program) {
  std::cout << "Usage: " << program
            << " [-m query_rows] [-n kv_length] [-c] [-P]"
               " [-p query_position_base]\n"
            << "  constraints: 1 <= query_rows <= 128, kv_length = 128\n";
}

bool parse_args(int argc, char **argv) {
  int option = 0;
  while ((option = getopt(argc, argv, "m:n:p:cPh")) != -1) {
    switch (option) {
      case 'm': g_query_rows = uint32_t(std::strtoul(optarg, nullptr, 0)); break;
      case 'n': g_kv_length = uint32_t(std::strtoul(optarg, nullptr, 0)); break;
      case 'p':
        g_query_position_base = uint32_t(std::strtoul(optarg, nullptr, 0));
        g_position_explicit = true;
        break;
      case 'c': g_causal = true; break;
      case 'P': g_pv_only = true; break;
      case 'h': usage(argv[0]); std::exit(0);
      default: usage(argv[0]); return false;
    }
  }
  if (g_query_rows == 0 || g_query_rows > FLASH_DMA_MT
      || g_kv_length != kKvTile) {
    usage(argv[0]);
    return false;
  }
  if (g_causal && !g_position_explicit)
    g_query_position_base = g_kv_length > g_query_rows
                              ? g_kv_length - g_query_rows : 0;
  return true;
}

struct test_data_t {
  std::vector<fp16_t> q;
  std::vector<int8_t> k;
  std::vector<int8_t> v;
  fp16_t k_scale;
  fp16_t v_scale;
};

test_data_t make_test_data() {
  test_data_t data;
  data.q.resize(size_t(g_query_rows) * kHeadDim);
  data.k.resize(size_t(g_kv_length) * kHeadDim);
  data.v.resize(size_t(g_kv_length) * kHeadDim);
  data.k_scale = float_to_fp16(1.0f / 32.0f);
  data.v_scale = float_to_fp16(1.0f / 16.0f);

  for (uint32_t row = 0; row < g_query_rows; ++row) {
    for (uint32_t d = 0; d < kHeadDim; ++d) {
      const float value = 0.0625f + float((row + d) & 3u) * 0.015625f;
      data.q[size_t(row) * kHeadDim + d] = float_to_fp16(value);
    }
  }

  for (uint32_t key = 0; key < g_kv_length; ++key) {
    for (uint32_t d = 0; d < kHeadDim; ++d) {
      data.k[size_t(key) * kHeadDim + d] =
          key == 96u ? int8_t(3) : int8_t(-2 + int((key + d) & 1u));
      data.v[size_t(key) * kHeadDim + d] =
          int8_t(int((key * 3u + d * 5u) % 7u) - 3);
    }
  }
  return data;
}

std::vector<uint8_t> tile_input(const std::vector<fp16_t> &input,
                                uint32_t rows, uint32_t cols) {
  const uint32_t rows_pad = align_up_pow2_u32(rows, 3u);
  std::vector<uint8_t> tiled(size_t(rows_pad) * cols * sizeof(fp16_t), 0);
  for (uint32_t row = 0; row < rows; ++row) {
    for (uint32_t col = 0; col < cols; ++col) {
      const fp16_t value = input[size_t(row) * cols + col];
      size_t offset = sizeof(fp16_t) * gemm_a_tiled_elem_offset(
          row, col, rows, cols,
          log2_pow2(FLASH_DMA_MT), log2_pow2(FLASH_MXU_KT));
      tiled[offset++] = uint8_t(value);
      tiled[offset++] = uint8_t(value >> 8);
    }
  }
  return tiled;
}

std::vector<uint8_t> tile_weight(const std::vector<int8_t> &kv,
                                 bool source_transposed) {
  const uint32_t tile_count = g_kv_length / kKvTile;
  const size_t tile_bytes = size_t(kHeadDim) * kKvTile / 2;
  std::vector<uint8_t> tiled(tile_count * tile_bytes);
  size_t offset = 0;

  for (uint32_t tile = 0; tile < tile_count; ++tile) {
    for (uint32_t nt = 0; nt < kHeadDim / FLASH_MXU_NT; ++nt) {
      for (uint32_t kb = 0; kb < kHeadDim / FLASH_MXU_KT; ++kb) {
        for (uint32_t k = 0; k < FLASH_MXU_KT; ++k) {
          for (uint32_t n = 0; n < FLASH_MXU_NT; n += 2) {
            const uint32_t gemm_k = kb * FLASH_MXU_KT + k;
            const uint32_t gemm_n0 = nt * FLASH_MXU_NT + n;
            const uint32_t gemm_n1 = gemm_n0 + 1;
            const uint32_t row0 = tile * kKvTile
                                + (source_transposed ? gemm_n0 : gemm_k);
            const uint32_t row1 = tile * kKvTile
                                + (source_transposed ? gemm_n1 : gemm_k);
            const uint32_t col0 = source_transposed ? gemm_k : gemm_n0;
            const uint32_t col1 = source_transposed ? gemm_k : gemm_n1;
            tiled[offset++] = pack_int4(
                kv[size_t(row0) * kHeadDim + col0],
                kv[size_t(row1) * kHeadDim + col1]);
          }
        }
      }
    }
  }
  return tiled;
}

std::vector<uint8_t> tile_quant_params(fp16_t value) {
  const uint32_t tile_count = g_kv_length / kKvTile;
  const size_t body_bytes = size_t(kHeadDim / FLASH_QBLK) * kKvTile * 2;
  const size_t tile_bytes = align_up(body_bytes, kDramAlign);
  std::vector<uint8_t> tiled(tile_count * tile_bytes, 0);
  for (uint32_t tile = 0; tile < tile_count; ++tile) {
    size_t offset = tile * tile_bytes;
    for (uint32_t nt = 0; nt < kKvTile / FLASH_MXU_NT; ++nt) {
      for (uint32_t group = 0; group < kHeadDim / FLASH_QBLK; ++group) {
        for (uint32_t n = 0; n < FLASH_MXU_NT; ++n) {
          tiled[offset++] = uint8_t(value);
          tiled[offset++] = uint8_t(value >> 8);
        }
      }
    }
  }
  return tiled;
}

struct reference_t {
  std::vector<fp16_t> output;
  std::vector<fp16_t> last_scores;
  std::vector<fp16_t> last_probabilities;
  std::vector<fp16_t> last_partial;
  std::vector<float> accumulator;
  std::vector<float> row_max;
  std::vector<float> row_sum;
  uint32_t later_max_updates = 0;
};

reference_t compute_reference(const test_data_t &data) {
  reference_t ref;
  ref.output.resize(size_t(g_query_rows) * kHeadDim);
  ref.last_scores.resize(size_t(g_query_rows) * kKvTile);
  ref.last_probabilities.resize(size_t(g_query_rows) * kKvTile);
  ref.last_partial.resize(size_t(g_query_rows) * kHeadDim);
  ref.accumulator.assign(size_t(g_query_rows) * kHeadDim, 0.0f);
  ref.row_max.assign(g_query_rows, -std::numeric_limits<float>::infinity());
  ref.row_sum.assign(g_query_rows, 0.0f);
  const float k_scale = fp16_to_float(data.k_scale);
  const float v_scale = fp16_to_float(data.v_scale);
  const float attention_scale = 1.0f / std::sqrt(float(kHeadDim));
  std::vector<float> scores(kKvTile);

  for (uint32_t tile = 0; tile < g_kv_length / kKvTile; ++tile) {
    for (uint32_t row = 0; row < g_query_rows; ++row) {
      std::fill(scores.begin(), scores.end(),
                -std::numeric_limits<float>::infinity());
      for (uint32_t col = 0; col < kKvTile; ++col) {
        const uint32_t key = tile * kKvTile + col;
        float dot = 0.0f;
        for (uint32_t d = 0; d < kHeadDim; ++d) {
          dot += fp16_to_float(data.q[size_t(row) * kHeadDim + d])
               * float(data.k[size_t(key) * kHeadDim + d]) * k_scale;
        }
        const fp16_t rounded_dot = float_to_fp16(dot);
        ref.last_scores[size_t(row) * kKvTile + col] = rounded_dot;
        const bool valid = !g_causal || key <= g_query_position_base + row;
        if (!valid)
          continue;
        scores[col] = fp16_to_float(rounded_dot) * attention_scale;
      }

      for (uint32_t block = 0; block < kKvTile / FLASH_MXU_NT; ++block) {
        const uint32_t begin = block * FLASH_MXU_NT;
        const uint32_t end = begin + FLASH_MXU_NT;
        float block_max = -std::numeric_limits<float>::infinity();
        for (uint32_t col = begin; col < end; ++col)
          block_max = std::max(block_max, scores[col]);

        const float old_max = ref.row_max[row];
        const float new_max = std::max(old_max, block_max);
        const float alpha = std::isinf(old_max)
                              ? 0.0f : std::exp(old_max - new_max);
        if (new_max > old_max) {
          for (uint32_t col = 0; col < begin; ++col) {
            const size_t index = size_t(row) * kKvTile + col;
            ref.last_probabilities[index] = float_to_fp16(
                fp16_to_float(ref.last_probabilities[index]) * alpha);
          }
          if (row == 0u && block > 0u)
            ++ref.later_max_updates;
        }

        float block_sum = 0.0f;
        for (uint32_t col = begin; col < end; ++col) {
          float probability = 0.0f;
          if (!std::isinf(scores[col]))
            probability = std::exp(scores[col] - new_max);
          ref.last_probabilities[size_t(row) * kKvTile + col] =
              float_to_fp16(probability);
          block_sum += probability;
        }
        ref.row_max[row] = new_max;
        ref.row_sum[row] = alpha * ref.row_sum[row] + block_sum;
      }
    }

    for (uint32_t row = 0; row < g_query_rows; ++row) {
      for (uint32_t d = 0; d < kHeadDim; ++d) {
        float partial = 0.0f;
        for (uint32_t col = 0; col < kKvTile; ++col) {
          const fp16_t p =
              ref.last_probabilities[size_t(row) * kKvTile + col];
          const uint32_t key = tile * kKvTile + col;
          partial += fp16_to_float(p)
                   * float(data.v[size_t(key) * kHeadDim + d]) * v_scale;
        }
        const fp16_t rounded_partial = float_to_fp16(partial);
        ref.last_partial[size_t(row) * kHeadDim + d] = rounded_partial;
        ref.accumulator[size_t(row) * kHeadDim + d] +=
            fp16_to_float(rounded_partial);
      }
    }
  }

  for (uint32_t row = 0; row < g_query_rows; ++row) {
    for (uint32_t d = 0; d < kHeadDim; ++d) {
      ref.output[size_t(row) * kHeadDim + d] = float_to_fp16(
          ref.accumulator[size_t(row) * kHeadDim + d] / ref.row_sum[row]);
    }
  }
  return ref;
}

bool allocate_tmem(kernel_arg_t &args, uint64_t available) {
  const uint64_t input_bytes = uint64_t(FLASH_DMA_MT) * FLASH_DMA_KT * 2;
  const uint64_t weight_bytes = uint64_t(FLASH_DMA_KT) * FLASH_DMA_NT / 2;
  const uint64_t quant_bytes =
      uint64_t(FLASH_DMA_KT / FLASH_QBLK) * FLASH_DMA_NT * 2;
  const uint64_t output_bytes = uint64_t(FLASH_DMA_MT) * FLASH_DMA_NT * 2;
  uint64_t cursor = 0;
  auto allocate = [&](uint64_t bytes, uint64_t &address) {
    cursor = align_up(cursor, kTmemAlign);
    if (cursor + bytes > available)
      return false;
    address = cursor;
    cursor += align_up(bytes, kTmemAlign);
    return true;
  };
  return allocate(input_bytes, args.lmem_ibuf[0])
      && allocate(input_bytes, args.lmem_ibuf[1])
      && allocate(weight_bytes, args.lmem_wbuf[0])
      && allocate(weight_bytes, args.lmem_wbuf[1])
      && allocate(quant_bytes, args.lmem_scbuf[0])
      && allocate(quant_bytes, args.lmem_scbuf[1])
      && allocate(quant_bytes, args.lmem_zpbuf[0])
      && allocate(quant_bytes, args.lmem_zpbuf[1])
      && allocate(output_bytes, args.lmem_obuf);
}

bool check_vector(const char *name, const std::vector<float> &actual,
                  const std::vector<float> &expected, float max_abs_limit,
                  float rel_l2_limit) {
  double squared_error = 0.0;
  double squared_ref = 0.0;
  float max_abs = 0.0f;
  size_t max_index = 0;
  for (size_t i = 0; i < actual.size(); ++i) {
    const float error = std::abs(actual[i] - expected[i]);
    if (error > max_abs) {
      max_abs = error;
      max_index = i;
    }
    squared_error += double(error) * error;
    squared_ref += double(expected[i]) * expected[i];
  }
  const double rel_l2 = std::sqrt(squared_error / std::max(squared_ref, 1e-30));
  std::cout << name << ": max_abs=" << max_abs << ", rel_l2=" << rel_l2
            << ", worst[" << max_index << "]=" << actual[max_index]
            << "/" << expected[max_index] << std::endl;
  return max_abs <= max_abs_limit && rel_l2 <= rel_l2_limit;
}

std::vector<fp16_t> detile(const std::vector<uint8_t> &tiled,
                           uint32_t rows, uint32_t cols, bool a_layout) {
  std::vector<fp16_t> row_major(size_t(rows) * cols);
  const auto *values = reinterpret_cast<const fp16_t *>(tiled.data());
  const uint32_t rows_pad = align_up_pow2_u32(rows, 3u);
  constexpr uint32_t kLog2DmaMt = log2_pow2(FLASH_DMA_MT);
  constexpr uint32_t kLog2MxuKt = log2_pow2(FLASH_MXU_KT);
  constexpr uint32_t kLog2MxuNt = log2_pow2(FLASH_MXU_NT);
  for (uint32_t row = 0; row < rows; ++row) {
    for (uint32_t col = 0; col < cols; ++col) {
      const uint64_t offset = a_layout
          ? gemm_a_tiled_elem_offset(
                row, col, rows_pad, cols, kLog2DmaMt, kLog2MxuKt)
          : gemm_c_tiled_elem_offset(
                row, col, rows_pad, cols, kLog2DmaMt, kLog2MxuNt);
      row_major[size_t(row) * cols + col] = values[offset];
    }
  }
  return row_major;
}

std::vector<float> fp16_vector_to_float(const std::vector<fp16_t> &values) {
  std::vector<float> result(values.size());
  for (size_t i = 0; i < values.size(); ++i)
    result[i] = fp16_to_float(values[i]);
  return result;
}

}  // namespace

int main(int argc, char **argv) {
  if (!parse_args(argc, argv))
    return argc > 1 ? 1 : 0;

  const uint32_t query_rows_pad = align_up_pow2_u32(g_query_rows, 3u);
  const uint32_t tile_count = g_kv_length / kKvTile;
  const float attention_scale = 1.0f / std::sqrt(float(kHeadDim));
  std::cout << "C4 W4A16/KV4 FlashAttention regression: M=" << g_query_rows
            << " (pad=" << query_rows_pad << "), Sk=" << g_kv_length
            << ", D=" << kHeadDim << ", tiles=" << tile_count
            << ", causal=" << g_causal << std::endl;

  const test_data_t data = make_test_data();
  const reference_t reference = compute_reference(data);
  const std::vector<uint8_t> q_tiled = tile_input(data.q, g_query_rows, kHeadDim);
  std::vector<uint8_t> p_tiled;
  if (g_pv_only) {
    p_tiled = tile_input(
        reference.last_probabilities, g_query_rows, kKvTile);
  }
  const std::vector<uint8_t> k_tiled = tile_weight(data.k, true);
  const std::vector<uint8_t> v_tiled = tile_weight(data.v, false);
  const std::vector<uint8_t> k_scales = tile_quant_params(data.k_scale);
  const std::vector<uint8_t> v_scales = tile_quant_params(data.v_scale);
  const std::vector<uint8_t> zeros = tile_quant_params(0);
  const size_t scratch_bytes = size_t(query_rows_pad) * kKvTile * 2;
  const size_t state_elements = size_t(g_query_rows) * kHeadDim;

  RT_CHECK(vx_dev_open(&g_device));
  uint64_t num_cores = 0, num_warps = 0, num_threads = 0;
  RT_CHECK(vx_dev_caps(g_device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(g_device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(g_device, VX_CAPS_NUM_THREADS, &num_threads));
  std::cout << "Device: cores=" << num_cores << ", warps=" << num_warps
            << ", threads=" << num_threads << std::endl;
  if (num_cores == 0) {
    std::cerr << "No device cores" << std::endl;
    cleanup();
    return 1;
  }

  auto alloc = [&](size_t bytes, uint32_t flags, vx_buffer_h *buffer) {
    return vx_mem_alloc_aligned(g_device, bytes, kDramAlign, flags, buffer);
  };
  RT_CHECK(alloc(q_tiled.size(), VX_MEM_READ, &g_q));
  RT_CHECK(alloc(k_tiled.size(), VX_MEM_READ, &g_k_weight));
  RT_CHECK(alloc(k_scales.size(), VX_MEM_READ, &g_k_scale));
  RT_CHECK(alloc(zeros.size(), VX_MEM_READ, &g_k_zero));
  RT_CHECK(alloc(v_tiled.size(), VX_MEM_READ, &g_v_weight));
  RT_CHECK(alloc(v_scales.size(), VX_MEM_READ, &g_v_scale));
  RT_CHECK(alloc(scratch_bytes, VX_MEM_READ_WRITE, &g_score));
  RT_CHECK(alloc(scratch_bytes, VX_MEM_READ_WRITE, &g_probability));
  RT_CHECK(alloc(scratch_bytes, VX_MEM_READ_WRITE, &g_partial));
  RT_CHECK(alloc(state_elements * sizeof(float), VX_MEM_READ_WRITE,
                 &g_accumulator));
  RT_CHECK(alloc(g_query_rows * sizeof(float), VX_MEM_READ_WRITE, &g_row_max));
  RT_CHECK(alloc(g_query_rows * sizeof(float), VX_MEM_READ_WRITE, &g_row_sum));
  RT_CHECK(alloc(state_elements * sizeof(fp16_t), VX_MEM_READ_WRITE, &g_output));

  RT_CHECK(vx_copy_to_dev(g_q, q_tiled.data(), 0, q_tiled.size()));
  RT_CHECK(vx_copy_to_dev(g_k_weight, k_tiled.data(), 0, k_tiled.size()));
  RT_CHECK(vx_copy_to_dev(g_k_scale, k_scales.data(), 0, k_scales.size()));
  RT_CHECK(vx_copy_to_dev(g_k_zero, zeros.data(), 0, zeros.size()));
  RT_CHECK(vx_copy_to_dev(g_v_weight, v_tiled.data(), 0, v_tiled.size()));
  RT_CHECK(vx_copy_to_dev(g_v_scale, v_scales.data(), 0, v_scales.size()));
  if (g_pv_only)
    RT_CHECK(vx_copy_to_dev(g_probability, p_tiled.data(), 0, p_tiled.size()));
  kernel_arg_t args = {};
  RT_CHECK(vx_mem_address(g_q, &args.q_base));
  RT_CHECK(vx_mem_address(g_k_weight, &args.k_weight_base));
  RT_CHECK(vx_mem_address(g_k_scale, &args.k_scale_base));
  RT_CHECK(vx_mem_address(g_k_zero, &args.k_zero_base));
  RT_CHECK(vx_mem_address(g_v_weight, &args.v_weight_base));
  RT_CHECK(vx_mem_address(g_v_scale, &args.v_scale_base));
  RT_CHECK(vx_mem_address(g_score, &args.score_base));
  RT_CHECK(vx_mem_address(g_probability, &args.probability_base));
  RT_CHECK(vx_mem_address(g_partial, &args.partial_base));
  RT_CHECK(vx_mem_address(g_accumulator, &args.accumulator_base));
  RT_CHECK(vx_mem_address(g_row_max, &args.row_max_base));
  RT_CHECK(vx_mem_address(g_row_sum, &args.row_sum_base));
  RT_CHECK(vx_mem_address(g_output, &args.output_base));
  args.k_weight_tile_bytes = size_t(kHeadDim) * kKvTile / 2;
  args.k_scale_tile_bytes = k_scales.size() / tile_count;
  args.k_zero_tile_bytes = zeros.size() / tile_count;
  args.query_rows = g_query_rows;
  args.query_rows_pad = query_rows_pad;
  args.kv_length = g_kv_length;
  args.kv_tile = kKvTile;
  args.head_dim = kHeadDim;
  args.causal = g_causal;
  args.pv_only = g_pv_only;
  args.query_position_base = g_query_position_base;
  args.attention_scale = attention_scale;

  const uint64_t tensor_mem_size = uint64_t(TMEM_BANK_SIZE) * NUM_DMA_CHANNELS;
  if (!allocate_tmem(args, tensor_mem_size)) {
    std::cerr << "TMEM layout exceeds " << tensor_mem_size << " bytes" << std::endl;
    cleanup();
    return 1;
  }

  RT_CHECK(vx_upload_kernel_file(g_device, "kernel.vxbin", &g_kernel));
  RT_CHECK(vx_mem_alloc(g_device, sizeof(args), VX_MEM_READ_WRITE, &g_args));
  RT_CHECK(vx_copy_to_dev(g_args, &args, 0, sizeof(args)));
  RT_CHECK(vx_start(g_device, g_kernel, g_args));
  RT_CHECK(vx_ready_wait(g_device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(&args, g_args, 0, sizeof(args)));

  std::vector<fp16_t> actual_output(state_elements);
  std::vector<float> actual_accumulator(state_elements);
  std::vector<float> actual_row_max(g_query_rows);
  std::vector<float> actual_row_sum(g_query_rows);
  std::vector<uint8_t> actual_score_tiled(scratch_bytes);
  std::vector<uint8_t> actual_probability_tiled(scratch_bytes);
  std::vector<uint8_t> actual_partial_tiled(scratch_bytes);
  RT_CHECK(vx_copy_from_dev(actual_output.data(), g_output, 0,
                            actual_output.size() * sizeof(fp16_t)));
  RT_CHECK(vx_copy_from_dev(actual_accumulator.data(), g_accumulator, 0,
                            actual_accumulator.size() * sizeof(float)));
  RT_CHECK(vx_copy_from_dev(actual_row_max.data(), g_row_max, 0,
                            actual_row_max.size() * sizeof(float)));
  RT_CHECK(vx_copy_from_dev(actual_row_sum.data(), g_row_sum, 0,
                            actual_row_sum.size() * sizeof(float)));
  RT_CHECK(vx_copy_from_dev(actual_score_tiled.data(), g_score, 0, scratch_bytes));
  RT_CHECK(vx_copy_from_dev(actual_probability_tiled.data(), g_probability, 0,
                            scratch_bytes));
  RT_CHECK(vx_copy_from_dev(actual_partial_tiled.data(), g_partial, 0,
                            scratch_bytes));

  std::cout << "Kernel status=" << args.status
            << ", qk_progress_events=" << args.qk_progress_events
            << ", pv_progress_events=" << args.pv_progress_events
            << ", later_max_updates=" << args.later_max_updates
            << ", completed_tiles=" << args.completed_kv_tiles << std::endl;
  const uint32_t expected_progress = kKvTile / FLASH_MXU_NT;
  bool passed = args.status == FLASH_STATUS_OK
             && args.pv_progress_events == expected_progress;
  if (!g_pv_only) {
    passed &= args.qk_progress_events == expected_progress
           && args.later_max_updates == reference.later_max_updates
           && args.later_max_updates > 0u
           && args.completed_kv_tiles == tile_count;
  }
  const auto actual_scores = detile(actual_score_tiled, g_query_rows,
                                    kKvTile, false);
  const auto actual_probabilities = detile(actual_probability_tiled,
                                           g_query_rows, kKvTile, true);
  const auto actual_partial = detile(actual_partial_tiled, g_query_rows,
                                     kHeadDim, false);
  if (!g_pv_only) {
    passed &= check_vector("last_scores", fp16_vector_to_float(actual_scores),
                           fp16_vector_to_float(reference.last_scores),
                           0.01f, 0.02f);
    passed &= check_vector("last_probabilities",
                           fp16_vector_to_float(actual_probabilities),
                           fp16_vector_to_float(reference.last_probabilities),
                           0.015f, 0.02f);
  }
  passed &= check_vector("last_partial", fp16_vector_to_float(actual_partial),
                         fp16_vector_to_float(reference.last_partial),
                         0.4f, 0.06f);
  if (!passed) {
    std::cout << "partial row 0 samples:";
    for (uint32_t d = 0; d < 8; ++d) {
      std::cout << " d" << d << "=" << fp16_to_float(actual_partial[d])
                << "/" << fp16_to_float(reference.last_partial[d]);
    }
    std::cout << std::endl;
    std::cout << "partial per-row max_abs:";
    for (uint32_t row = 0; row < g_query_rows; ++row) {
      float row_error = 0.0f;
      for (uint32_t d = 0; d < kHeadDim; ++d) {
        row_error = std::max(row_error, std::abs(
            fp16_to_float(actual_partial[size_t(row) * kHeadDim + d])
            - fp16_to_float(reference.last_partial[size_t(row) * kHeadDim + d])));
      }
      std::cout << " r" << row << "=" << row_error;
    }
    std::cout << std::endl;
  }
  if (!g_pv_only) {
    passed &= check_vector("output", fp16_vector_to_float(actual_output),
                           fp16_vector_to_float(reference.output),
                           0.035f, 0.06f);
    passed &= check_vector("accumulator", actual_accumulator,
                           reference.accumulator, 0.4f, 0.06f);
    passed &= check_vector("row_max", actual_row_max,
                           reference.row_max, 0.02f, 0.02f);
    passed &= check_vector("row_sum", actual_row_sum,
                           reference.row_sum, 8.0f, 0.06f);
  }
  std::cout << (passed ? "PASSED" : "FAILED") << std::endl;
  cleanup();
  return passed ? 0 : 1;
}
