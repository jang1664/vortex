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

#include <algorithm>
#include <cassert>
#include <cstring>
#include <iostream>
#include <unordered_set>

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
constexpr uint64_t WRITE_DRAIN_CYCLES = 8;

// Pack the STATE/ALLOC response word: bit0=success/occupied, bits[30:1]=generation.
uint32_t pack_state(bool bit0, uint32_t gen) {
  return (uint32_t(bit0) & 1u) | ((gen & 0x7fffffffu) << 1);
}

constexpr uint32_t GN_JOB_ENTRY_BITS      = 4;
constexpr uint32_t GN_JOB_GEN_BITS        = 16;
constexpr uint32_t GN_ALLOC_SUCC_BIT      = 0;
constexpr uint32_t GN_ALLOC_ENTRY_LSB     = 1;
constexpr uint32_t GN_ALLOC_OWNER_LSB     = GN_ALLOC_ENTRY_LSB + GN_JOB_ENTRY_BITS;
constexpr uint32_t GN_ALLOC_GEN_LSB       = GN_ALLOC_OWNER_LSB + 4;
constexpr uint32_t GN_CTRL_VALID_BIT      = 0;
constexpr uint32_t GN_CTRL_OCCUPY_BIT     = 1;
constexpr uint32_t GN_CTRL_WORKING_BIT    = 2;
constexpr uint32_t GN_CTRL_OWNER_LSB      = 3;
constexpr uint32_t GN_CTRL_GEN_LSB        = GN_CTRL_OWNER_LSB + 4;

uint32_t bit_mask(uint32_t bits) {
  return (bits >= 32) ? 0xffffffffu : ((1u << bits) - 1u);
}

uint64_t byte_mask(uint32_t size) {
  return (size >= 8) ? 0xffffffffffffffffULL : ((1ULL << (size * 8)) - 1ULL);
}

uint32_t ceil_div(uint32_t a, uint32_t b) {
  return (a + b - 1) / b;
}

uint32_t align_up(uint32_t value, uint32_t alignment) {
  return (value + alignment - 1) & ~(alignment - 1);
}

uint64_t align_up_u64(uint64_t value, uint64_t alignment) {
  return (value + alignment - 1) & ~(alignment - 1);
}

uint32_t min_left(uint32_t total, uint32_t base, uint32_t limit) {
  return (total > base) ? std::min(total - base, limit) : 0;
}

uint32_t log2_to_size(uint32_t log2_value, uint32_t fallback) {
  if (log2_value >= 31)
    return fallback;
  uint32_t value = 1u << log2_value;
  return value ? value : fallback;
}

} // anonymous namespace

GemmNode::GemmNode(Core* core)
  : core_(core)
  , occupied_(false)
  , generation_(0)
  , completion_cycle_(0)
  , cycle_counter_(0)
  , expected_words_(0)
  , mmio_mode_(MmioMode::Unknown)
  , descriptor_job_active_(false)
  , active_eid_(0)
  , outstanding_traffic_reads_(0)
  , outstanding_traffic_writes_(0)
  , descriptor_start_cycle_(0)
  , descriptor_compute_done_cycle_(0)
  , descriptor_last_issue_cycle_(0)
  , traffic_queues_(NUM_DMA_CHANNELS)
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
  mmio_mode_ = MmioMode::Unknown;
  descriptor_job_active_ = false;
  active_eid_ = 0;
  outstanding_traffic_reads_ = 0;
  outstanding_traffic_writes_ = 0;
  descriptor_start_cycle_ = 0;
  descriptor_compute_done_cycle_ = 0;
  descriptor_last_issue_cycle_ = 0;
  for (auto& queue : traffic_queues_)
    queue.clear();
  traffic_stats_ = TrafficStats{};
  for (auto& entry : desc_entries_) {
    entry.regs.fill(0);
    entry.occupied = false;
    entry.working = false;
    entry.generation = 0;
  }
  std::fill(tmem_.begin(), tmem_.end(), uint8_t(0));
  std::fill(acc_mem_.begin(), acc_mem_.end(), 0.0f);
  for (int b = 0; b < 2; ++b) {
    std::fill(mxu_.weight_reg[b].begin(), mxu_.weight_reg[b].end(), uint8_t(0));
    std::fill(mxu_.scale_reg[b].begin(), mxu_.scale_reg[b].end(), uint8_t(0));
    std::fill(mxu_.zp_reg[b].begin(), mxu_.zp_reg[b].end(), uint8_t(0));
    mxu_.wtrans[b] = false;
  }
}

bool GemmNode::busy() const {
  if (occupied_)
    return true;
  for (const auto& entry : desc_entries_) {
    if (entry.occupied)
      return true;
  }
  return false;
}

