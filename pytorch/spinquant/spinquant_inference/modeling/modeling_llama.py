"""
Minimal LLaMA model for SpinQuant W4A16+KV4 inference.

Forward signatures:
  LlamaForCausalLM.forward(input_ids, position_ids=None, attention_mask=None, labels=None)
    -> (logits,)  or  (loss, logits)
"""
import math
from typing import Optional, Tuple

import torch
import torch.nn.functional as F
from torch import nn

from transformers.activations import ACT2FN
from transformers.modeling_rope_utils import ROPE_INIT_FUNCTIONS
from transformers.modeling_utils import PreTrainedModel
from transformers.models.llama.configuration_llama import LlamaConfig

# Primitive kernels: route to the Vortex C++ kernel on device, basic torch on CPU.
from ..kernels.rmsnorm import rmsnorm
from ..kernels.silu import silu
from ..kernels.rope import rotate_half, apply_rotary_pos_emb  # noqa: F401 (re-exported)


# ---------------------------------------------------------------------------
# Norms
# ---------------------------------------------------------------------------

class LlamaRMSNorm(nn.Module):
    def __init__(self, hidden_size: int, eps: float = 1e-6):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(hidden_size))
        self.variance_epsilon = eps

    def forward(self, hidden_states: torch.Tensor) -> torch.Tensor:
        return rmsnorm(hidden_states, self.weight, self.variance_epsilon)


# ---------------------------------------------------------------------------
# Rotary embeddings
# ---------------------------------------------------------------------------

class LlamaRotaryEmbedding(nn.Module):
    def __init__(self, config: LlamaConfig):
        super().__init__()
        rope_type = "default"
        if config.rope_scaling is not None:
            rope_type = config.rope_scaling.get("rope_type", config.rope_scaling.get("type", "default"))
        self.rope_type = rope_type
        self.config = config
        inv_freq, self.attention_scaling = ROPE_INIT_FUNCTIONS[rope_type](config, device=None)
        self.register_buffer("inv_freq", inv_freq, persistent=False)

    @torch.no_grad()
    def forward(self, x: torch.Tensor, position_ids: torch.LongTensor) -> Tuple[torch.Tensor, torch.Tensor]:
        inv_freq = self.inv_freq[None, :, None].float().expand(position_ids.shape[0], -1, 1)
        pos      = position_ids[:, None, :].float()
        with torch.autocast(device_type=x.device.type, enabled=False):
            freqs = (inv_freq @ pos).transpose(1, 2)
            emb   = torch.cat((freqs, freqs), dim=-1)
            cos   = emb.cos() * self.attention_scaling
            sin   = emb.sin() * self.attention_scaling
        return cos.to(dtype=x.dtype), sin.to(dtype=x.dtype)


# rotate_half / apply_rotary_pos_emb are provided by kernels/rope.py (imported
# above and re-exported here) so RoPE routes to the Vortex kernel on device.


# ---------------------------------------------------------------------------
# MLP
# ---------------------------------------------------------------------------

class LlamaMLP(nn.Module):
    def __init__(self, config: LlamaConfig):
        super().__init__()
        self.gate_proj = nn.Linear(config.hidden_size, config.intermediate_size, bias=config.mlp_bias)
        self.up_proj   = nn.Linear(config.hidden_size, config.intermediate_size, bias=config.mlp_bias)
        self.down_proj = nn.Linear(config.intermediate_size, config.hidden_size, bias=config.mlp_bias)
        self.act_fn    = ACT2FN[config.hidden_act]

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.down_proj(silu(self.gate_proj(x)) * self.up_proj(x))


# ---------------------------------------------------------------------------
# Attention
# ---------------------------------------------------------------------------

def repeat_kv(hidden_states: torch.Tensor, n_rep: int) -> torch.Tensor:
    if n_rep == 1:
        return hidden_states
    B, H, T, D = hidden_states.shape
    return (
        hidden_states[:, :, None, :, :]
        .expand(B, H, n_rep, T, D)
        .reshape(B, H * n_rep, T, D)
    )


