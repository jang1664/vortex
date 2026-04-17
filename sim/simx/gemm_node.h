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

#include <cstdint>
#include <memory>
#include <vector>

namespace vortex {

class Core;

// Functional model of the fpint_improve VX_gemm_node instruction-stream accelerator.
// Intercepts MMIO writes to the GEMM stream FIFO and executes opcodes sequentially.
// See docs/simx/ and agent-tasks/simx-gemm-node/STATUS.yaml for the design.
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

  bool busy() const { return occupied_; }

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

  Core* core_;

  // Entry state (single entry — current kernel uses 1)
  bool     occupied_;
  uint32_t generation_;
  uint64_t completion_cycle_;
  uint64_t cycle_counter_;

  // Instruction stream assembly buffer
  std::vector<uint64_t> cmd_buf_;
  int expected_words_;

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