uint64_t GemmNode::mmio_read(uint64_t addr, uint32_t size) {
  const uint64_t off = addr - BASE_ADDR;

  if (off == OFF_ALLOC) {
    // Allocate on read: the descriptor ABI packs entry/owner/generation fields
    // at different positions from the older stream-only STATE register.
    uint32_t ret;
    auto& entry = desc_entries_[0];
    if (!occupied_ && !entry.occupied) {
      generation_ = (generation_ + 1) & 0x7fffffffu;
      entry.generation = (entry.generation + 1) & bit_mask(GN_JOB_GEN_BITS);
      entry.regs.fill(0);
      entry.occupied = true;
      entry.working = false;
      occupied_ = true;
      mmio_mode_ = MmioMode::Unknown;
      ret = pack_alloc_response(true, 0, entry.generation);
    } else {
      ret = pack_alloc_response(false, 0, entry.generation);
    }
    DP(3, "GemmNode: ALLOC read -> 0x" << std::hex << ret << " (occupied=" << occupied_ << ", gen=" << std::dec << generation_ << ")");
    return uint64_t(ret) & byte_mask(size);
  }

  uint64_t desc_value = 0;
  if (mmio_mode_ != MmioMode::RawStream && descriptor_read(off, size, &desc_value)) {
    return desc_value & byte_mask(size);
  }

  if (off == OFF_STATE && mmio_mode_ == MmioMode::RawStream) {
    uint32_t ret = pack_state(occupied_, generation_);
    DP(3, "GemmNode: STATE read -> 0x" << std::hex << ret);
    return uint64_t(ret) & byte_mask(size);
  }

  // STREAM is write-only; other offsets are reserved. Return 0.
  DP(3, "GemmNode: unexpected read at offset 0x" << std::hex << off);
  return 0;
}

void GemmNode::mmio_write(uint64_t addr, const void* data, uint32_t size) {
  const uint64_t off = addr - BASE_ADDR;

  if (mmio_mode_ != MmioMode::RawStream && descriptor_write(off, data, size)) {
    mmio_mode_ = MmioMode::Descriptor;
    return;
  }

  if (off == OFF_STREAM) {
    // STREAM accepts 64-bit words. Extract lower `size*8` bits as the word.
    uint64_t w = 0;
    assert(size <= 8);
    std::memcpy(&w, data, size);
    mmio_mode_ = MmioMode::RawStream;
    desc_entries_[0].occupied = false;
    desc_entries_[0].working = false;
    push_stream_word(w);
    return;
  }

  // Writes to ALLOC/STATE are ignored (as per RTL: these are RO from SW side).
  DP(3, "GemmNode: ignored write at offset 0x" << std::hex << off);
}

uint32_t GemmNode::pack_alloc_response(bool success, uint32_t eid, uint32_t generation) const {
  uint32_t value = 0;
  value |= (uint32_t(success) & 1u) << GN_ALLOC_SUCC_BIT;
  value |= (eid & bit_mask(GN_JOB_ENTRY_BITS)) << GN_ALLOC_ENTRY_LSB;
  value |= (generation & bit_mask(GN_JOB_GEN_BITS)) << GN_ALLOC_GEN_LSB;
  return value;
}

uint32_t GemmNode::descriptor_control_value(uint32_t eid) const {
  const auto& entry = desc_entries_[eid];
  uint32_t value = entry.regs[REG_CONTROL] & (1u << GN_CTRL_VALID_BIT);
  value |= (uint32_t(entry.occupied) & 1u) << GN_CTRL_OCCUPY_BIT;
  value |= (uint32_t(entry.working) & 1u) << GN_CTRL_WORKING_BIT;
  value |= (entry.generation & bit_mask(GN_JOB_GEN_BITS)) << GN_CTRL_GEN_LSB;
  return value;
}

bool GemmNode::decode_descriptor_offset(uint64_t off, uint32_t* eid, uint32_t* reg_idx, uint32_t* byte_lane) const {
  if (off < DESC_WINDOW_BASE)
    return false;
  const uint64_t desc_off = off - DESC_WINDOW_BASE;
  const uint32_t entry_id = uint32_t(desc_off / DESC_ENTRY_STRIDE);
  if (entry_id >= DESC_NUM_ENTRIES)
    return false;
  const uint32_t entry_off = uint32_t(desc_off % DESC_ENTRY_STRIDE);
  const uint32_t beat = entry_off / DESC_BEAT_BYTES;
  const uint32_t word_in_beat = (entry_off % DESC_BEAT_BYTES) / 4;
  const uint32_t reg = beat * DESC_WORDS_PER_BEAT + word_in_beat;
  if (reg >= DESC_NUM_REGS32)
    return false;

  *eid = entry_id;
  *reg_idx = reg;
  *byte_lane = entry_off % 4;
  return true;
}

bool GemmNode::descriptor_read(uint64_t off, uint32_t size, uint64_t* value) const {
  if (size == 0 || size > 8)
    return false;

  uint64_t result = 0;
  for (uint32_t i = 0; i < size; ++i) {
    uint32_t eid, reg_idx, byte_lane;
    if (!decode_descriptor_offset(off + i, &eid, &reg_idx, &byte_lane))
      return false;
    uint32_t reg_value = (reg_idx == REG_CONTROL)
                         ? descriptor_control_value(eid)
                         : desc_entries_[eid].regs[reg_idx];
    result |= uint64_t((reg_value >> (byte_lane * 8)) & 0xffu) << (i * 8);
  }

  *value = result;
  return true;
}

