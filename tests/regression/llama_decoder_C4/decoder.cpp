#include "decoder.h"
#include "op_args.h"
#include "../fpint_gemm_ffn_hw/layout.h"
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
uint32_t pad_rows(uint32_t m) { return (m+7u)&~7u; }
uint64_t tensor_bytes(uint32_t matrices, uint32_t m, uint32_t n) {
  return uint64_t(matrices)*pad_rows(m)*n*2;
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
    tmem=uint64_t(TMEM_BANK_SIZE)*NUM_TMEM_BANKS;
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
  rt_check(vx_mem_alloc_aligned(device_, bytes, 512, VX_MEM_READ_WRITE, &b.handle), "allocate tensor");
  buffers_.emplace(name,b);
  auto& result=buffers_.at(name);
  rt_check(vx_mem_address(result.handle,&result.address), "tensor address");
  // Defined padding and deterministic initial data, outside all measurements.
  std::vector<uint8_t> zeros(std::min<uint64_t>(bytes,1<<20),0);
  for(uint64_t off=0;off<bytes;off+=zeros.size())
    rt_check(vx_copy_to_dev(result.handle,zeros.data(),off,std::min<uint64_t>(bytes-off,zeros.size())), "zero tensor");
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
      if(operation.kind==DecoderOp::gemm) {
        DecoderGemmArgs arg{};
        rt_check(vx_copy_from_dev(&arg,operation.args_buffer,0,sizeof(arg)),"GEMM status");
        if(arg.status!=STATUS_OK) throw std::runtime_error("GEMM bad status "+std::to_string(arg.status));
      }
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
void Decoder::gemm(const std::string& name,const std::string& input,
    const std::string& weight,const std::string& scale,const std::string& zero,
    const std::string& output,uint32_t m,uint32_t k,uint32_t n,
    uint32_t group,uint32_t transpose,uint32_t qdir,uint64_t input_offset,uint64_t output_offset,
    uint32_t target_k,uint32_t target_n) {
  DecoderGemmArgs arg{};
  arg.dram_in_base=addr(input)+input_offset; arg.dram_w_base=addr(weight);
  arg.dram_sc_base=addr(scale); arg.dram_zp_base=addr(zero); arg.dram_out_base=addr(output)+output_offset;
  // Fused vector kernels store microtiles with an eight-row physical pitch.
  // Describe that parent matrix separately from the real execution extent.
  arg.M=pad_rows(m); arg.target_M=m; arg.N=n; arg.K=k;
  arg.target_N=target_n?target_n:n; arg.target_K=target_k?target_k:k;
  if(arg.target_N>n || arg.target_K>k) throw std::runtime_error("target exceeds parent matrix");
  arg.QBLK=group; arg.WTRANS=transpose; arg.QDIR=qdir;
  if(!fpint_gemm_layout::allocate_tmem_buffers(arg,tmem,128,128,128,MXU_COL,group,qdir))
    throw std::runtime_error("GEMM TMEM overflow");
  if(input_offset+tensor_bytes(1,m,k)>buffers_.at(input).bytes ||
     output_offset+tensor_bytes(1,m,n)>buffers_.at(output).bytes)
    throw std::runtime_error("GEMM tensor range overflow");
  append(op(name,DecoderOp::gemm,arg,{input,weight,scale,zero},{output}));
}

void Decoder::build() {
  if(!ops_.empty()) throw std::runtime_error("decoder already built");
  const uint32_t B=cfg_.batch, S=cfg_.seq, M=B*S, H=cfg_.hidden, F=cfg_.ffn;
  const uint32_t Q=cfg_.q_heads, V=cfg_.kv_heads, D=cfg_.head_dim;
  const uint32_t G=cfg_.attention_group_size(), attention_heads=Q/G, attention_rows=G*S;
  const uint32_t C=cfg_.decode()?cfg_.cache_capacity:S;
  const uint32_t L=cfg_.decode()?cfg_.past_kv+1:S;
  const uint32_t E=cfg_.decode()?((L+31)/32)*32:S;
  const uint32_t tpb=std::min(256u,uint32_t(warps*threads));
  auto blocks=[&](uint64_t count) { return uint32_t(std::min<uint64_t>((count+tpb-1)/tpb,cores*4)); };
  auto tensor=[&](const std::string& name,uint32_t matrices,uint32_t rows,uint32_t cols,const char* layout) {
    alloc(name,tensor_bytes(matrices,rows,cols),layout,matrices,rows,cols);
  };
  auto norm=[&](const std::string& name,const std::string& input,const std::string& gamma) {
    tensor(name,1,M,H,"a"); DecoderRmsArgs a{};
    a.kernel_id=KERNEL_RMSNORM_LAYOUT_FUSED; grid(a,M,M<warps?tpb:uint32_t(threads));
    a.input_addr=addr(input); a.output_addr=addr(name); a.gamma_addr=addr(gamma);
    a.M_real=M; a.M_pad=pad_rows(M); a.K=H; a.eps=cfg_.eps;
    a.log2_mt=a.log2_kt=7; a.log2_mxu_kt=lg(MXU_ROW);
    append(op(name,DecoderOp::rms,a,{input,gamma},{name}));
  };
  auto linear=[&](const std::string& name,const std::string& input,uint32_t k,uint32_t n) {
    tensor(name,1,M,n,"c");
    gemm(name,input,name+".weight",name+".scale",name+".zero",name,M,k,n,cfg_.weight_group,0,0);
  };
  auto rope=[&](const std::string& name,const std::string& input,uint32_t heads) {
    alloc(name,uint64_t(B)*heads*S*D*2,"row",B*heads,S,D); DecoderRopeArgs a{};
    grid(a,std::min(uint32_t((uint64_t(B)*S*heads*(D/2)+tpb-1)/tpb),uint32_t(cores)),tpb);
    a.input_addr=addr(input); a.output_addr=addr(name); a.cos_addr=addr("rope.cos"); a.sin_addr=addr("rope.sin");
    a.batch_size=B; a.seq_len=S; a.num_heads=heads; a.head_dim=D; a.max_seq_len=S;
    a.layout_to=ROPE_LAYOUT_TO_HEAD_MAJOR_ROW; a.input_m_pad=pad_rows(M); a.output_m_pad=pad_rows(S);
    a.log2_mt=a.log2_kt=7; a.log2_mxu_kt=lg(MXU_ROW); a.log2_mxu_nt=lg(MXU_COL);
    append(op(name,DecoderOp::rope,a,{input,"rope.cos","rope.sin"},{name}));
  };
  auto had=[&](const std::string& name,const std::string& input,uint32_t matrices,uint32_t rows,
               uint32_t dim,uint32_t base,bool tiled) {
    tensor(name,matrices,rows,dim,"a"); DecoderHadamardArgs a{};
    const bool r3=base==1 && dim==128 && !tiled && (threads==16 || threads==32);
    const bool multi=uint64_t(matrices)*rows<warps && dim/base>threads;
    // Match the original r3 flattened/persistent launch policy.
    const uint32_t workers=cores*warps;
    const bool flat=r3 && matrices>1 && rows<=workers && uint64_t(matrices)*rows>workers && workers%rows==0;
    grid(a,flat?workers:r3?std::min(rows,workers):rows,threads*(r3?1:multi?warps:1),flat?1:matrices);
    a.input_addr=addr(input); a.output_addr=addr(name); a.matrix_addr=addr(base==1?"hadamard.r3":"hadamard.r4");
    a.matrix_count=matrices; a.rows=rows; a.m_pad=pad_rows(rows); a.dim=dim; a.base_k=base; a.width=dim/base;
    a.input_layout=tiled?HADAMARD_INPUT_GEMM_A_TILED:HADAMARD_INPUT_ROW_MAJOR;
    a.inv_sqrt_dim=1.0f/std::sqrt(float(dim)); a.log2_mt=7; a.log2_mxu_kt=lg(MXU_ROW);
    append(op(name,DecoderOp::hadamard,a,{input,base==1?"hadamard.r3":"hadamard.r4"},{name}));
  };
  auto residual=[&](const std::string& name,const std::string& input,const std::string& skip) {
    alloc(name,uint64_t(M)*H*2,"row",1,M,H); DecoderEladdArgs a{};
    grid(a,blocks(uint64_t(M)*H),tpb); a.input_a_addr=addr(input); a.input_b_addr=addr(skip); a.output_addr=addr(name);
    a.M_real=M; a.M_pad=pad_rows(M); a.K=H; a.log2_mt=7; a.log2_mxu_nt=lg(MXU_COL);
    append(op(name,DecoderOp::eladd,a,{input,skip},{name}));
  };
  norm("attention_norm","hidden","input_norm.weight");
  linear("q_proj","attention_norm",H,H);
  linear("k_proj","attention_norm",H,V*D);
  linear("v_proj","attention_norm",H,V*D);
  rope("q_rope","q_proj",Q); rope("k_rope","k_proj",V);
  // Pack queries sharing K/V into rows of one parent matrix. Hadamard writes
  // that layout directly; softmax and concat consume the same grouped rows.
  had("q_hadamard","q_rope",B*attention_heads,attention_rows,D,1,false);
  had("k_hadamard","k_rope",B*V,S,D,1,false);

  for(uint32_t b=0;b<B;++b) for(uint32_t h=0;h<V;++h) for(uint32_t is_key=0;is_key<2;++is_key) {
    const std::string name=(is_key?"key":"value")+std::string(".")+std::to_string(b)+"."+std::to_string(h);
    const std::string input=is_key?"k_hadamard":"v_proj";
    const uint32_t transpose=is_key, qdir=is_key?0:1;
    auto weight_bytes=weight_total_bytes_host(C,D,transpose);
    auto scales_bytes=scale_total_bytes_host(C,D,D,qdir,transpose,128,128);
    if (!cfg_.decode()) {
      alloc(name+".weight",weight_bytes,"w",1,is_key?D:C,is_key?C:D);
      alloc(name+".scale",scales_bytes,"scale"); alloc(name+".zero",scales_bytes,"zero");
    } else if(buffers_.at(name+".weight").bytes!=weight_bytes || buffers_.at(name+".scale").bytes!=scales_bytes
        || buffers_.at(name+".zero").bytes!=scales_bytes) throw std::runtime_error("cache storage size mismatch");
    alloc(name+".logical_scale",uint64_t(C)*2,"row",1,C,1);
    alloc(name+".logical_zero",uint64_t(C)*2,"row",1,C,1);
    DecoderQuantArgs a{};
    const uint32_t max_slot=max_scale_slot_bytes_host(C,D,D,qdir,transpose,128,128)/2;
    const uint32_t out_k=padded_qparam_K_host(C,D,D,qdir,transpose);
    const uint32_t out_n=padded_qparam_N_host(C,D,D,qdir,transpose);
    const uint32_t work=std::max<uint32_t>(weight_bytes,((out_k+127)/128)*((out_n+127)/128)*max_slot);
    // These tiled prefill shapes use the ordinary (non-cross-group) launch.
    if(!init_kernel_arg(a,C,D,D,1,transpose,qdir,transpose,
          is_key?SRC_LAYOUT_GEMM_A_TILED:SRC_LAYOUT_GEMM_C_TILED,
          128,128,128,cfg_.decode()?1:blocks(work),cfg_.decode()?uint32_t(threads):tpb,KV_QUANT_SPINQUANT_SIGNED_ASYMMETRIC,is_key?D:V*D,is_key?0:h*D))
      throw std::runtime_error("invalid KV quant args");
    if(cfg_.decode()) { a.K=1; a.persistent_mode=1; a.cache_capacity=C; a.cache_position=cfg_.past_kv; }
    a.src_addr=addr(input)+(is_key?uint64_t(b*V+h)*pad_rows(S)*D*2:0);
    a.src_total_K=is_key?pad_rows(S):pad_rows(M); a.src_row_offset=is_key?0:b*S;
    a.weight_addr=addr(name+".weight"); a.scale_addr=addr(name+".scale"); a.zero_addr=addr(name+".zero");
    a.logical_scale_addr=addr(name+".logical_scale"); a.logical_zero_addr=addr(name+".logical_zero");
    append(op(name,DecoderOp::quant,a,{input},{name+".weight",name+".scale",name+".zero",name+".logical_scale",name+".logical_zero"}));
  }
  tensor("scores",B*attention_heads,attention_rows,C,"c"); tensor("probabilities",B*attention_heads,attention_rows,C,"a"); tensor("context",B*attention_heads,attention_rows,D,"c");
  for(uint32_t b=0;b<B;++b) for(uint32_t h=0;h<Q;h+=G) {
    auto kv="key."+std::to_string(b)+"."+std::to_string(h/(Q/V));
    gemm("qk."+std::to_string(b)+"."+std::to_string(h),"q_hadamard",kv+".weight",kv+".scale",kv+".zero",
      "scores",attention_rows,D,C,D,1,0,uint64_t(b*attention_heads+h/G)*pad_rows(attention_rows)*D*2,uint64_t(b*attention_heads+h/G)*pad_rows(attention_rows)*C*2,0,E);
  }
  DecoderSoftmaxArgs soft{}; grid(soft,B*Q*S,threads);
  soft.input_addr=addr("scores"); soft.output_addr=addr("probabilities");
  soft.batch_size=B; soft.num_heads=attention_heads; soft.seq_len_q=attention_rows; soft.seq_len_k=L; soft.seq_len_k_pad=soft.output_k_pad=C;
  soft.M_pad=pad_rows(attention_rows); soft.use_mask=cfg_.decode()?0:1; soft.scale=1/std::sqrt(float(D));
  soft.log2_mt=soft.log2_kt=7; soft.log2_mxu_kt=lg(MXU_ROW); soft.log2_mxu_nt=lg(MXU_COL);
  append(op("softmax",DecoderOp::softmax,soft,{"scores"},{"probabilities"}));
  for(uint32_t b=0;b<B;++b) for(uint32_t h=0;h<Q;h+=G) {
    auto kv="value."+std::to_string(b)+"."+std::to_string(h/(Q/V));
    gemm("pv."+std::to_string(b)+"."+std::to_string(h),"probabilities",kv+".weight",kv+".scale",kv+".zero",
      "context",attention_rows,C,D,D,0,1,uint64_t(b*attention_heads+h/G)*pad_rows(attention_rows)*C*2,uint64_t(b*attention_heads+h/G)*pad_rows(attention_rows)*D*2,E,0);
  }
  tensor("concat",1,M,H,"a"); DecoderConcatArgs cat{};
  grid(cat,blocks(uint64_t(M)*H),tpb); cat.input_addr=addr("context"); cat.output_addr=addr("concat");
  cat.batch=B; cat.seq=S; cat.heads=Q; cat.headdim=D; cat.query_heads_per_kv=G;
  cat.input_m_pad=pad_rows(attention_rows); cat.output_m_pad=pad_rows(M);
  cat.log2_mt=7; cat.log2_mxu_kt=lg(MXU_ROW); cat.log2_mxu_nt=lg(MXU_COL);
  append(op("concat",DecoderOp::concat,cat,{"context"},{"concat"}));
  linear("o_proj","concat",H,H); residual("attention_residual","o_proj","hidden");
  norm("ffn_norm","attention_residual","post_attention_norm.weight");
  linear("gate_proj","ffn_norm",H,F); linear("up_proj","ffn_norm",H,F);
  tensor("silu",1,M,F,"c"); DecoderSiluArgs si{};
  si.kernel_id=KERNEL_SILU_LAYOUT_FUSED; grid(si,blocks(uint64_t(M)*(F/MXU_COL)),tpb);
  si.input_addr=addr("gate_proj"); si.output_addr=addr("silu"); si.M_real=M; si.M_pad=pad_rows(M); si.K=F; si.size=M*F;
  si.log2_mt=si.log2_kt=7; si.log2_mxu_kt=lg(MXU_COL);
  append(op("silu",DecoderOp::silu,si,{"gate_proj"},{"silu"}));
  tensor("mlp_product",1,M,F,"a"); DecoderElmulArgs mul{};
  grid(mul,blocks(uint64_t(M)*F),tpb); mul.input_a_addr=addr("silu"); mul.input_b_addr=addr("up_proj"); mul.output_addr=addr("mlp_product");
  mul.M_real=M; mul.M_pad=pad_rows(M); mul.K=F; mul.log2_mt=mul.log2_kt=7; mul.log2_mxu_kt=lg(MXU_ROW); mul.log2_mxu_nt=lg(MXU_COL);
  append(op("mlp_product",DecoderOp::elmul,mul,{"silu","up_proj"},{"mlp_product"}));
  const uint32_t r4=uint32_t(std::sqrt(buffers_.at("hadamard.r4").bytes/2));
  if(uint64_t(r4)*r4*2!=buffers_.at("hadamard.r4").bytes || F%r4)
    throw std::runtime_error("invalid R4 matrix");
  had("ffn_hadamard","mlp_product",1,M,F,r4,true);
  linear("down_proj","ffn_hadamard",F,H); residual("output","down_proj","attention_residual");
}
