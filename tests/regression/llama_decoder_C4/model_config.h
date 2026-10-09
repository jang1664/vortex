#pragma once
#include <cstdint>
#include <stdexcept>
#include <string>
struct ModelConfig {
  std::string model = "llama3-8b";
  uint32_t batch = 1, seq = 32, hidden = 4096, ffn = 14336;
  std::string stage = "prefill";
  uint32_t past_kv = 0, cache_capacity = 0;
  bool decode() const { return stage == "decode"; }
  uint32_t q_heads = 32, kv_heads = 8, head_dim = 128;
  // Decode queries sharing a KV head are consecutive rows of one GEMM.
  // Prefill retains per-head matrices so its causal row index stays unchanged.
  uint32_t attention_group_size() const { return decode() ? q_heads / kv_heads : 1; }
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
    if (stage != "prefill" && stage != "decode") throw std::invalid_argument("invalid stage");
    if (decode() && (batch != 1 || seq != 1 || !past_kv || cache_capacity <= past_kv || cache_capacity % 32))
      throw std::invalid_argument("decode requires B1/S1, positive past KV, and capacity >= past+1 aligned to 32");
    if (!decode() && (past_kv || cache_capacity)) throw std::invalid_argument("cache arguments require decode stage");
    // Kernel/layout execution extent support, independent of thread-count checks.
    if ((!decode() && seq % 16) || head_dim != kv_group || hidden % weight_group || ffn % weight_group)
      throw std::invalid_argument("initial prefill requires seq multiple of 16 and one KV group per head");
  }
};