bool GemmNode::descriptor_write(uint64_t off, const void* data, uint32_t size) {
  if (size == 0 || size > 8)
    return false;

  // The legacy stream path writes 64-bit command words at off=8. The current
  // descriptor kernel uses 32-bit writes, so keep that single case for raw mode.
  if (off == OFF_STREAM && size == 8 && mmio_mode_ == MmioMode::Unknown)
    return false;

  const auto* bytes = reinterpret_cast<const uint8_t*>(data);
  bool control_touched[DESC_NUM_ENTRIES] = {};

  for (uint32_t i = 0; i < size; ++i) {
    uint32_t eid, reg_idx, byte_lane;
    if (!decode_descriptor_offset(off + i, &eid, &reg_idx, &byte_lane))
      return false;
    auto& entry = desc_entries_[eid];
    uint32_t reg_value = entry.regs[reg_idx];
    reg_value &= ~(0xffu << (byte_lane * 8));
    reg_value |= uint32_t(bytes[i]) << (byte_lane * 8);
    if (reg_idx == REG_CONTROL) {
      entry.regs[REG_CONTROL] = reg_value & (1u << GN_CTRL_VALID_BIT);
      control_touched[eid] = true;
    } else {
      entry.regs[reg_idx] = reg_value;
    }
  }

  for (uint32_t eid = 0; eid < DESC_NUM_ENTRIES; ++eid) {
    auto& entry = desc_entries_[eid];
    if (control_touched[eid]
        && entry.occupied
        && !entry.working
        && ((entry.regs[REG_CONTROL] >> GN_CTRL_VALID_BIT) & 1u)) {
      entry.working = true;
      if (execute_descriptor_job(eid)) {
        start_descriptor_timing(eid);
      } else {
        active_eid_ = eid;
        finish_descriptor_job();
      }
    }
  }

  return true;
}

uint64_t GemmNode::reg_u64(const JobEntry& entry, uint32_t lo_reg) const {
  return uint64_t(entry.regs[lo_reg]) | (uint64_t(entry.regs[lo_reg + 1]) << 32);
}

uint16_t GemmNode::read_u16(uint64_t addr) const {
  uint16_t value = 0;
  core_->dcache_read(&value, addr, sizeof(value));
  return value;
}

int16_t GemmNode::read_i16(uint64_t addr) const {
  int16_t value = 0;
  core_->dcache_read(&value, addr, sizeof(value));
  return value;
}

void GemmNode::write_u16(uint64_t addr, uint16_t value) const {
  core_->dcache_write(&value, addr, sizeof(value));
}

float GemmNode::fp16_to_float(uint16_t value) const {
  uint32_t bits = rv_htof_s(value, 0, nullptr);
  float out;
  std::memcpy(&out, &bits, sizeof(out));
  return out;
}

uint16_t GemmNode::float_to_fp16(float value) const {
  uint32_t bits;
  std::memcpy(&bits, &value, sizeof(bits));
  return rv_ftoh_s(bits, 0, nullptr);
}

uint64_t GemmNode::input_offset(uint32_t M, uint32_t K, uint32_t dma_mt, uint32_t dma_kt, uint32_t gm, uint32_t gk) const {
  const uint32_t mt = gm / dma_mt;
  const uint32_t kt = gk / dma_kt;
  const uint32_t k_tiles = ceil_div(K, dma_kt);

  uint64_t offset = 0;
  for (uint32_t mt_i = 0; mt_i < mt; ++mt_i) {
    uint32_t cur_m = min_left(M, mt_i * dma_mt, dma_mt);
    uint32_t cur_m_slot = align_up(cur_m, 8);
    for (uint32_t kt_i = 0; kt_i < k_tiles; ++kt_i) {
      uint32_t cur_k = min_left(K, kt_i * dma_kt, dma_kt);
      offset += uint64_t(cur_m_slot) * cur_k * 2;
    }
  }
  uint32_t cur_m = min_left(M, mt * dma_mt, dma_mt);
  uint32_t cur_m_slot = align_up(cur_m, 8);
  for (uint32_t kt_i = 0; kt_i < kt; ++kt_i) {
    uint32_t cur_k = min_left(K, kt_i * dma_kt, dma_kt);
    offset += uint64_t(cur_m_slot) * cur_k * 2;
  }

  const uint32_t local_m = gm - mt * dma_mt;
  const uint32_t local_k = gk - kt * dma_kt;
  const uint32_t kb = local_k / MXU_KT;
  const uint32_t k_in_mxu = local_k % MXU_KT;
  offset += uint64_t(kb) * cur_m * MXU_KT * 2;
  offset += uint64_t(local_m) * MXU_KT * 2;
  offset += uint64_t(k_in_mxu) * 2;
  return offset;
}

