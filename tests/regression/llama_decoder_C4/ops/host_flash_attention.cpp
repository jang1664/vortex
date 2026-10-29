#include "../decoder.h"
#include "../op_args.h"
#include "../../fpint_gemm_ffn_hw/layout.h"
#include <algorithm>
#include <cmath>
#include <cstring>

void Decoder::build_resident_attention(uint32_t B, uint32_t S, uint32_t Q,
    uint32_t V, uint32_t D, uint32_t G, uint32_t C, uint32_t L) {
  if (D != 128) throw std::invalid_argument("resident attention requires head dimension 128");
  const uint32_t rows = G*S, heads = Q/G, padded_rows = (rows+7u)&~7u;
  const uint64_t tiles = (L+127u)/128u;
  auto align = [](uint64_t n) { return (n+31u)&~uint64_t(31u); };
  auto scratch = [&](const std::string& name, uint64_t bytes) {
    if (!buffers_.count(name)) alloc(name,bytes,"packed_attention_input");
    return addr(name);
  };
  DecoderGemmArgs layout{};
  // QROW PV has the larger qparam slots; use its reservation for both jobs.
  if (!fpint_gemm_layout::allocate_tmem_buffers(layout,tmem,128,128,128,MXU_COL,128,1))
    throw std::runtime_error("resident attention TMEM overflow");
  // The helper reserves two consecutive FP16 output slots after all inputs.
  // Resident scheduling uses one output at a time, so FP32 owns their union.
  const uint64_t fp16_output_bytes=uint64_t(128)*128*sizeof(uint16_t);
  if (attention_fp32_ && (layout.lmem_obuf[1]!=layout.lmem_obuf[0]+fp16_output_bytes
      || layout.lmem_obuf[1]+fp16_output_bytes>tmem))
    throw std::runtime_error("resident FP32 output requires two contiguous TMEM slots");
  Operation batch;
  batch.name="attention"; batch.kind=DecoderOp::flash_attention; batch.gemm_count=0;
  batch.inputs={"q_hadamard"}; batch.outputs={"context"};
  for (uint32_t b=0;b<B;++b) for (uint32_t h=0;h<Q;h+=G) {
    const auto suffix=std::to_string(b)+"."+std::to_string(h/(Q/V));
    const auto key="key."+suffix, value="value."+suffix;
    for (const auto& name : {key+".weight",key+".scale",key+".zero",
                            value+".weight",value+".scale",value+".zero"})
      if (std::find(batch.inputs.begin(),batch.inputs.end(),name)==batch.inputs.end())
        batch.inputs.push_back(name);
    for (uint32_t row=0;row<rows;row+=128) {
      DecoderFlashArgs record{};
      auto& a=record.attention;
      a.query_rows=std::min(128u,rows-row); a.query_rows_pad=(a.query_rows+7u)&~7u;
      const uint64_t offset=(uint64_t(b*heads+h/G)*padded_rows+row)*D*2;
      a.q_base=addr("q_hadamard")+offset; a.output_base=addr("context")+offset;
      a.k_weight_base=addr(key+".weight"); a.k_scale_base=addr(key+".scale"); a.k_zero_base=addr(key+".zero");
      a.v_weight_base=addr(value+".weight"); a.v_scale_base=addr(value+".scale"); a.v_zero_base=addr(value+".zero");
      a.k_weight_tile_bytes=a.v_weight_tile_bytes=8192;
      a.k_scale_tile_bytes=a.k_zero_tile_bytes=scale_slot_bytes_host(128,128,128,0);
      a.v_scale_tile_bytes=a.v_zero_tile_bytes=scale_slot_bytes_host(128,128,128,1);
      const uint64_t key_bytes=weight_total_bytes_host(C,D,1);
      if (key_bytes<tiles*8192) {
        record.key_source=a.k_weight_base; record.key_source_bytes=key_bytes;
        record.key_padded_bytes=tiles*8192;
        a.k_weight_base=scratch("attention.key_pad."+suffix,record.key_padded_bytes);
      }
      const uint32_t value_rows=padded_weight_K_host(C,D,0);
      if (value_rows<128) {
        record.value_source=a.v_weight_base;
        record.value_scale_source=a.v_scale_base; record.value_zero_source=a.v_zero_base;
        record.value_source_rows=value_rows;
        a.v_weight_base=scratch("attention.value_pad."+suffix,8192);
        a.v_scale_base=scratch("attention.value_scale_pad."+suffix,a.v_scale_tile_bytes);
        a.v_zero_base=scratch("attention.value_zero_pad."+suffix,a.v_zero_tile_bytes);
      }
      for (unsigned i=0;i<2;++i) {
        a.lmem_ibuf[i]=layout.lmem_ibuf[i]; a.lmem_wbuf[i]=layout.lmem_wbuf[i];
        a.lmem_scbuf[i]=layout.lmem_scbuf[i]; a.lmem_zpbuf[i]=layout.lmem_zpbuf[i];
      }
      a.lmem_obuf=layout.lmem_obuf[0];
      a.output_fp32=attention_fp32_;
      uint64_t cursor=uint64_t(LMEM_BASE_ADDR);
      const uint64_t probability_bytes=uint64_t(a.query_rows_pad)*128*2;
      a.score_base=a.partial_base=cursor;
      cursor+=align(probability_bytes*(a.output_fp32?2:1));
      a.probability_base=a.score_base;
      if (a.output_fp32) {
        a.probability_base=cursor;
        cursor+=align(probability_bytes);
      }
      a.accumulator_base=cursor; cursor+=align(uint64_t(a.query_rows)*D*4);
      a.row_max_base=cursor; cursor+=align(a.query_rows*4);
      a.row_sum_base=cursor; cursor+=align(a.query_rows*4);
      a.row_alpha_base=cursor; cursor+=align(a.query_rows*4);
      if (cursor-uint64_t(LMEM_BASE_ADDR)>uint64_t(LMEM_SIZE)/2)
        throw std::runtime_error("resident attention exceeds reserved LMEM arena");
      a.kv_length=L; a.kv_tile=128; a.head_dim=D;
      a.qk_qblk=a.pv_qblk=128; a.qk_wtrans=1; a.pv_qdir=1;
      a.causal=!cfg_.decode(); a.query_position_base=row;
      a.resident=1; a.output_tiled=1; a.attention_scale=1.0f/std::sqrt(float(D));
      const auto begin=batch.arguments.size();
      batch.arguments.resize(begin+sizeof(record));
      std::memcpy(batch.arguments.data()+begin,&record,sizeof(record));
      ++batch.gemm_count;
      if (!batch_attention_) {
        batch.name="attention."+std::to_string(b)+"."+std::to_string(h)+"."+std::to_string(row);
        append(batch); batch.arguments.clear(); batch.gemm_count=0;
      }
    }
  }
  if (batch_attention_) append(std::move(batch));
}
