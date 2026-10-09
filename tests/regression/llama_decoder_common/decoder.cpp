#include "decoder.h"
#include "op_args.h"
#include "../kv_cache_quant_w4a16/host_variant.h"
#include "../kv_cache_dequant_w4a16/host_variant.h"
#if DECODER_CANDIDATE != 1
#include "naive_layout.h"
#endif
#include <tensor_cfg.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>

namespace fs = std::filesystem;
namespace {
uint32_t lg(uint32_t n) {
  if (!n || (n & (n-1))) throw std::invalid_argument("expected power of two");
  uint32_t v=0; while ((1u<<v)!=n) ++v; return v;
}
template<class T> void grid(T& arg, uint32_t blocks, uint32_t threads, uint32_t matrices=1) {
  arg.grid_dim[0]=blocks; arg.grid_dim[1]=matrices; arg.grid_dim[2]=1;
  arg.block_dim[0]=threads; arg.block_dim[1]=arg.block_dim[2]=1;
}
template<class T> Operation op(const std::string& name, DecoderOp kind, const T& arg,
    std::vector<std::string> inputs, std::vector<std::string> outputs) {
  Operation result;
  result.name=name; result.kind=kind;
  result.arguments.resize(sizeof(arg));
  std::memcpy(result.arguments.data(), &arg, sizeof(arg));
  result.inputs=std::move(inputs); result.outputs=std::move(outputs);
  return result;
}
}
void rt_check(int status, const char* action) {
  if (status) throw std::runtime_error(std::string(action)+": status="+std::to_string(status));
}
Decoder::Decoder(ModelConfig config) : cfg_(std::move(config)) {
  cfg_.validate();
  rt_check(vx_dev_open(&device_), "vx_dev_open");
  try {
    rt_check(vx_dev_caps(device_, VX_CAPS_NUM_CORES, &cores), "cores");
    rt_check(vx_dev_caps(device_, VX_CAPS_NUM_WARPS, &warps), "warps");
    rt_check(vx_dev_caps(device_, VX_CAPS_NUM_THREADS, &threads), "threads");
    if (cores!=NUM_CORES || threads!=NUM_THREADS) throw std::runtime_error("config/device mismatch");
    if (cores!=1) throw std::runtime_error("this decoder's cycle measurement currently requires one core");
    rt_check(vx_dev_caps(device_, VX_CAPS_LOCAL_MEM_SIZE, &local_mem), "local memory");
    rt_check(vx_upload_kernel_file(device_, "kernel.vxbin", &kernel_), "upload decoder kernel");
  } catch (...) { vx_dev_close(device_); device_=nullptr; throw; }
}
Decoder::~Decoder() {
  for (auto& x:ops_) { if(x.dispatch_buffer) vx_mem_free(x.dispatch_buffer); if(x.args_buffer) vx_mem_free(x.args_buffer); }
  for (auto& x:buffers_) if(x.second.handle) vx_mem_free(x.second.handle);
  if(kernel_) vx_mem_free(kernel_);
  if(device_) vx_dev_close(device_);
}
Buffer& Decoder::alloc(const std::string& name, uint64_t bytes, const std::string& layout,
    uint32_t matrices, uint32_t rows, uint32_t cols) {
  if (!bytes || buffers_.count(name)) throw std::runtime_error("invalid/duplicate buffer "+name);
  Buffer b; b.name=name; b.bytes=bytes; b.layout=layout; b.matrices=matrices; b.rows=rows; b.cols=cols;
  // The original TCU kernel rounds M to its hardware tile. Extra output rows
  // never change the logical row pitch; reserve and initialize the tail so
  // those stores and the corresponding A loads remain inside owned memory.
#if DECODER_CANDIDATE != 3
  using TC=vortex::tensor::wmma_config_t<NUM_THREADS,vortex::tensor::fp16,vortex::tensor::fp16>;
  const uint64_t storage_bytes=bytes+uint64_t(TC::tileM-1)*std::max({cfg_.hidden,cfg_.ffn,cfg_.cache_capacity})*2;
#else
  const uint64_t storage_bytes=bytes;
#endif
  rt_check(vx_mem_alloc_aligned(device_, storage_bytes, 512, VX_MEM_READ_WRITE, &b.handle), "allocate tensor");
  buffers_.emplace(name,b);
  auto& result=buffers_.at(name);
  rt_check(vx_mem_address(result.handle,&result.address), "tensor address");
  // Defined padding and deterministic initial data, outside all measurements.
  std::vector<uint8_t> zeros(std::min<uint64_t>(storage_bytes,1<<20),0);
  for(uint64_t off=0;off<storage_bytes;off+=zeros.size())
    rt_check(vx_copy_to_dev(result.handle,zeros.data(),off,std::min<uint64_t>(storage_bytes-off,zeros.size())), "zero tensor");
  return result;
}
uint64_t Decoder::addr(const std::string& name) const { return buffers_.at(name).address; }
void Decoder::load(const fs::path& fixture) {
  std::ifstream meta(fixture/"config.txt");
  if(!meta) throw std::runtime_error("missing fixture config.txt");
  std::map<std::string,std::string> fields; std::string key,value;
  while(meta>>key>>value) fields[key]=value;
  for(auto kv : std::map<std::string,uint32_t>{{"batch",cfg_.batch},{"seq",cfg_.seq},{"hidden",cfg_.hidden},
      {"ffn",cfg_.ffn},{"q_heads",cfg_.q_heads},{"kv_heads",cfg_.kv_heads},{"head_dim",cfg_.head_dim}})
    if(fields.at(kv.first)!=std::to_string(kv.second)) throw std::runtime_error("fixture mismatch: "+kv.first);
  if(fields.at("model")!=cfg_.model) throw std::runtime_error("fixture model mismatch");
  if(fields.at("candidate")!="C"+std::to_string(DECODER_CANDIDATE)) throw std::runtime_error("fixture candidate mismatch");
  if (cfg_.decode() && (fields.at("stage") != cfg_.stage || fields.at("past_kv") != std::to_string(cfg_.past_kv)
      || fields.at("cache_capacity") != std::to_string(cfg_.cache_capacity)))
    throw std::runtime_error("fixture decode metadata mismatch");
  std::ifstream list(fixture/"tensors.tsv");
  if(!list) throw std::runtime_error("missing tensors.tsv");
  std::string line;
  while(std::getline(list,line)) {
    std::istringstream s(line); std::string name,file; uint64_t bytes;
    if(!(s>>name>>bytes>>file)) throw std::runtime_error("invalid tensor record");
    auto& buffer=alloc(name,bytes,"fixture");
    std::ifstream data(fixture/file,std::ios::binary);
    if(!data || fs::file_size(fixture/file)!=bytes) throw std::runtime_error("invalid fixture tensor "+name);
    std::vector<uint8_t> chunk(std::min<uint64_t>(bytes,1<<20));
    for(uint64_t off=0;off<bytes;off+=chunk.size()) {
      auto n=std::min<uint64_t>(bytes-off,chunk.size());
      data.read(reinterpret_cast<char*>(chunk.data()),n);
      if(!data) throw std::runtime_error("short fixture read");
      rt_check(vx_copy_to_dev(buffer.handle,chunk.data(),off,n), "upload fixture");
    }
  }
}
void Decoder::append(Operation operation) {
  for(const auto& name:operation.inputs) (void)buffers_.at(name);
  for(const auto& name:operation.outputs) (void)buffers_.at(name);
  // Preserve every original argument struct verbatim on the wire.
  rt_check(vx_mem_alloc(device_,operation.arguments.size(),VX_MEM_READ_WRITE,&operation.args_buffer), "allocate args");
  ops_.push_back(std::move(operation)); auto& saved=ops_.back();
  rt_check(vx_copy_to_dev(saved.args_buffer,saved.arguments.data(),0,saved.arguments.size()), "upload args");
  DecoderDispatch dispatch{}; dispatch.operation=saved.kind;
  rt_check(vx_mem_address(saved.args_buffer,&dispatch.args_address), "args address");
  rt_check(vx_upload_bytes(device_,&dispatch,sizeof(dispatch),&saved.dispatch_buffer), "upload dispatch");
}
Sample Decoder::launch(Operation& operation, bool profile) {
  auto start=std::chrono::steady_clock::now();
  rt_check(vx_start(device_,kernel_,operation.dispatch_buffer), operation.name.c_str());
  rt_check(vx_ready_wait(device_,300000), operation.name.c_str());
  double seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
  uint64_t cycles=0;
  if(profile) rt_check(vx_mpm_query(device_,0xB00,0,&cycles), "read MCYCLE");
  return {operation.name,cycles,seconds};
}
void Decoder::dump_buffer(const std::string& name,const fs::path& folder) {
  const auto& b=buffers_.at(name); std::vector<uint8_t> bytes(b.bytes);
  rt_check(vx_copy_from_dev(bytes.data(),b.handle,0,b.bytes), "dump tensor");
  std::ofstream out(folder/(name+".bin"),std::ios::binary);
  out.write(reinterpret_cast<const char*>(bytes.data()),bytes.size());
  if(!out) throw std::runtime_error("could not dump "+name);
}
void Decoder::save_output(const fs::path& folder) {
  dump_buffer("output",folder);
  if(cfg_.decode()) for(const auto& operation:ops_)
    if(operation.kind==DecoderOp::quant)
      for(const auto& name:operation.outputs) dump_buffer(name,folder);
}
std::vector<Sample> Decoder::run(bool profile,const fs::path& dump,size_t stop_after) {
  std::vector<Sample> samples;
  if(!dump.empty()) {
    fs::create_directories(dump);
    std::ofstream catalog(dump/"buffers.tsv");
    for(const auto& [name,b]:buffers_)
      catalog<<name<<'\t'<<b.layout<<'\t'<<b.matrices<<'\t'<<b.rows<<'\t'<<b.cols<<'\t'<<b.bytes<<'\n';
  }
  for(auto& operation:ops_) {
    if(!dump.empty()) std::cout<<"BEGIN "<<samples.size()<<' '<<operation.name<<std::endl;
    samples.push_back(launch(operation,profile));
    if(!dump.empty()) {
#if DECODER_CANDIDATE != 1
      if(operation.kind==DecoderOp::gemm) {
        DecoderNaiveArgs result{};
        rt_check(vx_copy_from_dev(&result,operation.args_buffer,0,sizeof(result)), "read naive GEMM status");
        if(result.status!=MMIO_STATUS_OK)
          throw std::runtime_error(operation.name+": naive GEMM status="+std::to_string(result.status));
      }
#endif
      for(const auto& name:operation.outputs) dump_buffer(name,dump);
      std::cout<<"DONE "<<operation.name<<" cycles="<<samples.back().cycles<<std::endl;
    }
    if(stop_after && samples.size()>=stop_after) break;
  }
  return samples;
}
std::vector<Sample> Decoder::isolated(unsigned repetitions) {
  // Caller first runs the complete graph to retain its actual inputs. All
  // intermediate tensors have distinct immutable storage, so no host replay or
  // upstream computation enters an isolated operator's measurement.
  if(!repetitions) throw std::invalid_argument("repetitions must be positive");
  std::vector<Sample> result;
  for(auto& operation:ops_) {
    std::cout<<"ISOLATED "<<operation.name<<std::endl;
    (void)launch(operation,false);
    for(unsigned r=0;r<repetitions;++r) result.push_back(launch(operation,true));
  }
  return result;
}