uint64_t GemmNode::weight_offset(uint32_t N, uint32_t K, uint32_t dma_kt, uint32_t gn, uint32_t gk, bool wtrans, uint32_t* nibble_hi) const {
  const uint32_t kt = gk / dma_kt;
  const uint32_t nt = gn / MXU_NT;
  const uint32_t local_k = gk - kt * dma_kt;
  const uint32_t kb = local_k / MXU_KT;
  const uint32_t k_in_mxu = local_k % MXU_KT;
  const uint32_t n_in_mxu = gn % MXU_NT;
  const uint32_t n_tiles = N / MXU_NT;
  const uint32_t seg_size = MXU_KT * (MXU_NT / 2);

  uint64_t offset = 0;
  for (uint32_t kt_i = 0; kt_i < kt; ++kt_i) {
    uint32_t cur_k = min_left(K, kt_i * dma_kt, dma_kt);
    offset += uint64_t(n_tiles) * (cur_k / MXU_KT) * seg_size;
  }

  const uint32_t cur_k = min_left(K, kt * dma_kt, dma_kt);
  const uint32_t kb_per_kt = cur_k / MXU_KT;
  offset += uint64_t(nt) * kb_per_kt * seg_size;
  offset += uint64_t(kb) * seg_size;

  if (!wtrans) {
    offset += uint64_t(k_in_mxu) * (MXU_NT / 2) + (n_in_mxu / 2);
    *nibble_hi = n_in_mxu & 1u;
  } else {
    offset += uint64_t(n_in_mxu) * (MXU_KT / 2) + (k_in_mxu / 2);
    *nibble_hi = k_in_mxu & 1u;
  }
  return offset;
}

uint64_t GemmNode::scale_offset(uint32_t N, uint32_t K, uint32_t dma_kt, uint32_t dma_nt, uint32_t qblk, uint32_t qdir, uint32_t gn, uint32_t gk) const {
  const uint32_t kt = gk / dma_kt;
  const uint32_t nt_dma = gn / dma_nt;
  const uint32_t n_tiles_dma = ceil_div(N, dma_nt);
  const uint32_t ng_per_mxu_nt = ceil_div(MXU_NT, qblk);

  auto slot_bytes = [&](uint32_t ck, uint32_t cn) -> uint64_t {
    uint64_t actual = (qdir == 0)
                    ? uint64_t(ck / qblk) * cn * 2
                    : uint64_t(cn / MXU_NT) * ck * ng_per_mxu_nt * 2;
    return align_up_u64(actual, 512);
  };

  uint64_t offset = 0;
  for (uint32_t kt_i = 0; kt_i < kt; ++kt_i) {
    uint32_t cur_k = min_left(K, kt_i * dma_kt, dma_kt);
    for (uint32_t nt_i = 0; nt_i < n_tiles_dma; ++nt_i) {
      uint32_t cur_n = min_left(N, nt_i * dma_nt, dma_nt);
      offset += slot_bytes(cur_k, cur_n);
    }
  }
  const uint32_t cur_k = min_left(K, kt * dma_kt, dma_kt);
  for (uint32_t nt_i = 0; nt_i < nt_dma; ++nt_i) {
    uint32_t cur_n = min_left(N, nt_i * dma_nt, dma_nt);
    offset += slot_bytes(cur_k, cur_n);
  }

  const uint32_t nb = (gn - nt_dma * dma_nt) / MXU_NT;
  const uint32_t n_in_mxu = gn % MXU_NT;
  const uint32_t k_in_tile = gk - kt * dma_kt;
  if (qdir == 0) {
    const uint32_t groups_per_kt = cur_k / qblk;
    const uint32_t group = k_in_tile / qblk;
    offset += uint64_t(nb) * groups_per_kt * MXU_NT * 2;
    offset += uint64_t(group) * MXU_NT * 2;
    offset += uint64_t(n_in_mxu) * 2;
  } else {
    const uint32_t ng = n_in_mxu / qblk;
    offset += uint64_t(nb) * cur_k * ng_per_mxu_nt * 2;
    offset += uint64_t(k_in_tile) * ng_per_mxu_nt * 2;
    offset += uint64_t(ng) * 2;
  }
  return offset;
}

uint64_t GemmNode::output_offset(uint32_t M, uint32_t N, uint32_t dma_mt, uint32_t gm, uint32_t gn) const {
  const uint32_t m_pad = align_up(M, 8);
  const uint32_t mt = gm / dma_mt;
  const uint32_t nt = gn / MXU_NT;
  const uint32_t n_tiles = N / MXU_NT;

  uint64_t offset = 0;
  for (uint32_t mt_i = 0; mt_i < mt; ++mt_i) {
    uint32_t cur_m_pad = min_left(m_pad, mt_i * dma_mt, dma_mt);
    offset += uint64_t(n_tiles) * cur_m_pad * MXU_NT * 2;
  }

  const uint32_t cur_m_pad = min_left(m_pad, mt * dma_mt, dma_mt);
  const uint32_t local_m = gm - mt * dma_mt;
  const uint32_t n_in_mxu = gn % MXU_NT;
  offset += uint64_t(nt) * cur_m_pad * MXU_NT * 2;
  offset += uint64_t(local_m) * MXU_NT * 2;
  offset += uint64_t(n_in_mxu) * 2;
  return offset;
}

