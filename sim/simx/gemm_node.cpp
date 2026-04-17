// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "gemm_node.h"

#include <cassert>
#include <cstring>

#include "core.h"
#include "debug.h"
#include "rvfloats.h"

using namespace vortex;

namespace {

// Total bytes per MXU weight buffer we track. Kernel weight_reg stores
// (MXU_KT * MXU_NT / 2) bytes per micro-tile, but multiple K-blocks can be
// loaded back-to-back — allocate a generous buffer.
constexpr uint32_t WEIGHT_REG_BYTES = 64 * 1024;

// Scale/ZP register file per bank. RTL: MAX(MXU_ROW, MXU_COL) * WIDTH/8 = 32*2 = 64 bytes.
// Keep it at a power-of-two that fits the MMIO map (0x40 per bank × 2 banks).
constexpr uint32_t SZ_REG_BYTES     = 0x40;

// Small fixed completion delay after CLEAR (cycles) so that the SW polling loop
// can observe occupied_=1 at least once.
constexpr uint64_t CLEAR_DELAY_CYCLES = 8;

// Pack the STATE/ALLOC response word: bit0=success/occupied, bits[30:1]=generation.
uint32_t pack_state(bool bit0, uint32_t gen) {
  return (uint32_t(bit0) & 1u) | ((gen & 0x7fffffffu) << 1);
}

} // anonymous namespace

GemmNode::GemmNode(Core* core)
  : core_(core)
  , occupied_(false)
  , generation_(0)
  , completion_cycle_(0)
  , cycle_counter_(0)
  , expected_words_(0)
  , tmem_(TMEM_SIZE, 0)
  , acc_mem_(ACC_MEM_FP32_COUNT, 0.0f)
{
  for (int b = 0; b < 2; ++b) {
    mxu_.weight_reg[b].assign(WEIGHT_REG_BYTES, 0);
    mxu_.scale_reg[b].assign(SZ_REG_BYTES, 0);
    mxu_.zp_reg[b].assign(SZ_REG_BYTES, 0);
    mxu_.wtrans[b] = false;
  }
  cmd_buf_.reserve(3);
}

void GemmNode::reset() {
  occupied_ = false;
  generation_ = 0;
  completion_cycle_ = 0;
  cycle_counter_ = 0;
  cmd_buf_.clear();
  expected_words_ = 0;
  std::fill(tmem_.begin(), tmem_.end(), uint8_t(0));
  std::fill(acc_mem_.begin(), acc_mem_.end(), 0.0f);
  for (int b = 0; b < 2; ++b) {
    std::fill(mxu_.weight_reg[b].begin(), mxu_.weight_reg[b].end(), uint8_t(0));
    std::fill(mxu_.scale_reg[b].begin(), mxu_.scale_reg[b].end(), uint8_t(0));
    std::fill(mxu_.zp_reg[b].begin(), mxu_.zp_reg[b].end(), uint8_t(0));
    mxu_.wtrans[b] = false;
  }
}

uint64_t GemmNode::mmio_read(uint64_t addr, uint32_t size) {
  const uint64_t off = addr - BASE_ADDR;

  if (off == OFF_ALLOC) {
    // Allocate on read: if not occupied, take it; advance generation.
    uint32_t ret;
    if (!occupied_) {
      generation_ = (generation_ + 1) & 0x7fffffffu;
      occupied_ = true;
      ret = pack_state(true, generation_);
    } else {
      ret = pack_state(false, generation_);
    }
    DP(3, "GemmNode: ALLOC read -> 0x" << std::hex << ret << " (occupied=" << occupied_ << ", gen=" << std::dec << generation_ << ")");
    return uint64_t(ret) & ((size >= 4) ? 0xffffffffULL : ((1ULL << (size * 8)) - 1ULL));
  }

  if (off == OFF_STATE) {
    uint32_t ret = pack_state(occupied_, generation_);
    DP(3, "GemmNode: STATE read -> 0x" << std::hex << ret);
    return uint64_t(ret) & ((size >= 4) ? 0xffffffffULL : ((1ULL << (size * 8)) - 1ULL));
  }

  // STREAM is write-only; other offsets are reserved. Return 0.
  DP(3, "GemmNode: unexpected read at offset 0x" << std::hex << off);
  return 0;
}

