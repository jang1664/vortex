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

#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <vector>

namespace vortex {

class Core;

// Functional model of the GEMM accelerator. It supports the current
// descriptor-MMIO ABI used by fpint_gemm_ffn_hw, and keeps the older raw stream
// opcode path for compatibility with earlier experiments.
class GemmNode {
public:
  // MMIO layout (XLEN=64 ; see hw/rtl/VX_config.vh GEMM_REG_BASE_ADDR)
  static constexpr uint64_t BASE_ADDR   = 0x1080ULL;
  static constexpr uint64_t WINDOW_SIZE = 4096ULL;
  static constexpr uint64_t OFF_ALLOC   = 0;   // read => allocate entry
  static constexpr uint64_t OFF_STREAM  = 8;   // write => push 64-bit instr word
  static constexpr uint64_t OFF_STATE   = 16;  // read => {gen, occupied}

  // Raw opcodes (kernel side common.h)
  static constexpr uint8_t OP_DMA_LOAD         = 1;
  static constexpr uint8_t OP_DMA_STORE        = 2;
  static constexpr uint8_t OP_NOTIFY           = 3;
  static constexpr uint8_t OP_WAIT             = 4;
  static constexpr uint8_t OP_MXU_LOAD_WEIGHT  = 5;
  static constexpr uint8_t OP_MXU_LOAD_QPARAM  = 6;
  static constexpr uint8_t OP_MXU_LOAD_INPUT   = 7;
  static constexpr uint8_t OP_MXU_STORE_OUTPUT = 8;
  static constexpr uint8_t OP_CLEAR            = 9;

  // Fixed tile geometry (MXU is 32x32 in this branch)
  static constexpr uint32_t MXU_KT      = 32;   // K dimension per compute
  static constexpr uint32_t MXU_NT      = 32;   // N columns
  static constexpr uint32_t SCALE_BYTES = 2;    // FP16
  static constexpr uint32_t ZP_BYTES    = 2;    // INT16

  // TMEM: 8 banks x 32KB = 256KB (flat in our model)
  static constexpr uint64_t TMEM_SIZE = 256ULL * 1024ULL;

  // Accumulator memory (simx flat float array).
  // RTL: 4 banks x 1024 depth x 128 bytes(32*FP32) = 512KB of storage.
  // We model it as a flat FP32 array, indexed by byte addr / 4.
  static constexpr uint32_t ACC_MEM_FP32_COUNT = 131072;  // 512KB / 4B

  GemmNode(Core* core);

  void reset();

  bool busy() const;

  // MMIO access. addr is the byte address; size is the access size in bytes.
  // Returns the read data zero-extended in a 64-bit value (only low `size*8` bits valid).
  uint64_t mmio_read(uint64_t addr, uint32_t size);

  void mmio_write(uint64_t addr, const void* data, uint32_t size);

  // Called each core tick to clear occupied_ when completion_cycle_ is reached.
  void tick();

private:
  void push_stream_word(uint64_t w);
  int  opcode_word_count(uint8_t op) const;
  void dispatch();

  // opcode handlers — consume cmd_buf_ (not cleared by handlers)
  void handle_dma_load(const uint64_t* w);
  void handle_dma_store(const uint64_t* w);
  void handle_mxu_load_weight(const uint64_t* w);
  void handle_mxu_load_qparam(const uint64_t* w);
  void handle_mxu_load_input(const uint64_t* w);
  void handle_mxu_store_output(const uint64_t* w);
  void handle_clear();

  // INT4 weight unpack: returns signed 4-bit as int32.
  static int32_t unpack_int4(const uint8_t* bytes, uint32_t byte_idx, uint32_t nibble_hi);

  // Descriptor-MMIO functional path.
  static constexpr uint32_t DESC_NUM_ENTRIES     = 1;
  static constexpr uint32_t DESC_NUM_REGS32      = 43;
  static constexpr uint32_t DESC_BEAT_BYTES      = 8;
  static constexpr uint32_t DESC_WORDS_PER_BEAT  = DESC_BEAT_BYTES / 4;
  static constexpr uint32_t DESC_NUM_BEATS       = (DESC_NUM_REGS32 + DESC_WORDS_PER_BEAT - 1) / DESC_WORDS_PER_BEAT;
  static constexpr uint32_t DESC_ENTRY_STRIDE    = DESC_NUM_BEATS * DESC_BEAT_BYTES;
  static constexpr uint32_t DESC_WINDOW_BASE     = DESC_BEAT_BYTES;