uint64_t GemmNode::naive_input_offset(uint32_t K, uint32_t gm, uint32_t gk) const {
  return (uint64_t(gm) * K + gk) * 2;
}

uint64_t GemmNode::naive_weight_offset(uint32_t N, uint32_t K, uint32_t gn, uint32_t gk, bool wtrans, uint32_t* nibble_hi) const {
  if (!wtrans) {
    const uint64_t packed_n = (uint64_t(N) + 1) / 2;
    *nibble_hi = gn & 1u;
    return uint64_t(gk) * packed_n + gn / 2;
  }

  const uint64_t packed_k = (uint64_t(K) + 1) / 2;
  *nibble_hi = gk & 1u;
  return uint64_t(gn) * packed_k + gk / 2;
}

uint64_t GemmNode::naive_qparam_offset(uint32_t N, uint32_t qblk, uint32_t qdir, uint32_t gn, uint32_t gk) const {
  if (qdir == 0)
    return (uint64_t(gk / qblk) * N + gn) * 2;

  const uint64_t n_groups = (uint64_t(N) + qblk - 1) / qblk;
  return (uint64_t(gk) * n_groups + gn / qblk) * 2;
}

uint64_t GemmNode::naive_output_offset(uint32_t N, uint32_t gm, uint32_t gn) const {
  return (uint64_t(gm) * N + gn) * 2;
}

bool GemmNode::execute_descriptor_job(uint32_t eid) {
  const auto& entry = desc_entries_[eid];

  const uint64_t input_base  = reg_u64(entry, REG_INPUT_BASE_LO);
  const uint64_t weight_base = reg_u64(entry, REG_WEIGHT_BASE_LO);
  const uint64_t output_base = reg_u64(entry, REG_OUTPUT_BASE_LO);
  const uint64_t scale_base  = reg_u64(entry, REG_SCALE_BASE_LO);
  const uint64_t zp_base     = reg_u64(entry, REG_ZP_BASE_LO);

  const uint32_t M      = entry.regs[REG_M_ORIG];
  const uint32_t N      = entry.regs[REG_N_ORIG];
  const uint32_t K      = entry.regs[REG_K_ORIG];
  const uint32_t qblk   = log2_to_size(entry.regs[REG_QBLK_ORIG], 32);
  const uint32_t target_M = entry.regs[REG_M_TARGET];
  const uint32_t target_N = entry.regs[REG_N_TARGET];
  const uint32_t target_K = entry.regs[REG_K_TARGET];
  const uint32_t m_start  = entry.regs[REG_M_START];
  const uint32_t n_start  = entry.regs[REG_N_START];
  const bool wtrans = (entry.regs[REG_WTRANS] & 1u) != 0;
  const uint32_t qdir = entry.regs[REG_QDIR] & 1u;
#ifdef GEMM_NAIVE
  const uint32_t dma_mt = GEMM_FSM_MT;
  const uint32_t dma_kt = GEMM_FSM_KT;
  const uint32_t dma_nt = GEMM_FSM_NT;
#else
  const uint32_t dma_mt = log2_to_size(entry.regs[REG_LOG2_DMA_MT], 128);
  const uint32_t dma_kt = log2_to_size(entry.regs[REG_LOG2_DMA_KT], 128);
  const uint32_t dma_nt = log2_to_size(entry.regs[REG_LOG2_DMA_NT], 128);
#endif

  DP(2, "GemmNode: descriptor job eid=" << eid
        << " M=" << M << " N=" << N << " K=" << K
        << " target=(" << target_M << "," << target_N << "," << target_K << ")"
        << " start=(" << m_start << "," << n_start << ")"
        << " qblk=" << qblk << " qdir=" << qdir << " wtrans=" << wtrans);

  if (M == 0 || N == 0 || K == 0 || qblk == 0
   || target_M == 0 || target_N == 0 || target_K == 0
   || dma_mt == 0 || dma_kt == 0 || dma_nt == 0) {
    DP(1, "GemmNode: descriptor job has invalid dimensions");
    return false;
  }

  const bool m_bounds_valid = m_start <= M && target_M <= M - m_start;
  const bool n_bounds_valid = n_start <= N && target_N <= N - n_start;
  if (!m_bounds_valid || !n_bounds_valid || target_K > K) {
    DP(1, "GemmNode: descriptor job is out of bounds"
          << " M=" << M << " N=" << N << " K=" << K
          << " target=(" << target_M << "," << target_N << "," << target_K << ")"
          << " start=(" << m_start << "," << n_start << ")");
    return false;
  }

  for (uint32_t m = 0; m < target_M; ++m) {
    const uint32_t gm = m_start + m;
    for (uint32_t n = 0; n < target_N; ++n) {
      const uint32_t gn = n_start + n;

      float sum = 0.0f;
      for (uint32_t k = 0; k < target_K; ++k) {
        uint32_t nibble_hi = 0;
#ifdef GEMM_NAIVE
        const uint64_t input_off = naive_input_offset(K, gm, k);
        const uint64_t weight_off = naive_weight_offset(N, K, gn, k, wtrans, &nibble_hi);
        const uint64_t qparam_off = naive_qparam_offset(N, qblk, qdir, gn, k);
#else
        const uint64_t input_off = input_offset(M, K, dma_mt, dma_kt, gm, k);
        const uint64_t weight_off = weight_offset(N, K, dma_kt, gn, k, wtrans, &nibble_hi);
        const uint64_t qparam_off = scale_offset(N, K, dma_kt, dma_nt, qblk, qdir, gn, k);
#endif

        const uint64_t in_addr = input_base + input_off;
        const uint64_t w_addr = weight_base + weight_off;
        const uint64_t sc_addr = scale_base + qparam_off;
        const uint64_t zp_addr = zp_base + qparam_off;

        uint8_t w_byte = 0;
        core_->dcache_read(&w_byte, w_addr, 1);

        const float a = fp16_to_float(read_u16(in_addr));
        const int32_t wv = unpack_int4(&w_byte, 0, nibble_hi);
        const float scale = fp16_to_float(read_u16(sc_addr));
        const float zp = float(read_i16(zp_addr));
        sum += a * (float(wv) - zp) * scale;
      }

#ifdef GEMM_NAIVE
      const uint64_t output_off = naive_output_offset(N, gm, gn);
#else
      const uint64_t output_off = output_offset(M, N, dma_mt, gm, gn);
#endif
      write_u16(output_base + output_off, float_to_fp16(sum));
    }
  }
  return true;
}

