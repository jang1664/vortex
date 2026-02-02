"""
Vortex-accelerated Llama model
Replaces specific operations in transformers.models.llama with Vortex kernels
"""

import torch
from torch import nn
from transformers.models.llama.modeling_llama import (
    LlamaRMSNorm as OriginalLlamaRMSNorm,
    LlamaMLP as OriginalLlamaMLP,
    apply_rotary_pos_emb as original_apply_rotary_pos_emb,
    eager_attention_forward as original_eager_attention_forward,
    rotate_half,
    repeat_kv,
)
import vortex_torch as vx


class VortexLlamaRMSNorm(OriginalLlamaRMSNorm):
    """Vortex-accelerated RMSNorm"""
    
    def forward(self, hidden_states):
        input_dtype = hidden_states.dtype
        # Use Vortex RMSNorm kernel
        output = vx.rmsnorm(hidden_states.to(torch.float16), 
                           self.weight.to(torch.float16), 
                           eps=self.variance_epsilon)
        return output.to(input_dtype)


class VortexLlamaMLP(OriginalLlamaMLP):
    """Vortex-accelerated MLP (FFN block)"""
    
    def forward(self, x):
        # gate_proj and up_proj
        gate = self.gate_proj(x)
        up = self.up_proj(x)
        
        # SiLU activation using Vortex
        gate_act = vx.silu(gate.to(torch.float16)).to(x.dtype)
        
        # Element-wise multiply using Vortex
        intermediate = vx.elmul(gate_act.to(torch.float16), up.to(torch.float16)).to(x.dtype)
        
        # down_proj
        return self.down_proj(intermediate)


def vortex_apply_rotary_pos_emb(q, k, cos, sin, position_ids=None, unsqueeze_dim=1):
    """Vortex-accelerated RoPE"""
    # Prepare cos/sin for Vortex RoPE format
    # Vortex expects: [batch, seq_len, num_heads, head_dim]
    # Current format: [batch, seq_len, head_dim] or [batch, 1, seq_len, head_dim]
    
    cos = cos.unsqueeze(unsqueeze_dim)
    sin = sin.unsqueeze(unsqueeze_dim)
    
    # For now, use original implementation (can optimize later)
    # TODO: Adapt to Vortex RoPE kernel format
    q_embed = (q * cos) + (rotate_half(q) * sin)
    k_embed = (k * cos) + (rotate_half(k) * sin)
    return q_embed, k_embed


def vortex_eager_attention_forward(
    module,
    query,
    key,
    value,
    attention_mask,
    scaling,
    dropout=0.0,
    **kwargs,
):
    """Vortex-accelerated attention forward"""
    
    key_states = repeat_kv(key, module.num_key_value_groups)
    value_states = repeat_kv(value, module.num_key_value_groups)
    
    # Q @ K^T with scaling
    attn_weights = torch.matmul(query, key_states.transpose(2, 3)) * scaling
    
    if attention_mask is not None:
        causal_mask = attention_mask[:, :, :, : key_states.shape[-2]]
        attn_weights = attn_weights + causal_mask
    
    # Softmax using Vortex
    # attn_weights shape: [batch, num_heads, seq_q, seq_k]
    if attn_weights.dtype == torch.float16:
        attn_weights = vx.softmax(attn_weights, dim=-1, scale=1.0)
    else:
        attn_weights = nn.functional.softmax(attn_weights, dim=-1, dtype=torch.float32).to(query.dtype)
    
    attn_weights = nn.functional.dropout(attn_weights, p=dropout, training=module.training)
    attn_output = torch.matmul(attn_weights, value_states)
    attn_output = attn_output.transpose(1, 2).contiguous()
    
    return attn_output, attn_weights


def patch_transformers_llama():
    """
    Monkey-patch transformers.models.llama.modeling_llama to use Vortex kernels
    Call this function before loading any Llama model
    """
    import transformers.models.llama.modeling_llama as llama_module
    
    print("🔧 Patching Llama model with Vortex kernels...")
    
    # Replace RMSNorm
    llama_module.LlamaRMSNorm = VortexLlamaRMSNorm
    print("  ✓ RMSNorm -> VortexLlamaRMSNorm")
    
    # Replace MLP
    llama_module.LlamaMLP = VortexLlamaMLP
    print("  ✓ LlamaMLP -> VortexLlamaMLP")
    
    # Replace RoPE (optional for now)
    # llama_module.apply_rotary_pos_emb = vortex_apply_rotary_pos_emb
    # print("  ✓ apply_rotary_pos_emb -> vortex_apply_rotary_pos_emb")
    
    # Replace attention forward
    # llama_module.eager_attention_forward = vortex_eager_attention_forward
    # print("  ✓ eager_attention_forward -> vortex_eager_attention_forward")
    
    print("✅ Llama model patched with Vortex kernels!\n")


# # Convenience: Auto-patch on import (can be disabled)
# import os
# if os.environ.get('VORTEX_AUTO_PATCH', '1') == '1':
#     patch_transformers_llama()
