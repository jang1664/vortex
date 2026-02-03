"""
Vortex-accelerated Llama model
Replaces specific operations in transformers.models.llama with Vortex kernels
"""
from typing import Callable, Optional
import torch
from torch import nn
from transformers.models.llama.modeling_llama import (
    LlamaRMSNorm as OriginalLlamaRMSNorm,
    LlamaMLP as OriginalLlamaMLP,
    LlamaAttention as OriginalLlamaAttention,
    LlamaRotaryEmbedding as OriginalLlamaRotaryEmbedding,
    apply_rotary_pos_emb as original_apply_rotary_pos_emb,
    eager_attention_forward as original_eager_attention_forward,
    rotate_half,
    repeat_kv,
)
from transformers.modeling_utils import ALL_ATTENTION_FUNCTIONS
from transformers.utils import TransformersKwargs
from transformers.processing_utils import Unpack
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

class VortexLlamaRotaryEmbedding(OriginalLlamaRotaryEmbedding):
    """Vortex-accelerated RoPE"""
    
    def forward(self, x, position_ids):
        ### TODO: Use Vortex RoPE kernel directly ###
        inv_freq_expanded = self.inv_freq[None, :, None].float().expand(position_ids.shape[0], -1, 1).to(x.device)
        position_ids_expanded = position_ids[:, None, :].float()

        device_type = x.device.type if isinstance(x.device.type, str) and x.device.type != "mps" else "cpu"
        with torch.autocast(device_type=device_type, enabled=False):  # Force float32
            freqs = (inv_freq_expanded.float() @ position_ids_expanded.float()).transpose(1, 2)
            emb = torch.cat((freqs, freqs), dim=-1)
            cos = emb.cos() * self.attention_scaling
            sin = emb.sin() * self.attention_scaling

        return cos.to(dtype=x.dtype), sin.to(dtype=x.dtype)
    
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
    module: nn.Module,
    query: torch.Tensor,
    key: torch.Tensor,
    value: torch.Tensor,
    attention_mask: Optional[torch.Tensor],
    scaling: float,
    dropout: float = 0.0,
    **kwargs: Unpack[TransformersKwargs],
):
    key_states = repeat_kv(key, module.num_key_value_groups)
    value_states = repeat_kv(value, module.num_key_value_groups)

    attn_weights = torch.matmul(query, key_states.transpose(2, 3)) * scaling
    if attention_mask is not None:
        causal_mask = attention_mask[:, :, :, : key_states.shape[-2]]
        attn_weights = attn_weights + causal_mask

    attn_weights = nn.functional.softmax(attn_weights, dim=-1, dtype=torch.float32).to(query.dtype)
    attn_weights = nn.functional.dropout(attn_weights, p=dropout, training=module.training)
    attn_output = torch.matmul(attn_weights, value_states)
    attn_output = attn_output.transpose(1, 2).contiguous()

    return attn_output, attn_weights

class VortexLlamaAttention(OriginalLlamaAttention):
    """Vortex-accelerated Attention"""
    
    def forward(
        self,
        hidden_states,
        position_embeddings,
        attention_mask,
        past_key_values,
        cache_position,
        **kwargs,
    ):
        input_shape = hidden_states.shape[:-1]
        hidden_shape = (*input_shape, -1, self.head_dim)
        
        query_states = self.q_proj(hidden_states).view(hidden_shape).transpose(1, 2)
        key_states = self.k_proj(hidden_states).view(hidden_shape).transpose(1, 2)
        value_states = self.v_proj(hidden_states).view(hidden_shape).transpose(1, 2)
        
        cos, sin = position_embeddings
        query_states, key_states = vortex_apply_rotary_pos_emb(query_states, key_states, cos, sin)
        
        if past_key_values is not None:
            # sin and cos are specific to RoPE models; cache_position needed for the static cache
            cache_kwargs = {"sin": sin, "cos": cos, "cache_position": cache_position}
            key_states, value_states = past_key_values.update(key_states, value_states, self.layer_idx, cache_kwargs)
        
        attention_interface: Callable = vortex_eager_attention_forward
        if self.config._attn_implementation != "eager":
            # attention_interface = ALL_ATTENTION_FUNCTIONS[self.config._attn_implementation]
            pass  # For now, only eager is implemented [TODO: add other implementations e.g. flash attention]

        attn_output, attn_weights = attention_interface(
            self,
            query_states,
            key_states,
            value_states,
            attention_mask,
            dropout=0.0 if not self.training else self.attention_dropout,
            scaling=self.scaling,
            **kwargs,
        )

        attn_output = attn_output.reshape(*input_shape, -1).contiguous()
        attn_output = self.o_proj(attn_output)
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
    
    # Replace RoPE Embedding   
    llama_module.LlamaRotaryEmbedding = VortexLlamaRotaryEmbedding
    print("  ✓ LlamaRotaryEmbedding -> VortexLlamaRotaryEmbedding")
    
    # Replace Attention
    llama_module.LlamaAttention = VortexLlamaAttention
    print("  ✓ LlamaAttention -> VortexLlamaAttention")
    
    # Replace MLP
    llama_module.LlamaMLP = VortexLlamaMLP
    print("  ✓ LlamaMLP -> VortexLlamaMLP")
    
    # Replace RoPE (optional for now)
    # llama_module.apply_rotary_pos_emb = vortex_apply_rotary_pos_emb
    # print("  ✓ apply_rotary_pos_emb -> vortex_apply_rotary_pos_emb")
    
    
    print("✅ Llama model patched with Vortex kernels!\n")


# # Convenience: Auto-patch on import (can be disabled)
# import os
# if os.environ.get('VORTEX_AUTO_PATCH', '1') == '1':
#     patch_transformers_llama()