void GemmNode::enqueue_traffic_block(uint64_t addr, bool write) {
  const uint64_t block_addr = addr & ~(uint64_t(MEM_BLOCK_SIZE) - 1);
#ifdef GEMM_NAIVE
  traffic_queues_.at(0).push_back({block_addr, write});
#else
  const uint32_t channel = uint32_t((block_addr / MEM_BLOCK_SIZE) % NUM_DMA_CHANNELS);
  traffic_queues_.at(channel).push_back({block_addr, write});
#endif
}

void GemmNode::enqueue_traffic_range(uint64_t addr, uint64_t size, bool write) {
  if (size == 0)
    return;

  const uint64_t first = addr & ~(uint64_t(MEM_BLOCK_SIZE) - 1);
  const uint64_t end = align_up_u64(addr + size, MEM_BLOCK_SIZE);
  for (uint64_t block = first; block < end; block += MEM_BLOCK_SIZE)
    enqueue_traffic_block(block, write);
}

void GemmNode::build_descriptor_traffic(uint32_t eid) {
  const auto& entry = desc_entries_[eid];
  const uint64_t input_base  = reg_u64(entry, REG_INPUT_BASE_LO);
  const uint64_t weight_base = reg_u64(entry, REG_WEIGHT_BASE_LO);
  const uint64_t output_base = reg_u64(entry, REG_OUTPUT_BASE_LO);
  const uint64_t scale_base  = reg_u64(entry, REG_SCALE_BASE_LO);
  const uint64_t zp_base     = reg_u64(entry, REG_ZP_BASE_LO);

#ifndef GEMM_NAIVE
  const uint32_t M = entry.regs[REG_M_ORIG];
#endif
  const uint32_t N = entry.regs[REG_N_ORIG];
  const uint32_t K = entry.regs[REG_K_ORIG];
  const uint32_t qblk = log2_to_size(entry.regs[REG_QBLK_ORIG], 32);
  const uint32_t target_M = entry.regs[REG_M_TARGET];
  const uint32_t target_N = entry.regs[REG_N_TARGET];
  const uint32_t target_K = entry.regs[REG_K_TARGET];
  const uint32_t m_start = entry.regs[REG_M_START];
  const uint32_t n_start = entry.regs[REG_N_START];
  const bool wtrans = (entry.regs[REG_WTRANS] & 1u) != 0;
  const uint32_t qdir = entry.regs[REG_QDIR] & 1u;
#ifdef GEMM_NAIVE
  const uint32_t dma_mt = GEMM_FSM_MT;
  const uint32_t dma_kt = GEMM_FSM_KT;
  const uint32_t dma_nt = GEMM_FSM_NT;
#else
  const uint32_t dma_mt = log2_to_size(entry.regs[REG_LOG2_DMA_MT], 128);
  const uint32_t dma_kt = log2_to_size(entry.regs[REG_LOG2_DMA_KT], 128);
  const uint32_t dma_nt = log2_to_size(entry.regs[REG_LOG2_DMA_NT], 128);
#endif

  auto enqueue_unique = [this](const std::unordered_set<uint64_t>& blocks, bool write) {
    std::vector<uint64_t> ordered(blocks.begin(), blocks.end());
    std::sort(ordered.begin(), ordered.end());
    for (uint64_t block : ordered)
      enqueue_traffic_block(block, write);
  };

  const uint32_t mt_dim = ceil_div(target_M, dma_mt);
  const uint32_t nt_dim = ceil_div(target_N, dma_nt);
  const uint32_t kt_dim = ceil_div(target_K, dma_kt);

  for (uint32_t mt = 0; mt < mt_dim; ++mt) {
    const uint32_t local_m0 = mt * dma_mt;
    const uint32_t mt_eff = min_left(target_M, local_m0, dma_mt);
    const uint32_t gm0 = m_start + local_m0;

    for (uint32_t nt = 0; nt < nt_dim; ++nt) {
      const uint32_t local_n0 = nt * dma_nt;
      const uint32_t nt_eff = min_left(target_N, local_n0, dma_nt);
      const uint32_t gn0 = n_start + local_n0;

      for (uint32_t kt = 0; kt < kt_dim; ++kt) {
        const uint32_t gk0 = kt * dma_kt;
        const uint32_t kt_eff = min_left(target_K, gk0, dma_kt);

        // Input is transferred once per output tile. Repeated N tiles retain
        // the same addresses, allowing the naive cache model to observe reuse.
        for (uint32_t m = 0; m < mt_eff; ++m) {
#ifdef GEMM_NAIVE
          const uint64_t offset = naive_input_offset(K, gm0 + m, gk0);
#else
          const uint64_t offset = input_offset(M, K, dma_mt, dma_kt, gm0 + m, gk0);
#endif
          enqueue_traffic_range(input_base + offset, uint64_t(kt_eff) * 2, false);
        }

        std::unordered_set<uint64_t> weight_blocks;
        std::unordered_set<uint64_t> qparam_blocks;
        for (uint32_t n = 0; n < nt_eff; ++n) {
          const uint32_t gn = gn0 + n;
          for (uint32_t k = 0; k < kt_eff; ++k) {
            const uint32_t gk = gk0 + k;
            uint32_t nibble_hi = 0;
#ifdef GEMM_NAIVE
            const uint64_t weight_off = naive_weight_offset(N, K, gn, gk, wtrans, &nibble_hi);
            const uint64_t qparam_off = naive_qparam_offset(N, qblk, qdir, gn, gk);
#else
            const uint64_t weight_off = weight_offset(N, K, dma_kt, gn, gk, wtrans, &nibble_hi);
            const uint64_t qparam_off = scale_offset(N, K, dma_kt, dma_nt, qblk, qdir, gn, gk);
#endif
            weight_blocks.insert((weight_base + weight_off) & ~(uint64_t(MEM_BLOCK_SIZE) - 1));
            qparam_blocks.insert((scale_base + qparam_off) & ~(uint64_t(MEM_BLOCK_SIZE) - 1));
            qparam_blocks.insert((zp_base + qparam_off) & ~(uint64_t(MEM_BLOCK_SIZE) - 1));
          }
        }
        enqueue_unique(weight_blocks, false);
        enqueue_unique(qparam_blocks, false);
      }

      // Improve output layout is grouped by MXU_NT columns, whereas naive is
      // row-major. Emit contiguous ranges that match each physical layout.
      for (uint32_t m = 0; m < mt_eff; ++m) {
#ifdef GEMM_NAIVE
        const uint64_t offset = naive_output_offset(N, gm0 + m, gn0);
        enqueue_traffic_range(output_base + offset, uint64_t(nt_eff) * 2, true);
#else
        for (uint32_t nb = 0; nb < nt_eff; nb += MXU_NT) {
          const uint32_t nb_eff = std::min(MXU_NT, nt_eff - nb);
          const uint64_t offset = output_offset(M, N, dma_mt, gm0 + m, gn0 + nb);
          enqueue_traffic_range(output_base + offset, uint64_t(nb_eff) * 2, true);
        }
#endif
      }
    }
  }
}

