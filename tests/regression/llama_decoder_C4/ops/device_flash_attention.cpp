#include "../flash_args.h"
#include <VX_config.h>

#ifdef GEMM_SRAM_FUSION
// Reuse the same attention implementation and ABI as the standalone test.
#define main llama_flash_attention_main
#include "../../flash_attn/kernel.cpp"
#undef main

static void prepare_attention_inputs() {
  auto* record=reinterpret_cast<DecoderFlashArgs*>(csr_read(VX_CSR_MSCRATCH));
  const auto& a=record->attention;
  const uint32_t lane=vx_thread_id();
  if (record->key_source) {
    const auto* src=reinterpret_cast<const uint64_t*>(record->key_source);
    auto* dst=reinterpret_cast<uint64_t*>(a.k_weight_base);
    for (uint64_t i=lane;i<record->key_padded_bytes/8;i+=NUM_THREADS)
      dst[i]=i<record->key_source_bytes/8?src[i]:0;
  }
  if (record->value_source_rows) {
    const uint32_t rows=record->value_source_rows;
    const uint32_t block_bytes=128*(MXU_COL/2), source_bytes=rows*(MXU_COL/2);
    const auto* src=reinterpret_cast<const uint8_t*>(record->value_source);
    auto* dst=reinterpret_cast<uint8_t*>(a.v_weight_base);
    for (uint32_t i=lane;i<8192;i+=NUM_THREADS) {
      const uint32_t block=i/block_bytes, offset=i%block_bytes;
      dst[i]=offset<source_bytes?src[block*source_bytes+offset]:0;
    }
    const auto* sc=reinterpret_cast<const uint16_t*>(record->value_scale_source);
    const auto* zp=reinterpret_cast<const uint16_t*>(record->value_zero_source);
    auto* out_sc=reinterpret_cast<uint16_t*>(a.v_scale_base);
    auto* out_zp=reinterpret_cast<uint16_t*>(a.v_zero_base);
    for (uint32_t i=lane;i<a.v_scale_tile_bytes/2;i+=NUM_THREADS) {
      const uint32_t block=i/128, row=i%128;
      const bool valid=block<128/MXU_COL && row<rows;
      out_sc[i]=valid?sc[block*rows+row]:0;
      out_zp[i]=valid?zp[block*rows+row]:0;
    }
  }
  vx_fence();
}

int llama_flash_attention_batch_main(uint32_t count) {
  if (vx_core_id()!=0 || vx_warp_id()!=0 || vx_thread_id()!=0) return 0;
  const auto saved=csr_read(VX_CSR_MSCRATCH);
  auto* args=reinterpret_cast<DecoderFlashArgs*>(saved);
  for (uint32_t i=0;i<count;++i) {
    csr_write(VX_CSR_MSCRATCH,reinterpret_cast<uintptr_t>(args+i));
    const uint64_t prepare_begin=attention_cycles();
    vx_tmc(-1);
    prepare_attention_inputs();
    vx_tmc_one();
    args[i].input_prepare_cycles=attention_cycles()-prepare_begin;
    csr_write(VX_CSR_MSCRATCH,reinterpret_cast<uintptr_t>(&args[i].attention));
    llama_flash_attention_main();
    if (args[i].attention.status!=FLASH_STATUS_OK) {
      csr_write(VX_CSR_MSCRATCH,saved);
      return -1;
    }
  }
  csr_write(VX_CSR_MSCRATCH,saved);
  return 0;
}
#else
int llama_flash_attention_batch_main(uint32_t) { return -1; }
#endif