void GemmNode::mmio_write(uint64_t addr, const void* data, uint32_t size) {
  const uint64_t off = addr - BASE_ADDR;

  if (off == OFF_STREAM) {
    // STREAM accepts 64-bit words. Extract lower `size*8` bits as the word.
    uint64_t w = 0;
    assert(size <= 8);
    std::memcpy(&w, data, size);
    push_stream_word(w);
    return;
  }

  // Writes to ALLOC/STATE are ignored (as per RTL: these are RO from SW side).
  DP(3, "GemmNode: ignored write at offset 0x" << std::hex << off);
}

void GemmNode::push_stream_word(uint64_t w) {
  cmd_buf_.push_back(w);
  if (cmd_buf_.size() == 1) {
    uint8_t op = uint8_t(w & 0xf);
    expected_words_ = opcode_word_count(op);
    if (expected_words_ <= 0) {
      DP(1, "GemmNode: unknown opcode 0x" << std::hex << int(op) << ", dropping");
      cmd_buf_.clear();
      expected_words_ = 0;
      return;
    }
  }
  if (int(cmd_buf_.size()) == expected_words_) {
    dispatch();
    cmd_buf_.clear();
    expected_words_ = 0;
  }
}

int GemmNode::opcode_word_count(uint8_t op) const {
  switch (op) {
    case OP_DMA_LOAD:
    case OP_DMA_STORE:         return 3;
    case OP_MXU_LOAD_QPARAM:
    case OP_MXU_LOAD_INPUT:
    case OP_MXU_STORE_OUTPUT:  return 2;
    case OP_NOTIFY:
    case OP_WAIT:
    case OP_MXU_LOAD_WEIGHT:
    case OP_CLEAR:             return 1;
    default:                   return 0;
  }
}

void GemmNode::dispatch() {
  uint8_t op = uint8_t(cmd_buf_[0] & 0xf);
  const uint64_t* w = cmd_buf_.data();
  switch (op) {
    case OP_DMA_LOAD:          handle_dma_load(w);         break;
    case OP_DMA_STORE:         handle_dma_store(w);        break;
    case OP_NOTIFY:            /* no-op (sequential) */    break;
    case OP_WAIT:              /* no-op (sequential) */    break;
    case OP_MXU_LOAD_WEIGHT:   handle_mxu_load_weight(w);  break;
    case OP_MXU_LOAD_QPARAM:   handle_mxu_load_qparam(w);  break;
    case OP_MXU_LOAD_INPUT:    handle_mxu_load_input(w);   break;
    case OP_MXU_STORE_OUTPUT:  handle_mxu_store_output(w); break;
    case OP_CLEAR:             handle_clear();             break;
    default:                   /* already filtered */      break;
  }
}

// ============================================================================
// Stage-3+ handlers: stubs for now (filled in later stages).
// ============================================================================

// DMA word encoding (kernel common.h, VX_cmd_constructor):
//   w0: [op: 4b @0] [dram_base: 36b @4] [tmem_base: 24b @40]
//   w1: [bound: 16b @0] [dram_stride: 16b @16] [tmem_stride: 16b @32]
//   w2: [seg_size: 32b @0]
// Strides and seg_size are in BYTES. tmem_base is a byte offset into TMEM.
void GemmNode::handle_dma_load(const uint64_t* w) {
  uint64_t w0 = w[0], w1 = w[1], w2 = w[2];
  uint64_t dram_base   = (w0 >> 4)  & 0xFFFFFFFFFULL;
  uint32_t tmem_base   = uint32_t((w0 >> 40) & 0xFFFFFFu);
  uint32_t bound       = uint32_t(w1 & 0xFFFFu);
  uint32_t dram_stride = uint32_t((w1 >> 16) & 0xFFFFu);
  uint32_t tmem_stride = uint32_t((w1 >> 32) & 0xFFFFu);
  uint32_t seg_size    = uint32_t(w2 & 0xFFFFFFFFu);

  DP(2, "GemmNode: DMA_LOAD tmem=0x" << std::hex << tmem_base << " <- dram=0x" << dram_base
        << " bound=" << std::dec << bound << " tmem_stride=" << tmem_stride
        << " dram_stride=" << dram_stride << " seg_size=" << seg_size);

  for (uint32_t i = 0; i < bound; ++i) {
    uint64_t src = dram_base + uint64_t(i) * dram_stride;
    uint32_t dst = tmem_base + i * tmem_stride;
    if (uint64_t(dst) + seg_size > tmem_.size()) {
      DP(1, "GemmNode: DMA_LOAD TMEM overflow: dst=0x" << std::hex << dst
            << " seg_size=0x" << seg_size);
      return;
    }
    core_->dcache_read(&tmem_[dst], src, seg_size);
  }
}

