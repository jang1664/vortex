"""Stable semantic checkpoint identifiers for the single-layer graph."""

from dataclasses import dataclass

STAGE_NAMES = (
    "input_norm",
    "q_proj",
    "k_proj",
    "v_proj",
    "q_rope",
    "k_rope",
    "q_r3",
    "k_r3",
    "k_quant",
    "v_quant",
    "qk",
    "scaled_masked_scores",
    "softmax",
    "pv",
    "head_concat",
    "o_proj",
    "attn_residual",
    "post_attn_norm",
    "gate_proj",
    "up_proj",
    "silu",
    "mlp_mul",
    "r4",
    "down_proj",
    "final_residual",
)

STAGE_INDEX = {name: index for index, name in enumerate(STAGE_NAMES)}


def validate_stop_stage(stage: str) -> int:
    try:
        return STAGE_INDEX[stage]
    except KeyError as error:
        raise ValueError(
            f"unknown stop stage {stage!r}; expected one of {', '.join(STAGE_NAMES)}"
        ) from error


@dataclass(frozen=True)
class DecodeStopPoint:
    """A semantic stop point within an ordered one-token decode step."""

    step: int
    stage: str

    def validate(self, *, decode_steps: int) -> int:
        if self.step < 0 or self.step >= decode_steps:
            raise ValueError(
                f"decode step {self.step} is outside [0, {decode_steps})"
            )
        return validate_stop_stage(self.stage)
