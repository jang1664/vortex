#pragma once
#include <cstdint>
#include <stdexcept>
#include <string>
struct ModelConfig {
  std::string model = "llama3-8b";
  uint32_t batch = 1, seq = 32, hidden = 4096, ffn = 14336;
  uint32_t q_heads = 32, kv_heads = 8, head_dim = 128;
  uint32_t weight_group = 32, kv_group = 128;
  float eps = 1e-5f, rope_theta = 500000.0f;
  static ModelConfig preset(const std::string& name) {
    ModelConfig c;
    c.model = name;
    if (name == "llama2-7b") { c.ffn = 11008; c.kv_heads = 32; c.rope_theta = 10000; }
    else if (name != "llama3-8b") throw std::invalid_argument("unknown model: " + name);
    return c;
  }
  void validate() const {
    if (!batch || !seq || hidden != q_heads * head_dim || !kv_heads || q_heads % kv_heads)
      throw std::invalid_argument("invalid model dimensions");
    // Kernel/layout execution extent support, independent of thread-count checks.
    if (seq % 16 || head_dim != kv_group || hidden % weight_group || ffn % weight_group)
      throw std::invalid_argument("initial prefill requires seq multiple of 16 and one KV group per head");
  }
};