void GemmNode::start_descriptor_timing(uint32_t eid) {
  active_eid_ = eid;
  descriptor_job_active_ = true;
  outstanding_traffic_reads_ = 0;
  outstanding_traffic_writes_ = 0;
  descriptor_start_cycle_ = cycle_counter_;
  descriptor_last_issue_cycle_ = cycle_counter_;
  traffic_stats_ = TrafficStats{};
  for (auto& queue : traffic_queues_)
    queue.clear();

  const auto& entry = desc_entries_[eid];
  const uint64_t macs = uint64_t(entry.regs[REG_M_TARGET])
                      * uint64_t(entry.regs[REG_N_TARGET])
                      * uint64_t(entry.regs[REG_K_TARGET]);
  const uint64_t mxu_macs_per_cycle = uint64_t(MXU_KT) * MXU_NT;
  traffic_stats_.compute_cycles = std::max<uint64_t>(1, (macs + mxu_macs_per_cycle - 1) / mxu_macs_per_cycle);
  descriptor_compute_done_cycle_ = descriptor_start_cycle_ + traffic_stats_.compute_cycles;
  build_descriptor_traffic(eid);
}

bool GemmNode::traffic_queues_empty() const {
  for (const auto& queue : traffic_queues_) {
    if (!queue.empty())
      return false;
  }
  return true;
}