void GemmNode::handle_dma_store(const uint64_t* w) {
  uint64_t w0 = w[0], w1 = w[1], w2 = w[2];
  // Note: for STORE, cmd_constructor sets rs1=tmem (src), rs2=dram (dst) BUT the
  // kernel encoding is symmetric — tmem_base@40, dram_base@4 — so we parse the
  // same fields and just reverse direction.
  uint64_t dram_base   = (w0 >> 4)  & 0xFFFFFFFFFULL;
  uint32_t tmem_base   = uint32_t((w0 >> 40) & 0xFFFFFFu);
  uint32_t bound       = uint32_t(w1 & 0xFFFFu);
  uint32_t dram_stride = uint32_t((w1 >> 16) & 0xFFFFu);
  uint32_t tmem_stride = uint32_t((w1 >> 32) & 0xFFFFu);
  uint32_t seg_size    = uint32_t(w2 & 0xFFFFFFFFu);

  DP(2, "GemmNode: DMA_STORE tmem=0x" << std::hex << tmem_base << " -> dram=0x" << dram_base
        << " bound=" << std::dec << bound << " tmem_stride=" << tmem_stride
        << " dram_stride=" << dram_stride << " seg_size=" << seg_size);

  for (uint32_t i = 0; i < bound; ++i) {
    uint32_t src = tmem_base + i * tmem_stride;
    uint64_t dst = dram_base + uint64_t(i) * dram_stride;
    if (uint64_t(src) + seg_size > tmem_.size()) {
      DP(1, "GemmNode: DMA_STORE TMEM overflow: src=0x" << std::hex << src
            << " seg_size=0x" << seg_size);
      return;
    }
    core_->dcache_write(&tmem_[src], dst, seg_size);
  }
}

// MXU_LOAD_WEIGHT word encoding (kernel common.h):
//   w0: [op:4 @0] [tmem_base:24 @4] [stride:16 @28] [bound:16 @44] [reg_idx:1 @60] [wtrans:1 @61]
// Unit: stride/bound are in bytes; seg_size is implicit = MXU_KT * (MXU_NT/2) = 512 bytes
// per micro-tile (INT4 packed 32x32 weight matrix).
void GemmNode::handle_mxu_load_weight(const uint64_t* w) {
  uint64_t w0 = w[0];
  uint32_t tmem_base = uint32_t((w0 >> 4)  & 0xFFFFFFu);
  uint32_t stride    = uint32_t((w0 >> 28) & 0xFFFFu);
  uint32_t bound     = uint32_t((w0 >> 44) & 0xFFFFu);
  uint32_t reg_idx   = uint32_t((w0 >> 60) & 0x1u);
  uint32_t wtrans    = uint32_t((w0 >> 61) & 0x1u);

  const uint32_t seg_size = MXU_KT * (MXU_NT / 2);  // 32 * 16 = 512 bytes (INT4 packed)

  DP(2, "GemmNode: MXU_LOAD_WEIGHT reg=" << reg_idx << " wtrans=" << wtrans
        << " tmem=0x" << std::hex << tmem_base
        << " bound=" << std::dec << bound << " stride=" << stride);

  if (reg_idx > 1) {
    DP(1, "GemmNode: MXU_LOAD_WEIGHT bad reg_idx");
    return;
  }
  auto& reg = mxu_.weight_reg[reg_idx];
  if (uint64_t(bound) * seg_size > reg.size()) {
    reg.assign(uint64_t(bound) * seg_size + seg_size, 0);
  }
  for (uint32_t i = 0; i < bound; ++i) {
    uint32_t src = tmem_base + i * stride;
    if (uint64_t(src) + seg_size > tmem_.size()) {
      DP(1, "GemmNode: MXU_LOAD_WEIGHT TMEM overflow");
      return;
    }
    std::memcpy(&reg[i * seg_size], &tmem_[src], seg_size);
  }
  mxu_.wtrans[reg_idx] = (wtrans != 0);
}