class LlamaAttention(nn.Module):
    """
    Base attention module. Holds q/k/v/o projections and RoPE.
    Replaced at load time by LlamaQuantizedKVAttention.
    """

    def __init__(self, config: LlamaConfig, layer_idx: int):
        super().__init__()
        self.config    = config
        self.layer_idx = layer_idx
        self.head_dim  = getattr(config, "head_dim", config.hidden_size // config.num_attention_heads)
        self.num_heads    = config.num_attention_heads
        self.num_kv_heads = config.num_key_value_heads
        self.num_kv_groups = self.num_heads // self.num_kv_heads

        self.q_proj = nn.Linear(config.hidden_size, self.num_heads    * self.head_dim, bias=config.attention_bias)
        self.k_proj = nn.Linear(config.hidden_size, self.num_kv_heads * self.head_dim, bias=config.attention_bias)
        self.v_proj = nn.Linear(config.hidden_size, self.num_kv_heads * self.head_dim, bias=config.attention_bias)
        self.o_proj = nn.Linear(self.num_heads * self.head_dim, config.hidden_size,    bias=config.attention_bias)
        self.rotary_emb = LlamaRotaryEmbedding(config)

    def forward(
        self,
        hidden_states:       torch.Tensor,
        attention_mask:      Optional[torch.Tensor] = None,
        position_ids:        Optional[torch.LongTensor] = None,
        position_embeddings: Optional[Tuple[torch.Tensor, torch.Tensor]] = None,
    ) -> torch.Tensor:
        B, T, _ = hidden_states.shape

        q = self.q_proj(hidden_states).view(B, T, self.num_heads,    self.head_dim).transpose(1, 2)
        k = self.k_proj(hidden_states).view(B, T, self.num_kv_heads, self.head_dim).transpose(1, 2)
        v = self.v_proj(hidden_states).view(B, T, self.num_kv_heads, self.head_dim).transpose(1, 2)

        if position_embeddings is not None:
            cos, sin = position_embeddings
        else:
            cos, sin = self.rotary_emb(q, position_ids)
        q, k = apply_rotary_pos_emb(q, k, cos, sin)

        k = repeat_kv(k, self.num_kv_groups)
        v = repeat_kv(v, self.num_kv_groups)

        out = F.scaled_dot_product_attention(
            q, k, v,
            attn_mask=attention_mask,
            is_causal=(attention_mask is None and T > 1),
        )
        return self.o_proj(out.transpose(1, 2).reshape(B, T, -1))


# ---------------------------------------------------------------------------
# Decoder layer
# ---------------------------------------------------------------------------

class LlamaDecoderLayer(nn.Module):
    def __init__(self, config: LlamaConfig, layer_idx: int):
        super().__init__()
        self.self_attn              = LlamaAttention(config, layer_idx)
        self.mlp                    = LlamaMLP(config)
        self.input_layernorm        = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.post_attention_layernorm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def forward(
        self,
        hidden_states:       torch.Tensor,
        attention_mask:      Optional[torch.Tensor] = None,
        position_ids:        Optional[torch.LongTensor] = None,
        position_embeddings: Optional[Tuple[torch.Tensor, torch.Tensor]] = None,
    ) -> torch.Tensor:
        hidden_states = hidden_states + self.self_attn(
            self.input_layernorm(hidden_states),
            attention_mask=attention_mask,
            position_ids=position_ids,
            position_embeddings=position_embeddings,
        )
        hidden_states = hidden_states + self.mlp(self.post_attention_layernorm(hidden_states))
        return hidden_states


# ---------------------------------------------------------------------------
# Model backbone
# ---------------------------------------------------------------------------

class LlamaPreTrainedModel(PreTrainedModel):
    config_class       = LlamaConfig
    base_model_prefix  = "model"
    _no_split_modules  = ["LlamaDecoderLayer"]

    def _init_weights(self, module):
        std = self.config.initializer_range
        if isinstance(module, nn.Linear):
            module.weight.data.normal_(mean=0.0, std=std)
            if module.bias is not None:
                module.bias.data.zero_()
        elif isinstance(module, nn.Embedding):
            module.weight.data.normal_(mean=0.0, std=std)
            if module.padding_idx is not None:
                module.weight.data[module.padding_idx].zero_()


class LlamaModel(LlamaPreTrainedModel):
    def __init__(self, config: LlamaConfig):
        super().__init__(config)
        self.embed_tokens = nn.Embedding(config.vocab_size, config.hidden_size, config.pad_token_id)
        self.layers       = nn.ModuleList([LlamaDecoderLayer(config, i) for i in range(config.num_hidden_layers)])
        self.norm         = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.rotary_emb   = LlamaRotaryEmbedding(config)
        self.post_init()

    def get_input_embeddings(self):
        return self.embed_tokens

    def set_input_embeddings(self, value):
        self.embed_tokens = value

    def forward(
        self,
        input_ids:      torch.LongTensor,
        position_ids:   Optional[torch.LongTensor] = None,
        attention_mask: Optional[torch.Tensor]     = None,
    ) -> torch.Tensor:
        hidden_states = self.embed_tokens(input_ids)

        if position_ids is None:
            position_ids = torch.arange(input_ids.shape[1], device=input_ids.device).unsqueeze(0)

        position_embeddings = self.rotary_emb(hidden_states, position_ids)

        for layer in self.layers:
            hidden_states = layer(
                hidden_states,
                attention_mask=attention_mask,
                position_ids=position_ids,
                position_embeddings=position_embeddings,
            )

        return self.norm(hidden_states)


# ---------------------------------------------------------------------------
# Causal LM head
# ---------------------------------------------------------------------------

class LlamaForCausalLM(LlamaPreTrainedModel):
    _tied_weights_keys = ["lm_head.weight"]

    def __init__(self, config: LlamaConfig):
        super().__init__(config)
        self.model      = LlamaModel(config)
        self.vocab_size = config.vocab_size
        self.lm_head    = nn.Linear(config.hidden_size, config.vocab_size, bias=False)
        self.post_init()

    def get_input_embeddings(self):
        return self.model.embed_tokens

    def set_input_embeddings(self, value):
        self.model.embed_tokens = value

    def get_output_embeddings(self):
        return self.lm_head

    def set_output_embeddings(self, new_embeddings):
        self.lm_head = new_embeddings

    def forward(
        self,
        input_ids:      torch.LongTensor,
        position_ids:   Optional[torch.LongTensor] = None,
        attention_mask: Optional[torch.Tensor]     = None,
        labels:         Optional[torch.LongTensor] = None,
    ) -> Tuple:
        """
        Returns:
            (logits,)             when labels is None
            (loss, logits)        when labels is provided
        """
        hidden_states = self.model(input_ids, position_ids=position_ids, attention_mask=attention_mask)
        logits = self.lm_head(hidden_states)

        if labels is None:
            # Greedy/argmax sampling is dtype-invariant — keep logits in the model
            # dtype (fp16) and skip the full (1, T, vocab) fp32 upcast round-trip.
            return (logits,)

        logits = logits.float()
        loss = F.cross_entropy(
            logits[..., :-1, :].contiguous().view(-1, self.vocab_size),
            labels[..., 1:].contiguous().view(-1).to(logits.device),
        )
        return (loss, logits)
