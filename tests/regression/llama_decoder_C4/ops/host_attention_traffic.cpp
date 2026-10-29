#include "../decoder.h"
#include "../op_args.h"
#include "../../layout_fused_common/layout_fused_layouts.h"
#include "../../../../runtime/common/nlohmann_json.hpp"
#include <algorithm>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>

namespace fs = std::filesystem;
namespace {
using Json = nlohmann::json;
std::string hex_address(uint64_t value) {
  std::ostringstream text; text << "0x" << std::hex << value; return text.str();
}
void write_json(const fs::path& path, const Json& value) {
  if (!path.parent_path().empty()) fs::create_directories(path.parent_path());
  std::ofstream file(path); file << value.dump(2) << '\n';
  if (!file) throw std::runtime_error("could not write " + path.string());
}
Json record_json(const DecoderFlashArgs& record, uint32_t index, uint32_t group, uint32_t chunks, uint32_t heads_per_kv) {
  const auto& a = record.attention;
  Json fields;
#define ADDRESS(field) fields[#field] = hex_address(a.field)
  ADDRESS(q_base); ADDRESS(k_weight_base); ADDRESS(k_scale_base); ADDRESS(k_zero_base);
  ADDRESS(v_weight_base); ADDRESS(v_scale_base); ADDRESS(v_zero_base);
  ADDRESS(score_base); ADDRESS(probability_base); ADDRESS(partial_base);
  ADDRESS(accumulator_base); ADDRESS(row_max_base); ADDRESS(row_sum_base); ADDRESS(row_alpha_base);
  ADDRESS(output_base); ADDRESS(debug_score_base); ADDRESS(debug_probability_base);
  ADDRESS(debug_partial_base); ADDRESS(debug_accumulator_base); ADDRESS(debug_row_max_base); ADDRESS(debug_row_sum_base);
  ADDRESS(lmem_obuf);
#undef ADDRESS
#define VALUE(field) fields[#field] = a.field
  VALUE(k_weight_tile_bytes); VALUE(k_scale_tile_bytes); VALUE(k_zero_tile_bytes);
  VALUE(v_weight_tile_bytes); VALUE(v_scale_tile_bytes); VALUE(v_zero_tile_bytes);
  VALUE(query_rows); VALUE(query_rows_pad); VALUE(kv_length); VALUE(kv_tile); VALUE(head_dim);
  VALUE(qk_qblk); VALUE(qk_wtrans); VALUE(qk_qdir); VALUE(pv_qblk); VALUE(pv_wtrans); VALUE(pv_qdir);
  VALUE(causal); VALUE(pv_only); VALUE(resident); VALUE(debug_export); VALUE(debug_stage);
  VALUE(output_tiled); VALUE(query_position_base); VALUE(attention_scale);
  VALUE(status); VALUE(qk_progress_events); VALUE(pv_progress_events); VALUE(later_max_updates);
  VALUE(qk_eid); VALUE(qk_generation); VALUE(current_kv_tile); VALUE(completed_kv_tiles); VALUE(dma_sequence);
  VALUE(sram_copy_bytes); VALUE(total_cycles); VALUE(gemm_submit_cycles); VALUE(gemm_wait_cycles);
  VALUE(sram_copy_cycles); VALUE(simd_cycles); VALUE(output_fp32);
#undef VALUE
  for (unsigned i=0; i<2; ++i) {
    fields["lmem_ibuf"].push_back(hex_address(a.lmem_ibuf[i]));
    fields["lmem_wbuf"].push_back(hex_address(a.lmem_wbuf[i]));
    fields["lmem_scbuf"].push_back(hex_address(a.lmem_scbuf[i]));
    fields["lmem_zpbuf"].push_back(hex_address(a.lmem_zpbuf[i]));
  }
  const uint32_t query_head=(index/chunks)*group;
  return {{"index", index}, {"batch", 0}, {"query_head_start", query_head},
    {"kv_head", query_head/heads_per_kv}, {"row_start", (index%chunks)*128}, {"attention", fields},
    {"key_source", hex_address(record.key_source)}, {"key_source_bytes", record.key_source_bytes},
    {"key_padded_bytes", record.key_padded_bytes}, {"value_source", hex_address(record.value_source)},
    {"value_scale_source", hex_address(record.value_scale_source)},
    {"value_zero_source", hex_address(record.value_zero_source)},
    {"value_source_rows", record.value_source_rows}, {"reserved", record.reserved}};
}
}