// MXU_LOAD_QPARAM word encoding (kernel common.h):
//   w0: [op:4 @0]  [tmem_base:24 @4]  [mxu_base:24 @28]
//   w1: [bound:16 @0] [mxu_stride:16 @16] [tmem_stride:16 @32]
//
// The MXU scale/zp register file layout (per VX_gemm_unit.sv):
//   SCALE_REG0_BASE = 0x00 (MXU_NT * SCALE_BYTES = 64B)
//   SCALE_REG1_BASE = 0x40 (next 64B)
//   ZP_REG0_BASE    = 0x80
//   ZP_REG1_BASE    = 0xC0
//
// The kernel sends bound=2 with mxu_dst_stride = 0x80: so two iterations write
// [SCALE_REGn][ZP_REGn] for the chosen double-buffer bank.
void GemmNode::handle_mxu_load_qparam(const uint64_t* w) {
  uint64_t w0 = w[0], w1 = w[1];
  uint32_t tmem_base   = uint32_t((w0 >> 4)  & 0xFFFFFFu);
  uint32_t mxu_base    = uint32_t((w0 >> 28) & 0xFFFFFFu);
  uint32_t bound       = uint32_t(w1        & 0xFFFFu);
  uint32_t mxu_stride  = uint32_t((w1 >> 16) & 0xFFFFu);
  uint32_t tmem_stride = uint32_t((w1 >> 32) & 0xFFFFu);

  const uint32_t seg_size = MXU_NT * SCALE_BYTES;  // 32 * 2 = 64 bytes

  DP(2, "GemmNode: MXU_LOAD_QPARAM mxu=0x" << std::hex << mxu_base
        << " <- tmem=0x" << tmem_base
        << " bound=" << std::dec << bound << " tmem_stride=" << tmem_stride
        << " mxu_stride=" << mxu_stride);

  for (uint32_t i = 0; i < bound; ++i) {
    uint32_t src = tmem_base + i * tmem_stride;
    uint32_t dst = mxu_base + i * mxu_stride;
    if (uint64_t(src) + seg_size > tmem_.size()) {
      DP(1, "GemmNode: MXU_LOAD_QPARAM TMEM overflow");
      return;
    }
    // Route dst to the appropriate register. Register map:
    //   [0x00..0x40) -> scale_reg[0]
    //   [0x40..0x80) -> scale_reg[1]
    //   [0x80..0xC0) -> zp_reg[0]
    //   [0xC0..0x100) -> zp_reg[1]
    std::vector<uint8_t>* target = nullptr;
    uint32_t target_off = dst;
    if (dst < 0x40) { target = &mxu_.scale_reg[0]; target_off = dst; }
    else if (dst < 0x80) { target = &mxu_.scale_reg[1]; target_off = dst - 0x40; }
    else if (dst < 0xC0) { target = &mxu_.zp_reg[0];    target_off = dst - 0x80; }
    else if (dst < 0x100){ target = &mxu_.zp_reg[1];    target_off = dst - 0xC0; }
    else {
      DP(1, "GemmNode: MXU_LOAD_QPARAM dst 0x" << std::hex << dst << " out of range");
      return;
    }
    if (target_off + seg_size > target->size()) {
      DP(1, "GemmNode: MXU_LOAD_QPARAM register overflow off=0x"
            << std::hex << target_off);
      return;
    }
    std::memcpy(&(*target)[target_off], &tmem_[src], seg_size);
  }
}