void GemmNode::finish_descriptor_job() {
  auto& entry = desc_entries_[active_eid_];
  entry.regs[REG_CONTROL] &= ~(1u << GN_CTRL_VALID_BIT);
  entry.working = false;
  entry.occupied = false;
  occupied_ = false;

  if (descriptor_job_active_) {
    const uint64_t elapsed = cycle_counter_ - descriptor_start_cycle_;
#ifdef GEMM_NAIVE
    const char* backend = "naive-cache";
#else
    const char* backend = "improve-tmem";
#endif
    std::cout << "PERF: core" << core_->id()
              << ": gemm backend=" << backend
              << ", cycles=" << elapsed
              << ", compute_cycles=" << traffic_stats_.compute_cycles
              << ", cache_reads=" << traffic_stats_.cache_reads
              << ", cache_writes=" << traffic_stats_.cache_writes
              << ", bypass_reads=" << traffic_stats_.bypass_reads
              << ", bypass_writes=" << traffic_stats_.bypass_writes
              << ", max_outstanding_reads=" << traffic_stats_.max_outstanding_reads
              << ", max_outstanding_writes=" << traffic_stats_.max_outstanding_writes
              << std::endl;
  }
  descriptor_job_active_ = false;
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

  if (!descriptor_job_active_)
    return;

#ifdef GEMM_NAIVE
  if (!core_->gemm_cache_rsp_port.empty()) {
    core_->gemm_cache_rsp_port.pop();
    assert(outstanding_traffic_reads_ != 0);
    --outstanding_traffic_reads_;
  }

  auto& queue = traffic_queues_.at(0);
  if (!queue.empty() && !core_->gemm_cache_req_port.full()) {
    const auto req_desc = queue.front();
    queue.pop_front();
    MemReq req(req_desc.addr, req_desc.write, AddrType::Global,
               0, core_->id(), 0);
    core_->gemm_cache_req_port.push(req);
    descriptor_last_issue_cycle_ = cycle_counter_;
    if (req_desc.write) {
      ++traffic_stats_.cache_writes;
    } else {
      ++traffic_stats_.cache_reads;
      ++outstanding_traffic_reads_;
    }
  }
#else
  for (uint32_t channel = 0; channel < NUM_DMA_CHANNELS; ++channel) {
    auto& rsp_port = core_->gemm_dma_rsp_ports.at(channel);
    if (!rsp_port.empty()) {
      const auto rsp = rsp_port.front();
      rsp_port.pop();
      if (rsp.tag == 1) {
        assert(outstanding_traffic_writes_ != 0);
        --outstanding_traffic_writes_;
      } else {
        assert(outstanding_traffic_reads_ != 0);
        --outstanding_traffic_reads_;
      }
    }

    auto& queue = traffic_queues_.at(channel);
    auto& req_port = core_->gemm_dma_req_ports.at(channel);
    if (!queue.empty() && !req_port.full()) {
      const auto req_desc = queue.front();
      queue.pop_front();
      MemReq req(req_desc.addr, req_desc.write, AddrType::Global,
                 req_desc.write ? 1 : 0, core_->id(), 0, req_desc.write);
      req_port.push(req);
      descriptor_last_issue_cycle_ = cycle_counter_;
      if (req_desc.write) {
        ++traffic_stats_.bypass_writes;
        ++outstanding_traffic_writes_;
      } else {
        ++traffic_stats_.bypass_reads;
        ++outstanding_traffic_reads_;
      }
    }
  }
#endif

  traffic_stats_.max_outstanding_reads = std::max(
      traffic_stats_.max_outstanding_reads, outstanding_traffic_reads_);
  traffic_stats_.max_outstanding_writes = std::max(
      traffic_stats_.max_outstanding_writes, outstanding_traffic_writes_);

#ifdef GEMM_NAIVE
  const bool traffic_done = traffic_queues_empty()
                         && outstanding_traffic_reads_ == 0
                         && cycle_counter_ >= descriptor_last_issue_cycle_ + WRITE_DRAIN_CYCLES;
#else
  const bool traffic_done = traffic_queues_empty()
                         && outstanding_traffic_reads_ == 0
                         && outstanding_traffic_writes_ == 0;
#endif
  if (traffic_done && cycle_counter_ >= descriptor_compute_done_cycle_)
    finish_descriptor_job();
}
