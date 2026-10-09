#pragma once
#include "common.h"
#include "model_config.h"
#include <vortex.h>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

void rt_check(int status, const char* action);
struct Buffer {
  vx_buffer_h handle = nullptr;
  uint64_t address = 0, bytes = 0;
  std::string name, layout;
  uint32_t matrices = 1, rows = 1, cols = 1;
};
struct Operation {
  std::string name;
  DecoderOp kind;
  std::vector<uint8_t> arguments;
  std::vector<std::string> inputs, outputs;
  vx_buffer_h args_buffer = nullptr, dispatch_buffer = nullptr;
};
struct Sample { std::string name; uint64_t cycles; double seconds; };
class Decoder {
 public:
  explicit Decoder(ModelConfig config);
  ~Decoder();
  Decoder(const Decoder&) = delete;
  Decoder& operator=(const Decoder&) = delete;
  void load(const std::filesystem::path& fixture);
  void build();
  std::vector<Sample> run(bool profile, const std::filesystem::path& dump, size_t stop_after = 0);
  std::vector<Sample> isolated(unsigned repetitions);
  const std::vector<Operation>& operations() const { return ops_; }
  uint64_t cores = 0, warps = 0, threads = 0, tmem = 0;
 private:
  ModelConfig cfg_;
  vx_device_h device_ = nullptr;
  vx_buffer_h kernel_ = nullptr;
  std::map<std::string, Buffer> buffers_;
  std::vector<Operation> ops_;
  Buffer& alloc(const std::string& name, uint64_t bytes, const std::string& layout,
                uint32_t matrices = 1, uint32_t rows = 1, uint32_t cols = 1);
  uint64_t addr(const std::string& name) const;
  void append(Operation op);
  Sample launch(Operation& op, bool profile);
  void dump_buffer(const std::string& name, const std::filesystem::path& folder);
  void gemm(const std::string& name, const std::string& input,
            const std::string& weight, const std::string& scale, const std::string& zero,
            const std::string& output, uint32_t m, uint32_t k, uint32_t n,
            uint32_t group, uint32_t transpose, uint32_t qdir,
            uint64_t input_offset = 0, uint64_t output_offset = 0);
};