// MXU_LOAD_INPUT word encoding:
//   w0: [op:4 @0]  [acc_mem_base:24 @4]  [tmem_base:24 @28]
//       [qdir:1 @52] [zreg:1 @53] [sreg:1 @54] [wreg:1 @55]
//       [is_last:1 @56] [is_accum:1 @57]
//   w1: [bound:16 @0] [stride:16 @16] [acc_cnt:32 @32]
//
// Reference (no prealign, per fpint_emul.sv `fpint_gemm_ref`):
//   For each output element (m, n):
//     acc_fp = is_accum ? acc_mem[m*MXU_NT + n] : 0
//     for k in 0..MXU_KT-1:
//       in_val = fp16_to_fp32(input_tmem[m*stride + k*2])
//       wt_val = signed INT4 weight @ (k, n) or (n, k) if wtrans
//       g      = (qdir==QCOL) ? n : k      // scale/zp group index
//       sc_val = fp16_to_fp32(scale_reg[sreg][g])
//       ze_val = int16_t zp_reg[zreg][g]
//       prod   = in_val * (sc_val * (wt_val - ze_val))
//       acc_fp += prod
//     acc_mem[m*MXU_NT + n] = acc_fp
void GemmNode::handle_mxu_load_input(const uint64_t* w) {
  uint64_t w0 = w[0], w1 = w[1];
  uint32_t acc_mem_base = uint32_t((w0 >> 4)  & 0xFFFFFFu);
  uint32_t tmem_base    = uint32_t((w0 >> 28) & 0xFFFFFFu);
  uint32_t qdir         = uint32_t((w0 >> 52) & 0x1u);
  uint32_t zreg_idx     = uint32_t((w0 >> 53) & 0x1u);
  uint32_t sreg_idx     = uint32_t((w0 >> 54) & 0x1u);
  uint32_t wreg_idx     = uint32_t((w0 >> 55) & 0x1u);
  uint32_t is_last      = uint32_t((w0 >> 56) & 0x1u);
  uint32_t is_accum     = uint32_t((w0 >> 57) & 0x1u);
  uint32_t bound        = uint32_t(w1 & 0xFFFFu);          // M (current rows)
  uint32_t stride       = uint32_t((w1 >> 16) & 0xFFFFu);  // bytes between M rows in TMEM
  uint32_t acc_cnt      = uint32_t((w1 >> 32) & 0xFFFFFFFFu);
  (void)is_last; (void)acc_cnt;  // functional model doesn't need these

  DP(2, "GemmNode: MXU_LOAD_INPUT acc=0x" << std::hex << acc_mem_base
        << " in_tmem=0x" << tmem_base << std::dec
        << " M=" << bound << " stride=" << stride
        << " is_accum=" << is_accum << " qdir=" << qdir
        << " wreg=" << wreg_idx << " sreg=" << sreg_idx << " zreg=" << zreg_idx);

  // Scale register view (FP16)
  const uint16_t* scale_ptr = reinterpret_cast<const uint16_t*>(mxu_.scale_reg[sreg_idx].data());
  // Zero-point register view (INT16 signed)
  const int16_t* zp_ptr = reinterpret_cast<const int16_t*>(mxu_.zp_reg[zreg_idx].data());

  // Weight bytes (INT4 packed)
  const uint8_t* w_bytes = mxu_.weight_reg[wreg_idx].data();
  const bool wtrans = mxu_.wtrans[wreg_idx];

  // acc_mem is indexed as flat FP32 array. byte_off / 4 = float index.
  // Each M row takes MXU_NT FP32 values = 128 bytes.
  if ((acc_mem_base & 0x3) != 0) {
    DP(1, "GemmNode: acc_mem_base 0x" << std::hex << acc_mem_base << " not FP32-aligned");
    return;
  }
  const uint32_t acc_base_f32 = acc_mem_base / 4;

  for (uint32_t m = 0; m < bound; ++m) {
    // Read one row of MXU_KT FP16 inputs from TMEM
    uint32_t in_off = tmem_base + m * stride;
    if (uint64_t(in_off) + MXU_KT * 2 > tmem_.size()) {
      DP(1, "GemmNode: MXU_LOAD_INPUT TMEM row overflow");
      return;
    }
    float in_fp[MXU_KT];
    for (uint32_t k = 0; k < MXU_KT; ++k) {
      uint16_t h;
      std::memcpy(&h, &tmem_[in_off + k * 2], 2);
      uint32_t f = rv_htof_s(h, 0, nullptr);
      std::memcpy(&in_fp[k], &f, 4);
    }

    for (uint32_t n = 0; n < MXU_NT; ++n) {
      uint32_t acc_idx = acc_base_f32 + m * MXU_NT + n;
      if (acc_idx >= acc_mem_.size()) {
        DP(1, "GemmNode: acc_mem overflow idx=" << acc_idx);
        return;
      }
      float acc = is_accum ? acc_mem_[acc_idx] : 0.0f;

      // For QCOL, scale/zp are constant across k (indexed by n only)
      float sc_qcol = 0.0f;
      float zp_qcol = 0.0f;
      if (qdir == 0) {
        uint32_t f = rv_htof_s(scale_ptr[n], 0, nullptr);
        std::memcpy(&sc_qcol, &f, 4);
        zp_qcol = float(zp_ptr[n]);
      }

      for (uint32_t k = 0; k < MXU_KT; ++k) {
        // INT4 weight unpack:
        //  wtrans=0: weight stored as [K, N] (low-nibble = even index)
        //  wtrans=1: weight stored as [N, K]
        uint32_t w_idx = wtrans ? (n * MXU_KT + k) : (k * MXU_NT + n);
        uint32_t byte_idx = w_idx >> 1;
        uint32_t nibble_hi = w_idx & 1;
        int32_t wv = unpack_int4(w_bytes, byte_idx, nibble_hi);

        // scale/zp selection
        float sc, zp;
        if (qdir == 0) {
          sc = sc_qcol;
          zp = zp_qcol;
        } else {
          uint32_t f = rv_htof_s(scale_ptr[k], 0, nullptr);
          std::memcpy(&sc, &f, 4);
          zp = float(zp_ptr[k]);
        }

        float prod = in_fp[k] * (sc * (float(wv) - zp));
        acc += prod;
      }

      acc_mem_[acc_idx] = acc;
    }
  }
}

