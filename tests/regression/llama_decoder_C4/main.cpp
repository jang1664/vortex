#include "decoder.h"
#include "../vector_common/fp16_preserve.h"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <numeric>

namespace fs=std::filesystem;
static std::vector<uint16_t> read_half(const fs::path& path) {
  auto bytes=fs::file_size(path);
  if(bytes%2) throw std::runtime_error("invalid fp16 file");
  std::vector<uint16_t> data(bytes/2);
  std::ifstream in(path,std::ios::binary);
  in.read(reinterpret_cast<char*>(data.data()),bytes);
  if(!in) throw std::runtime_error("could not read "+path.string());
  return data;
}
static bool check_output(const fs::path& fixture,const fs::path& out) {
  auto expected=read_half(fixture/"reference/output.bin");
  auto actual=read_half(out/"output.bin");
  if(expected.size()!=actual.size()) throw std::runtime_error("output shape mismatch");
  double error2=0,ref2=0,act2=0,dot=0,max_abs=0,sum_abs=0;
  size_t bad=0,nonfinite=0,max_index=0;
  for(size_t i=0;i<actual.size();++i) {
    double r=fp16_to_float_preserve(expected[i]),v=fp16_to_float_preserve(actual[i]);
    if(!std::isfinite(r)||!std::isfinite(v)) { ++nonfinite; continue; }
    double e=std::abs(v-r);
    if(e>max_abs) { max_abs=e; max_index=i; }
    sum_abs+=e; error2+=e*e; ref2+=r*r; act2+=v*v; dot+=v*r;
    // Decoder-level tolerance approved separately from the 0.002 local gate.
    if(e>(std::abs(r)<0.25?0.005:0.005*std::abs(r))) ++bad;
  }
  double relative_l2=std::sqrt(error2/std::max(ref2,1e-30));
  double cosine=dot/std::max(std::sqrt(ref2*act2),1e-30);
  bool pass=nonfinite==0 && double(bad)/actual.size()<=0.02 && relative_l2<=0.01 && cosine>=0.999;
  std::ofstream report(out/"verification.json");
  report<<std::setprecision(12)<<"{\n  \"atol\": 0.005, \"rtol\": 0.005,\n  \"pass\": "<<(pass?"true":"false")
        <<",\n  \"elements\": "<<actual.size()<<",\n  \"violations\": "<<bad
        <<",\n  \"nonfinite\": "<<nonfinite<<",\n  \"max_abs\": "<<max_abs
        <<",\n  \"max_index\": "<<max_index<<",\n  \"mean_abs\": "<<sum_abs/actual.size()
        <<",\n  \"relative_l2\": "<<relative_l2<<",\n  \"cosine\": "<<cosine<<"\n}\n";
  std::cout<<"CPU OUTPUT "<<(pass?"PASS":"FAIL")<<" max_abs="<<max_abs
           <<" violations="<<bad<<'/'<<actual.size()<<" rel_l2="<<relative_l2<<" cosine="<<cosine<<std::endl;
  return pass;
}
static void save_samples(const fs::path& path,const std::vector<Sample>& samples) {
  std::ofstream file(path); file<<"operation,repetition,cycles,host_seconds\n"<<std::setprecision(12);
  std::map<std::string,unsigned> repetitions;
  for(const auto& sample:samples)
    file<<sample.name<<','<<repetitions[sample.name]++<<','<<sample.cycles<<','<<sample.seconds<<'\n';
  if(!file) throw std::runtime_error("could not save samples");
}
int main(int argc,char** argv) {
  try {
    std::string model="llama3-8b",mode="verify";
    fs::path fixture,out="decoder_results";
    uint32_t batch=1,seq=32,repetitions=3,stop_after=0;
    for(int i=1;i<argc;++i) {
      std::string key=argv[i];
      if(key=="--help" || key=="-h") {
        std::cout<<"--model llama3-8b|llama2-7b --batch 1 --seq-len 32 --fixture DIR\n"
                   "--mode verify|timing|isolated --output DIR --repetitions 3\n"
                   "--stop-after N (partial diagnostic only; never a decoder PASS)\n";
        return 0;
      }
      if(++i==argc) throw std::invalid_argument("missing value for "+key);
      std::string value=argv[i];
      auto extent=[&]() { size_t end=0; auto n=std::stoul(value,&end); if(end!=value.size()||!n||n>UINT32_MAX) throw std::invalid_argument("invalid extent"); return uint32_t(n); };
      if(key=="--model") model=value;
      else if(key=="--mode") mode=value;
      else if(key=="--fixture") fixture=value;
      else if(key=="--output") out=value;
      else if(key=="--batch") batch=extent();
      else if(key=="--seq-len") seq=extent();
      else if(key=="--repetitions") repetitions=extent();
      else if(key=="--stop-after") stop_after=extent();
      else throw std::invalid_argument("unknown option "+key);
    }
    if(fixture.empty()) throw std::invalid_argument("--fixture is required");
    if(mode!="verify" && mode!="timing" && mode!="isolated") throw std::invalid_argument("unknown mode");
    if(stop_after && mode!="verify") throw std::invalid_argument("partial execution is only supported in verify mode");
    auto config=ModelConfig::preset(model); config.batch=batch; config.seq=seq; config.validate();
    if(!fs::exists(fixture/"reference/output.bin")) throw std::invalid_argument("fixture needs CPU reference/output.bin");
    fs::create_directories(out);
    Decoder decoder(config); decoder.load(fixture); decoder.build();
    size_t gemms=0; for(const auto& o:decoder.operations()) gemms+=o.kind==DecoderOp::gemm;
    std::cout<<"DECODER "<<model<<" B="<<batch<<" S="<<seq<<" heads="<<config.q_heads
      <<" kv_heads="<<config.kv_heads<<" operations="<<decoder.operations().size()<<" gemms="<<gemms<<std::endl;
    if(mode=="verify") {
      auto samples=decoder.run(true,out,stop_after); save_samples(out/"profile.csv",samples);
      if(stop_after && samples.size()<decoder.operations().size()) {
        std::cout<<"PARTIAL DIAGNOSTIC: "<<samples.size()<<" operations; full functionality not checked"<<std::endl;
        return 0;
      }
      if(!check_output(fixture,out)) return 1;
      std::cout<<"PASSED: decoder final output; intermediate checks are in reference.py"<<std::endl;
    } else {
      // Verify the actual chain once before collecting latency.
      decoder.run(false,out);
      if(!check_output(fixture,out)) throw std::runtime_error("correctness gate failed; timing skipped");
      if(mode=="isolated") save_samples(out/"isolated.csv",decoder.isolated(repetitions));
      else {
        std::vector<double> times;
        for(uint32_t r=0;r<repetitions;++r) {
          auto start=std::chrono::steady_clock::now(); decoder.run(false,{});
          auto elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
          times.push_back(elapsed); std::cout<<"TIMING "<<r<<' '<<elapsed<<std::endl;
        }
        std::ofstream file(out/"timings.csv"); file<<"repetition,seconds\n"<<std::setprecision(12);
        for(size_t i=0;i<times.size();++i) file<<i<<','<<times[i]<<'\n';
        // Counter queries belong to separate passes, outside wall timing.
        std::vector<Sample> profile;
        for(uint32_t r=0;r<repetitions;++r) {
          auto samples=decoder.run(true,{});
          profile.insert(profile.end(),samples.begin(),samples.end());
        }
        save_samples(out/"profile.csv",profile);
      }
    }
    return 0;
  } catch(const std::exception& e) { std::cerr<<"ERROR: "<<e.what()<<std::endl; return 1; }
}