void Decoder::multiply(const std::string& name,const std::string& input,const std::string& weights,
    const std::string& output,uint32_t m,uint32_t k,uint32_t n,bool attention,
    bool transpose,uint64_t input_offset,uint64_t output_offset) {
#if DECODER_CANDIDATE != 3
  if(DECODER_CANDIDATE==1 || attention) {
    using TC=vortex::tensor::wmma_config_t<NUM_THREADS,vortex::tensor::fp16,vortex::tensor::fp16>;
    if(k%TC::tileK || n%TC::tileN) throw std::runtime_error("TCU K/N must be tile aligned");
    DecoderTcuArgs a{}; a.M=align_up_u32(m,TC::tileM);a.K=k;a.N=n;
    a.grid_dim[0]=n/TC::tileN;a.grid_dim[1]=a.M/TC::tileM;
    a.block_dim[0]=threads;a.block_dim[1]=1;
    a.A_addr=addr(input)+input_offset;a.B_addr=addr(weights+".fp16");a.C_addr=addr(output)+output_offset;
    // Head launches are ordered. Rounded stores may reach the following
    // head's not-yet-produced rows; its later launch replaces them before any
    // consumer runs. The last head writes only into alloc()'s reserved tail.
    append(op(name,DecoderOp::tcu,a,{input,weights+".fp16"},{output}));return;
  }
#endif
#if DECODER_CANDIDATE != 1
  DecoderNaiveArgs a{};a.M=m;a.K=k;a.N=n;a.QBLK=attention?cfg_.head_dim:cfg_.weight_group;
  a.grid_dim[0]=cores;a.grid_dim[1]=1;a.block_dim[0]=1;a.block_dim[1]=1;
  a.WTRANS=transpose;a.QDIR=attention&&!transpose?1:0;
  a.input_base=addr(input)+input_offset;a.weight_base=addr(weights+".weight");
  a.scale_base=addr(weights+".scale");a.zp_base=addr(weights+".zero");a.output_base=addr(output)+output_offset;
  if(!decoder_naive_lmem_layout(a,local_mem)) throw std::runtime_error("naive LMEM overflow");
  append(op(name,DecoderOp::gemm,a,{input,weights+".weight",weights+".scale",weights+".zero"},{output}));
#endif
}
void Decoder::build() {
  if(!ops_.empty())throw std::runtime_error("decoder already built");
  const uint32_t B=cfg_.batch,S=cfg_.seq,M=B*S,H=cfg_.hidden,F=cfg_.ffn;
  const uint32_t Q=cfg_.q_heads,V=cfg_.kv_heads,D=cfg_.head_dim;
  const uint32_t G=cfg_.attention_group_size();
  const uint32_t C=cfg_.decode()?cfg_.cache_capacity:S,L=cfg_.decode()?cfg_.past_kv+1:S;
  const uint32_t tpb=std::min(256u,uint32_t(warps*threads));
  auto blocks=[&](uint64_t count){return uint32_t(std::max<uint64_t>(1,std::min<uint64_t>((count+tpb-1)/tpb,cores*4)));};
  auto tensor=[&](const std::string& n,uint32_t mats,uint32_t rows,uint32_t cols){alloc(n,uint64_t(mats)*rows*cols*2,"row",mats,rows,cols);};
  auto reorder=[&](const std::string& name,const std::string& in,uint32_t batch,uint32_t seq,uint32_t heads,uint32_t dim,uint32_t kind){
    tensor(name,batch*heads,seq,dim);DecoderReorderArgs a{};grid(a,blocks(uint64_t(batch)*seq*heads*dim),tpb);
    a.input=addr(in);a.output=addr(name);a.batch=batch;a.seq=seq;a.heads=heads;a.dim=dim;a.kind=kind;
    append(op(name,DecoderOp::reorder,a,{in},{name}));
  };
  auto norm=[&](const std::string& name,const std::string& in,const std::string& gamma){
    tensor(name,1,M,H);DecoderRmsArgs a{};grid(a,M,rmsnorm_threads_per_block(M,warps,threads));
    a.input_addr=addr(in);a.output_addr=addr(name);a.gamma_addr=addr(gamma);a.batch_size=B;a.seq_len=S;a.hidden_dim=H;a.eps=cfg_.eps;
    append(op(name,DecoderOp::rms,a,{in,gamma},{name}));
  };
  auto linear=[&](const std::string& name,const std::string& in,uint32_t k,uint32_t n){tensor(name,1,M,n);multiply(name,in,name,name,M,k,n,false);};
  auto rope=[&](const std::string& name,const std::string& in,uint32_t heads){
    auto tmp=name+"_interleaved";tensor(tmp,1,M,heads*D);DecoderRopeArgs a{};grid(a,std::min(uint32_t((uint64_t(M)*heads*((D/2+15u)/16u)+tpb-1)/tpb),uint32_t(cores)),tpb);
    a.input_addr=addr(in);a.output_addr=addr(tmp);a.cos_addr=addr("rope.cos");a.sin_addr=addr("rope.sin");
    a.batch_size=B;a.seq_len=S;a.num_heads=heads;a.head_dim=D;a.pos_offset=0;
    append(op(tmp,DecoderOp::rope,a,{in,"rope.cos","rope.sin"},{tmp}));reorder(name,tmp,B,S,heads,D,0);
  };
  auto had=[&](const std::string& name,const std::string& in,uint32_t rows,uint32_t dim,uint32_t base){
    tensor(name,1,rows,dim);DecoderHadamardArgs a{};bool r3=base==1&&dim==128;
    grid(a,r3?std::min(rows,uint32_t(cores*warps)):rows,r3||rows>=warps?uint32_t(threads):tpb);
    a.input_addr=addr(in);a.output_addr=addr(name);a.matrix_addr=addr(base==1?"hadamard.r3":"hadamard.r4");
    a.rows=rows;a.dim=dim;a.padded_dim=dim;a.stop_stride=dim/base;a.base_k=base;a.width=dim/base;a.inv_sqrt_dim=1/std::sqrt(float(dim));
    append(op(name,DecoderOp::hadamard,a,{in,base==1?"hadamard.r3":"hadamard.r4"},{name}));
  };
  auto residual=[&](const std::string& name,const std::string& in,const std::string& skip){tensor(name,1,M,H);DecoderEladdArgs a{};grid(a,blocks(uint64_t(M)*H),tpb);
    a.input_a_addr=addr(in);a.input_b_addr=addr(skip);a.output_addr=addr(name);a.size=M*H;append(op(name,DecoderOp::eladd,a,{in,skip},{name}));};
  norm("attention_norm","hidden","input_norm.weight");
  linear("q_proj","attention_norm",H,H);linear("k_proj","attention_norm",H,V*D);linear("v_proj","attention_norm",H,V*D);
  rope("q_rope","q_proj",Q);rope("k_rope","k_proj",V);
  had("q_hadamard","q_rope",B*Q*S,D,1);had("k_hadamard","k_rope",B*V*S,D,1);
  reorder("v_head_major","v_proj",B,S,V,D,0);
  for(uint32_t b=0;b<B;++b)for(uint32_t h=0;h<V;++h)for(uint32_t key=0;key<2;++key){
    auto name=std::string(key?"key.":"value.")+std::to_string(b)+"."+std::to_string(h);
    auto input=key?"k_hadamard":"v_head_major";
    if(!cfg_.decode()){alloc(name+".weight",uint64_t(C)*D/2,"w",1,C,D);alloc(name+".scale",C*2,"scale");alloc(name+".zero",C*2,"zero");}
    const uint32_t work_items=kv_cache_quant_work_items(S,D,D,1);
    const uint32_t mapping=kv_cache_quant_mapping_mode(work_items,1,D,cores,warps);
    const uint32_t quant_threads=kv_cache_quant_threads_per_block(mapping,warps,threads);
    DecoderQuantArgs a{};grid(a,kv_cache_quant_blocks(work_items,quant_threads,mapping,cores,warps),quant_threads);
    a.src_addr=addr(input)+uint64_t(b*V+h)*S*D*2;
    const uint32_t pos=cfg_.decode()?cfg_.past_kv:0;
    a.dst_addr=addr(name+".weight")+uint64_t(pos)*D/2;a.scale_addr=addr(name+".scale")+pos*2;a.zero_addr=addr(name+".zero")+pos*2;
    a.K=S;a.N=D;a.QBLK=D;a.QDIR=1;a.quant_mode=KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC;a.mapping_mode=mapping;a.log2_qblk=lg(D);
    append(op(name,DecoderOp::quant,a,{input},{name+".weight",name+".scale",name+".zero"}));
#if DECODER_CANDIDATE != 3
    // Cache dequantization is part of the real TCU attention graph.
    auto dq=name+(key?".fp16":".dequant");tensor(dq,1,C,D);
    const uint32_t dequant_threads=kv_cache_dequant_threads_per_block(warps,threads);
    const uint32_t dequant_work=kv_cache_dequant_work_items(C,D,D,1,threads);
    DecoderDequantArgs d{};grid(d,kv_cache_dequant_blocks(dequant_work,dequant_threads,cores,warps),dequant_threads);
    d.src_addr=addr(name+".weight");d.dst_addr=addr(dq);d.scale_addr=addr(name+".scale");d.zero_addr=addr(name+".zero");
    d.K=C;d.N=D;d.QBLK=D;d.QDIR=1;d.quant_mode=KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC;
    append(op(dq,DecoderOp::dequant,d,{name+".weight",name+".scale",name+".zero"},{dq}));
    if(!key)reorder(name+".fp16",dq,1,C,1,D,1);
#endif
  }
  tensor("scores",B*Q,S,C);tensor("probabilities",B*Q,S,C);tensor("context",B*Q,S,D);
  for(uint32_t b=0;b<B;++b)for(uint32_t h=0;h<Q;h+=G){auto key="key."+std::to_string(b)+"."+std::to_string(h/(Q/V));
    multiply("qk."+std::to_string(b)+"."+std::to_string(h),"q_hadamard",key,"scores",G*S,D,C,true,true,uint64_t(b*Q+h)*S*D*2,uint64_t(b*Q+h)*S*C*2);}
  DecoderSoftmaxArgs soft{};grid(soft,B*Q*S,threads);soft.input_addr=addr("scores");soft.output_addr=addr("probabilities");soft.batch_size=B;soft.num_heads=Q;soft.seq_len_q=S;soft.seq_len_k=L;soft.row_pitch_bytes=C*2;soft.use_mask=cfg_.decode()?0:1;soft.scale=1/std::sqrt(float(D));
  append(op("softmax",DecoderOp::softmax,soft,{"scores"},{"probabilities"}));
  for(uint32_t b=0;b<B;++b)for(uint32_t h=0;h<Q;h+=G){auto val="value."+std::to_string(b)+"."+std::to_string(h/(Q/V));
    multiply("pv."+std::to_string(b)+"."+std::to_string(h),"probabilities",val,"context",G*S,C,D,true,false,uint64_t(b*Q+h)*S*C*2,uint64_t(b*Q+h)*S*D*2);}
  tensor("concat",1,M,H);DecoderConcatArgs cat{};grid(cat,blocks(uint64_t(M)*Q*((D+15u)/16u)),tpb);cat.input_addr=addr("context");cat.output_addr=addr("concat");cat.batch=B;cat.seq=S;cat.heads=Q;cat.headdim=D;append(op("concat",DecoderOp::concat,cat,{"context"},{"concat"}));
  linear("o_proj","concat",H,H);residual("attention_residual","o_proj","hidden");norm("ffn_norm","attention_residual","post_attention_norm.weight");
  linear("gate_proj","ffn_norm",H,F);linear("up_proj","ffn_norm",H,F);
  tensor("silu",1,M,F);DecoderSiluArgs si{};grid(si,blocks(uint64_t(M)*((F+31u)/32u)),tpb);si.input_addr=addr("gate_proj");si.output_addr=addr("silu");si.size=M*F;si.M=M;si.K=F;append(op("silu",DecoderOp::silu,si,{"gate_proj"},{"silu"}));
  tensor("mlp_product",1,M,F);DecoderElmulArgs mul{};grid(mul,blocks(uint64_t(M)*F),tpb);mul.input_a_addr=addr("silu");mul.input_b_addr=addr("up_proj");mul.output_addr=addr("mlp_product");mul.size=M*F;append(op("mlp_product",DecoderOp::elmul,mul,{"silu","up_proj"},{"mlp_product"}));
  auto r4=uint32_t(std::sqrt(buffers_.at("hadamard.r4").bytes/2));had("ffn_hadamard","mlp_product",M,F,r4);
  linear("down_proj","ffn_hadamard",F,H);residual("output","down_proj","attention_residual");
}