// MXU_STORE_OUTPUT word encoding:
//   w0: [op:4 @0] [acc_mem_base:24 @4] [tmem_base:24 @28]
//   w1: [bound:16 @0] [stride:16 @16]
//
// Per VX_gemm_node.sv: seg_size = MXU_NT * 2 * bound (entire M×N tile as one
// segment). Each M row contributes MXU_NT FP16 values = 64 bytes, written
// contiguously starting at tmem_base. The `stride` field is currently unused
// by the kernel (sent as 0) — if non-zero, treat it as per-row byte stride.
void GemmNode::handle_mxu_store_output(const uint64_t* w) {
  uint64_t w0 = w[0], w1 = w[1];
  uint32_t acc_mem_base = uint32_t((w0 >> 4)  & 0xFFFFFFu);
  uint32_t tmem_base    = uint32_t((w0 >> 28) & 0xFFFFFFu);
  uint32_t bound        = uint32_t(w1        & 0xFFFFu);
  uint32_t stride       = uint32_t((w1 >> 16) & 0xFFFFu);
  const uint32_t row_bytes = MXU_NT * 2;  // 64 bytes
  if (stride == 0) stride = row_bytes;

  DP(2, "GemmNode: MXU_STORE_OUTPUT tmem=0x" << std::hex << tmem_base
        << " <- acc=0x" << acc_mem_base
        << " M=" << std::dec << bound << " stride=" << stride);

  if ((acc_mem_base & 0x3) != 0) {
    DP(1, "GemmNode: acc_mem_base 0x" << std::hex << acc_mem_base << " not FP32-aligned");
    return;
  }
  const uint32_t acc_base_f32 = acc_mem_base / 4;

  for (uint32_t m = 0; m < bound; ++m) {
    uint32_t dst = tmem_base + m * stride;
    if (uint64_t(dst) + row_bytes > tmem_.size()) {
      DP(1, "GemmNode: MXU_STORE_OUTPUT TMEM overflow");
      return;
    }
    for (uint32_t n = 0; n < MXU_NT; ++n) {
      uint32_t acc_idx = acc_base_f32 + m * MXU_NT + n;
      if (acc_idx >= acc_mem_.size()) {
        DP(1, "GemmNode: acc_mem read overflow idx=" << acc_idx);
        return;
      }
      float f = acc_mem_[acc_idx];
      uint32_t fbits;
      std::memcpy(&fbits, &f, 4);
      uint16_t h = rv_ftoh_s(fbits, 0, nullptr);
      std::memcpy(&tmem_[dst + n * 2], &h, 2);
    }
  }
}

void GemmNode::handle_clear() {
  completion_cycle_ = cycle_counter_ + CLEAR_DELAY_CYCLES;
  DP(2, "GemmNode: CLEAR at cycle " << cycle_counter_ << ", completes at " << completion_cycle_);
}

int32_t GemmNode::unpack_int4(const uint8_t* bytes, uint32_t byte_idx, uint32_t nibble_hi) {
  uint8_t b = bytes[byte_idx];
  uint8_t n = nibble_hi ? uint8_t(b >> 4) : uint8_t(b & 0xf);
  // Sign-extend 4 bits
  int32_t v = int32_t(n);
  if (v & 0x8) v -= 0x10;
  return v;
}

void GemmNode::tick() {
  ++cycle_counter_;
  if (occupied_ && completion_cycle_ > 0 && cycle_counter_ >= completion_cycle_) {
    DP(2, "GemmNode: entry cleared at cycle " << cycle_counter_);
    occupied_ = false;
    completion_cycle_ = 0;
  }
}