Sample Decoder::attention_traffic(const fs::path& fixture, const fs::path& snapshot,
    const fs::path& manifest_path, const fs::path& output) {
  if (!ops_.empty() || !buffers_.empty() || !resident_attention_ || !batch_attention_)
    throw std::invalid_argument("attention replay requires a fresh batched resident decoder");
  const bool device_snapshot=cfg_.decode() && cfg_.seq==1 && cfg_.past_kv==16 && cfg_.cache_capacity==32;
  const bool prefill=cfg_.stage=="prefill" && cfg_.seq==144 && cfg_.past_kv==0 && cfg_.cache_capacity==0;
  const bool cpu_fixture=prefill || (cfg_.decode() && cfg_.seq==1 && cfg_.past_kv==128
      && (cfg_.cache_capacity==160 || cfg_.cache_capacity==256));
  if (cfg_.model!="llama3-8b" || cfg_.batch!=1
      || (!device_snapshot && !cpu_fixture) || cfg_.q_heads!=32
      || cfg_.kv_heads!=8 || cfg_.head_dim!=128)
    throw std::invalid_argument("attention-traffic requires full Llama3 decode B1/S1 with P16/C32, P128/C160 or P128/C256, or prefill B1/S144/P0/C144");
  if (PLATFORM_MEMORY_NUM_BANKS!=32 || NUM_HBM_PORTS!=4 || MEM_BLOCK_SIZE!=64
      || MEM_ADDR_WIDTH!=34 || cores!=1 || warps!=4 || threads!=16)
    throw std::invalid_argument("attention-traffic requires the rev8 C4 memory geometry");
  const auto snapshot_path=fs::canonical(snapshot);
  for (const auto& path : {fs::weakly_canonical(output),fs::weakly_canonical(manifest_path)})
    if (std::mismatch(snapshot_path.begin(),snapshot_path.end(),path.begin(),path.end()).first==snapshot_path.end())
      throw std::invalid_argument("replay output/manifest must be outside the immutable snapshot");

  // Decoder::load has no separate metadata-only helper. Keep its metadata
  // checks here without loading the fixture's unused projection weights.
  std::ifstream meta(fixture/"config.txt");
  if (!meta) throw std::runtime_error("missing fixture config.txt");
  std::map<std::string,std::string> metadata; std::string key,value;
  while (meta>>key>>value) metadata[key]=value;
  for (auto kv : std::map<std::string,uint32_t>{{"batch",cfg_.batch},{"seq",cfg_.seq},
      {"hidden",cfg_.hidden},{"ffn",cfg_.ffn},{"q_heads",cfg_.q_heads},
      {"kv_heads",cfg_.kv_heads},{"head_dim",cfg_.head_dim}})
    if (metadata.at(kv.first)!=std::to_string(kv.second))
      throw std::runtime_error("fixture mismatch: "+kv.first);
  const uint32_t effective_capacity=cfg_.decode()?cfg_.cache_capacity:cfg_.seq;
  // Historical prefill fixtures omit these fields; reject conflicting explicit values.
  if (prefill) {
    metadata.emplace("stage","prefill");
    metadata.emplace("past_kv","0");
    metadata.emplace("cache_capacity",std::to_string(effective_capacity));
  }
  if (metadata.at("model")!=cfg_.model || metadata.at("stage")!=cfg_.stage
      || metadata.at("past_kv")!=std::to_string(cfg_.past_kv)
      || metadata.at("cache_capacity")!=std::to_string(effective_capacity))
    throw std::runtime_error("fixture model/decode metadata mismatch");
  const Json model={{"name",cfg_.model},{"batch",cfg_.batch},{"seq",cfg_.seq},
    {"stage",cfg_.stage},{"past_kv",cfg_.past_kv},{"capacity",effective_capacity},
    {"q_heads",cfg_.q_heads},{"kv_heads",cfg_.kv_heads},{"head_dim",cfg_.head_dim}};
  const auto provenance_path=snapshot/"provenance.json";
  if (cpu_fixture) {
    std::ifstream file(provenance_path);
    if (!file) throw std::runtime_error("CPU replay requires explicit CPU fixture input provenance");
    Json provenance; file>>provenance;
    if (provenance.at("schema")!="c4_attention_input_provenance_v1"
        || provenance.at("kind")!="cpu-fixture-input" || provenance.at("model")!=model
        || provenance.at("full_decoder_pass")!=false
        || fs::canonical(provenance.at("snapshot").get<std::string>())!=snapshot_path
        || fs::canonical(provenance.at("fixture").get<std::string>())!=fs::canonical(fixture)
        || fs::canonical(provenance.at("source_npz").at("path").get<std::string>())!=fs::canonical(fixture/"reference.npz")
        || provenance.at("updated_cache_keys")!=Json::array({"cache_0","cache_1","cache_2","cache_3","cache_4","cache_5"}))
      throw std::runtime_error("invalid CPU fixture attention input provenance");
    if (prefill && (provenance.value("cache_source_stage",std::string())!="prefill"
        || provenance.contains("initial_cache_npz")
        || !provenance.at("checks").value("prefill_cache_outputs",false)))
      throw std::runtime_error("invalid prefill cache source provenance");
  } else if (fs::exists(provenance_path)) {
    throw std::runtime_error("P16/C32 replay expects the archived device snapshot, not CPU input provenance");
  }

  std::ifstream catalog(snapshot/"buffers.tsv");
  if (!catalog) throw std::runtime_error("missing attention snapshot buffers.tsv");
  std::map<std::string,Buffer> descriptions;
  std::string line;
  while (std::getline(catalog,line)) {
    std::istringstream row(line); Buffer b; std::string extra;
    if (!(row>>b.name>>b.layout>>b.matrices>>b.rows>>b.cols>>b.bytes)
        || (row>>extra) || !descriptions.emplace(b.name,b).second)
      throw std::runtime_error("invalid/duplicate snapshot catalog record");
  }
  const uint32_t B=cfg_.batch, S=cfg_.seq, Q=cfg_.q_heads, V=cfg_.kv_heads;
  const uint32_t D=cfg_.head_dim, G=cfg_.attention_group_size(), C=effective_capacity;
  const uint32_t matrices=B*(Q/G), rows=G*S, padded_rows=(rows+7u)&~7u;
  const uint64_t context_bytes=uint64_t(matrices)*padded_rows*D*sizeof(uint16_t);
  std::map<std::string,std::string> roles;
  Json input_sources=Json::array();
  auto load_input = [&](const std::string& name, uint64_t bytes, const std::string& layout,
      uint32_t count, uint32_t m, uint32_t n, const std::string& role) {
    const auto& description=descriptions.at(name);
    if (description.bytes!=bytes || description.layout!=layout || description.matrices!=count
        || description.rows!=m || description.cols!=n)
      throw std::runtime_error("attention snapshot shape mismatch: "+name);
    const auto path=fs::canonical(snapshot/(name+".bin"));
    if (fs::file_size(path)!=bytes) throw std::runtime_error("attention snapshot byte mismatch: "+name);
    std::vector<uint8_t> data(bytes);
    std::ifstream file(path,std::ios::binary);
    file.read(reinterpret_cast<char*>(data.data()),data.size());
    if (!file) throw std::runtime_error("short attention snapshot read: "+name);
    auto& buffer=alloc(name,bytes,layout,count,m,n);
    rt_check(vx_copy_to_dev(buffer.handle,data.data(),0,bytes),"upload attention snapshot");
    roles[name]=role;
    input_sources.push_back({{"name",name},{"bytes",bytes},{"path",path.string()}});
  };
  load_input("q_hadamard",context_bytes,"a",matrices,rows,D,"q");
  for (uint32_t head=0; head<V; ++head) for (uint32_t is_key=0; is_key<2; ++is_key) {
    const std::string stem=(is_key?"key.0.":"value.0.")+std::to_string(head);
    const std::string role=is_key?"k_":"v_";
    const uint64_t weight_bytes=weight_total_bytes_host(C,D,is_key);
    const uint64_t qparam_bytes=scale_total_bytes_host(C,D,D,is_key?0:1,is_key,128,128);
    load_input(stem+".weight",weight_bytes,"fixture",1,1,1,role+"weight");
    load_input(stem+".scale",qparam_bytes,"fixture",1,1,1,role+"scale");
    load_input(stem+".zero",qparam_bytes,"fixture",1,1,1,role+"zero");
  }
  alloc("context",context_bytes,"c",matrices,rows,D); roles["context"]="context";
  build_resident_attention(B,S,Q,V,D,G,C,cfg_.past_kv+S);
  const uint32_t chunks=(rows+127)/128, expected_records=matrices*chunks;
  if (ops_.size()!=1 || ops_[0].kind!=DecoderOp::flash_attention
      || ops_[0].gemm_count!=expected_records
      || ops_[0].arguments.size()!=uint64_t(expected_records)*sizeof(DecoderFlashArgs))
    throw std::runtime_error("attention replay did not build the complete original batch");
  auto& operation=ops_[0];
  std::vector<DecoderFlashArgs> records(operation.gemm_count);
  std::memcpy(records.data(),operation.arguments.data(),operation.arguments.size());
  uint64_t args_base=0, dispatch_base=0, kernel_base=0;
  rt_check(vx_mem_address(operation.args_buffer,&args_base),"attention args address");
  rt_check(vx_mem_address(operation.dispatch_buffer,&dispatch_base),"attention dispatch address");
  rt_check(vx_mem_address(kernel_,&kernel_base),"attention kernel address");
  Json manifest={{"schema","c4_decoder_attention_traffic_v1"},
    {"model",model},
    {"backend",attention_fp32_?"resident-fp32":"resident"},
    {"snapshot",{{"path",fs::canonical(snapshot).string()},{"inputs",input_sources}}},
    {"fixture",fs::canonical(fixture).string()},
    {"geometry",{{"banks",PLATFORM_MEMORY_NUM_BANKS},{"ports",NUM_HBM_PORTS},
      {"beat_bytes",MEM_BLOCK_SIZE},{"address_bits",MEM_ADDR_WIDTH},
      {"cores",cores},{"warps",warps},{"threads",threads}}},
    {"dispatch",{{"base",hex_address(dispatch_base)},{"bytes",sizeof(DecoderDispatch)},
      {"operation",uint32_t(operation.kind)},{"args_base",hex_address(args_base)},{"count",operation.gemm_count}}},
    {"arguments",{{"base",hex_address(args_base)},{"bytes",operation.arguments.size()},{"record_bytes",sizeof(DecoderFlashArgs)}}},
    {"runtime",{{"kernel_base",hex_address(kernel_base)},{"kernel_reservation_source","MEM_RESERVE app-log"},
      {"stack_base",hex_address(STACK_BASE_ADDR)},{"stack_log2_size",STACK_LOG2_SIZE},
      {"lmem_base",hex_address(LMEM_BASE_ADDR)},{"lmem_bytes",LMEM_SIZE},{"tmem_bytes",tmem}}},
    {"context_padding_canary",0},{"buffers",Json::array()},{"records",Json::array()}};
  for (const auto& [name,b] : buffers_) {
    if (!roles.count(name)) {
      for (auto prefix : {std::pair<const char*,const char*>{"attention.key_pad.","pad_k_weight"},
          {"attention.value_pad.","pad_v_weight"},{"attention.value_scale_pad.","pad_v_scale"},
          {"attention.value_zero_pad.","pad_v_zero"}})
        if (name.compare(0,std::strlen(prefix.first),prefix.first)==0) roles[name]=prefix.second;
      if (!roles.count(name)) throw std::runtime_error("unexpected attention allocation: "+name);
    }
    manifest["buffers"].push_back({{"name",name},{"base",hex_address(b.address)},{"bytes",b.bytes},
      {"role",roles.at(name)},{"layout",b.layout},{"matrices",b.matrices},{"rows",b.rows},{"cols",b.cols}});
  }
  for (uint32_t i=0; i<records.size(); ++i) {
    if (records[i].attention.debug_export || records[i].attention.debug_stage)
      throw std::runtime_error("attention replay must not enable intermediate exports");
    manifest["records"].push_back(record_json(records[i],i,G,chunks,Q/V));
  }
  manifest["snapshot"]["kind"]=cpu_fixture?"cpu-fixture-input":"device-snapshot";
  if (cpu_fixture) manifest["snapshot"]["provenance"]=fs::canonical(provenance_path).string();
  write_json(manifest_path,manifest);
  fs::create_directories(output);
  std::ofstream output_catalog(output/"buffers.tsv");
  for (const auto& [name,b] : buffers_)
    output_catalog<<name<<'\t'<<b.layout<<'\t'<<b.matrices<<'\t'<<b.rows<<'\t'<<b.cols<<'\t'<<b.bytes<<'\n';
  if (!output_catalog) throw std::runtime_error("could not save replay catalog");
  output_catalog.close();
  std::cout<<"DECODER_ATTENTION_REPLAY records="<<records.size()<<" diagnostics=0"<<std::endl;
  const auto sample=launch(operation,true);
  rt_check(vx_copy_from_dev(records.data(),operation.args_buffer,0,operation.arguments.size()),"attention completion records");
  Json completion={{"schema","c4_decoder_attention_completion_v1"},{"full_decoder_pass",false},
    {"records",Json::array()},{"cycles",sample.cycles},{"host_seconds",sample.seconds}};
  for (uint32_t i=0; i<records.size(); ++i) {
    completion["records"].push_back(record_json(records[i],i,G,chunks,Q/V));
    const auto& a=records[i].attention;
    std::cout<<"DECODER_ATTENTION_RECORD index="<<i<<" status="<<a.status
      <<" completed_kv_tiles="<<a.completed_kv_tiles<<" sram_copy_bytes="<<a.sram_copy_bytes
      <<" dma_sequence="<<a.dma_sequence<<std::endl;
  }
  dump_buffer("context",output);
  std::vector<uint16_t> context(context_bytes/sizeof(uint16_t));
  std::ifstream context_file(output/"context.bin",std::ios::binary);
  context_file.read(reinterpret_cast<char*>(context.data()),context_bytes);
  if (!context_file) throw std::runtime_error("could not read replay context dump");
  uint32_t log2_mxu=0; while ((1u<<log2_mxu)!=MXU_COL) ++log2_mxu;
  for (uint32_t matrix=0; matrix<matrices; ++matrix)
    for (uint32_t row=rows; row<padded_rows; ++row) for (uint32_t col=0; col<D; ++col) {
      const uint64_t index=uint64_t(matrix)*padded_rows*D
        + gemm_c_tiled_elem_offset(row,col,padded_rows,D,7,log2_mxu);
      if (context[index]!=0) throw std::runtime_error("attention context padding canary changed");
    }
  completion["context_padding_preserved"]=true;
  write_json(output/"completion.json",completion);
  std::cout<<"ATTENTION_TRAFFIC_REPLAY PASSED full_decoder_pass=0 context_comparison=external"<<std::endl;
  return sample;
}