  enum class MmioMode {
    Unknown,
    Descriptor,
    RawStream
  };

  enum DescReg : uint32_t {
    REG_CONTROL        = 0,
    REG_INPUT_BASE_LO  = 1,
    REG_WEIGHT_BASE_LO = 3,
    REG_OUTPUT_BASE_LO = 5,
    REG_SCALE_BASE_LO  = 7,
    REG_ZP_BASE_LO     = 9,
    REG_M_ORIG         = 29,
    REG_N_ORIG         = 30,
    REG_K_ORIG         = 31,
    REG_QBLK_ORIG      = 32,
    REG_M_TARGET       = 33,
    REG_N_TARGET       = 34,
    REG_K_TARGET       = 35,
    REG_M_START        = 36,
    REG_N_START        = 37,
    REG_WTRANS         = 38,
    REG_QDIR           = 39,
    REG_LOG2_DMA_MT    = 40,
    REG_LOG2_DMA_KT    = 41,
    REG_LOG2_DMA_NT    = 42
  };

  struct JobEntry {
    std::array<uint32_t, DESC_NUM_REGS32> regs = {};
    bool occupied = false;
    bool working = false;
    uint32_t generation = 0;
  };

  uint32_t pack_alloc_response(bool success, uint32_t eid, uint32_t generation) const;
  uint32_t descriptor_control_value(uint32_t eid) const;
  bool decode_descriptor_offset(uint64_t off, uint32_t* eid, uint32_t* reg_idx, uint32_t* byte_lane) const;
  bool descriptor_read(uint64_t off, uint32_t size, uint64_t* value) const;
  bool descriptor_write(uint64_t off, const void* data, uint32_t size);
  void execute_descriptor_job(uint32_t eid);

  uint64_t reg_u64(const JobEntry& entry, uint32_t lo_reg) const;
  uint16_t read_u16(uint64_t addr) const;
  int16_t read_i16(uint64_t addr) const;
  void write_u16(uint64_t addr, uint16_t value) const;
  float fp16_to_float(uint16_t value) const;
  uint16_t float_to_fp16(float value) const;

  uint64_t input_offset(uint32_t M, uint32_t K, uint32_t dma_mt, uint32_t dma_kt, uint32_t gm, uint32_t gk) const;
  uint64_t weight_offset(uint32_t N, uint32_t K, uint32_t dma_kt, uint32_t gn, uint32_t gk, bool wtrans, uint32_t* nibble_hi) const;
  uint64_t scale_offset(uint32_t N, uint32_t K, uint32_t dma_kt, uint32_t dma_nt, uint32_t qblk, uint32_t qdir, uint32_t gn, uint32_t gk) const;
  uint64_t output_offset(uint32_t M, uint32_t N, uint32_t dma_mt, uint32_t gm, uint32_t gn) const;

  Core* core_;

  // Entry state (single entry — current kernel uses 1)
  bool     occupied_;
  uint32_t generation_;
  uint64_t completion_cycle_;
  uint64_t cycle_counter_;

  // Instruction stream assembly buffer
  std::vector<uint64_t> cmd_buf_;
  int expected_words_;

  MmioMode mmio_mode_;
  std::array<JobEntry, DESC_NUM_ENTRIES> desc_entries_;

  // TMEM flat byte array
  std::vector<uint8_t> tmem_;

  // MXU internal state — dual-buffered
  struct MxuRegs {
    // INT4 packed weights (MXU_KT * MXU_NT / 2 = 512 bytes per bank is the minimum;
    // kernel can load multiple K-blocks but always writes sequentially → keep large buffer).
    std::vector<uint8_t> weight_reg[2];
    // Scale registers — MXU_NT FP16 each, per MXU_LOAD_QPARAM bank
    std::vector<uint8_t> scale_reg[2];
    // Zero-point registers — MXU_NT INT16 each
    std::vector<uint8_t> zp_reg[2];
    // Transpose flag captured at weight load
    bool wtrans[2] = {false, false};
  };
  MxuRegs mxu_;

  // Accumulator memory (FP32 flat)
  std::vector<float> acc_mem_;
};

} // namespace vortex
