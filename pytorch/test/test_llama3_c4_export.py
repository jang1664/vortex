from __future__ import annotations

import math
import sys
from pathlib import Path

import pytest
import torch


SPINQUANT_ROOT = Path(__file__).resolve().parents[1] / "spinquant"
sys.path.insert(0, str(SPINQUANT_ROOT))

from spinquant_inference.layer_accuracy.artifacts import (  # noqa: E402
    create_random_case,
    create_random_decode_case,
)
from spinquant_inference.layer_accuracy.backends import TorchBackend  # noqa: E402
from spinquant_inference.layer_accuracy.graph import (  # noqa: E402
    DecodeExecutor,
    LayerExecutor,
)
from spinquant_inference.layer_accuracy.specs import (  # noqa: E402
    ALL_ASYMMETRIC_WKV4,
    DecodeConfig,
    LayerConfig,
)
from spinquant_inference.llama3_c4_export import (  # noqa: E402
    Llama3ExportConfig,
    Llama3LayerDecode,
    Llama3LayerPrefill,
    Llama3LayerPrefillCheckpoints,
    Llama3FinalHead,
    Llama3ModelDecode,
    Llama3ModelPrefill,
    Llama3StackDecode,
    Llama3StackPrefill,
    Llama3TokenEmbedding,
    embedding_parameter_shapes,
    exported_graph_has_physical_c4_ops,
    final_head_parameter_shapes,
    full_model_parameter_shapes,
    make_meta_parameters,
    stack_parameter_shapes,
    layer_checkpoint_names,
)
from spinquant_inference.utils.hadamard_utils import get_hadK  # noqa: E402


def _tiny_layer(*, batch: int, sequence: int) -> LayerConfig:
    return LayerConfig(
        model="test-llama3-gqa",
        hidden_size=32,
        intermediate_size=64,
        num_attention_heads=4,
        num_key_value_heads=2,
        head_dim=8,
        batch_size=batch,
        sequence_length=sequence,
        weight_group_size=4,
        kv_group_size=8,
        rms_norm_eps=1e-5,
        rope_theta=500000.0,
        quantization_policy=ALL_ASYMMETRIC_WKV4,
    )


def _export_config(
    layer: LayerConfig, *, query: int, capacity: int
) -> Llama3ExportConfig:
    return Llama3ExportConfig(
        batch_size=layer.batch_size,
        query_length=query,
        cache_capacity=capacity,
        hidden_size=layer.hidden_size,
        intermediate_size=layer.intermediate_size,
        num_attention_heads=layer.num_attention_heads,
        num_key_value_heads=layer.num_key_value_heads,
        head_dim=layer.head_dim,
        rms_norm_eps=layer.rms_norm_eps,
        rope_theta=layer.rope_theta,
        weight_group_size=layer.weight_group_size,
        kv_group_size=layer.kv_group_size,
    )


def _parameters(tensors: dict[str, torch.Tensor]) -> dict[str, torch.Tensor]:
    result = {
        name: tensor
        for name, tensor in tensors.items()
        if name.endswith(".weight")
        or name.endswith(".scales")
        or name.endswith(".zeros")
    }
    result.update(
        {
            name: tensor.view(torch.uint8)
            for name, tensor in tensors.items()
            if name.endswith(".qweight")
        }
    )
    return result


def _stack_parameters(
    config: Llama3ExportConfig, num_layers: int
) -> dict[str, torch.Tensor]:
    generator = torch.Generator().manual_seed(120 + num_layers)
    result = {}
    for name, (shape, dtype) in stack_parameter_shapes(config, num_layers).items():
        if dtype == torch.uint8:
            result[name] = torch.randint(
                0, 256, shape, dtype=dtype, generator=generator
            )
        elif dtype == torch.int16:
            result[name] = torch.randint(-2, 3, shape, dtype=dtype, generator=generator)
        elif name.endswith("norm.weight"):
            result[name] = torch.ones(shape, dtype=dtype)
        else:
            result[name] = torch.full(shape, 1.0 / 256.0, dtype=dtype)
    return result


def _select_layer_parameters(
    parameters: dict[str, torch.Tensor], layer_index: int
) -> dict[str, torch.Tensor]:
    prefix = f"layers.{layer_index}."
    return {
        name[len(prefix) :]: tensor
        for name, tensor in parameters.items()
        if name.startswith(prefix)
    }


def _full_model_parameters(
    config: Llama3ExportConfig, num_layers: int
) -> dict[str, torch.Tensor]:
    parameters = _stack_parameters(config, num_layers)
    generator = torch.Generator().manual_seed(140 + num_layers)
    for name, (shape, dtype) in full_model_parameter_shapes(config, num_layers).items():
        if name in parameters:
            continue
        if dtype == torch.uint8:
            parameters[name] = torch.randint(
                0, 256, shape, dtype=dtype, generator=generator
            )
        elif dtype == torch.int16:
            parameters[name] = torch.randint(
                -2, 3, shape, dtype=dtype, generator=generator
            )
        elif name.endswith("norm.weight"):
            parameters[name] = torch.ones(shape, dtype=dtype)
        else:
            parameters[name] = (
                torch.randn(shape, generator=generator) * (1.0 / 256.0)
            ).to(dtype)
    return parameters


def _assert_cache_suffix_zero(outputs: tuple[torch.Tensor, ...], length: int) -> None:
    for tensor in outputs[1:7]:
        torch.testing.assert_close(
            tensor[..., length:, :],
            torch.zeros_like(tensor[..., length:, :]),
            rtol=0,
            atol=0,
        )


def _butterfly_hadamard_reference(
    hidden: torch.Tensor, base: torch.Tensor, base_size: int
) -> torch.Tensor:
    width = hidden.shape[-1]
    work = hidden.float().reshape(-1, width, 1)
    while work.shape[1] > base_size:
        pairs = work.reshape(work.shape[0], work.shape[1] // 2, 2, work.shape[2])
        work = torch.cat(
            (
                pairs[:, :, 0, :] + pairs[:, :, 1, :],
                pairs[:, :, 0, :] - pairs[:, :, 1, :],
            ),
            dim=-1,
        )
    if base_size > 1:
        work = torch.matmul(base.reshape(1, base_size, base_size), work)
    return (work.reshape(hidden.shape) / math.sqrt(width)).to(hidden.dtype)


def test_prefill_matches_backend_neutral_all_asymmetric_reference() -> None:
    layer = _tiny_layer(batch=2, sequence=3)
    case = create_random_case(layer, seed=101)
    reference = LayerExecutor(TorchBackend("cpu")).run(case)
    module = Llama3LayerPrefill(_export_config(layer, query=3, capacity=8))
    arguments = (
        case.tensors["input"],
        case.tensors["position_ids"],
        _parameters(case.tensors),
    )
    eager = module(*arguments)

    torch.testing.assert_close(
        eager[0], reference.captures["final_residual"], rtol=5e-3, atol=5e-3
    )
    for offset, stage in ((1, "k_quant"), (4, "v_quant")):
        torch.testing.assert_close(
            eager[offset][..., :3, :].view(torch.int8),
            reference.auxiliary_captures[f"{stage}.packed"].view(torch.int8),
            rtol=0,
            atol=0,
        )
        torch.testing.assert_close(
            eager[offset + 1][..., :3, :],
            reference.auxiliary_captures[f"{stage}.scale"],
            rtol=0,
            atol=0,
        )
        torch.testing.assert_close(
            eager[offset + 2][..., :3, :],
            reference.auxiliary_captures[f"{stage}.zero"],
            rtol=0,
            atol=0,
        )
    _assert_cache_suffix_zero(eager, 3)
    assert eager[-1].item() == 3

    exported = torch.export.export(module, arguments, strict=True)
    assert not exported_graph_has_physical_c4_ops(exported)
    graph = str(exported.graph_module.graph)
    assert graph.count("torch.ops.vortex.mm_w4a16.default") == 9
    assert graph.count("torch.ops.vortex.causal_softmax.default") == 1
    assert graph.count("torch.ops.vortex.quantize_int4.default") == 2
    assert graph.count("torch.ops.vortex.kv_cache_update.default") == 6
    exported_outputs = exported.module()(*arguments)
    for expected, actual in zip(eager, exported_outputs):
        torch.testing.assert_close(actual, expected, rtol=0, atol=0)


def test_prefill_checkpoint_boundary_preserves_production_outputs() -> None:
    layer = _tiny_layer(batch=1, sequence=1)
    case = create_random_case(layer, seed=151)
    config = _export_config(layer, query=1, capacity=8)
    arguments = (
        case.tensors["input"],
        case.tensors["position_ids"],
        _parameters(case.tensors),
    )
    production = Llama3LayerPrefill(config)(*arguments)
    checkpointed = Llama3LayerPrefillCheckpoints(config)(*arguments)

    checkpoint_names = layer_checkpoint_names(config)
    assert checkpoint_names[-1] == "output"
    assert len(checkpointed) == len(checkpoint_names) + 7
    torch.testing.assert_close(
        checkpointed[len(checkpoint_names) - 1], production[0], rtol=0, atol=0
    )
    for actual, expected in zip(checkpointed[len(checkpoint_names) :], production[1:]):
        torch.testing.assert_close(actual, expected, rtol=0, atol=0)


@pytest.mark.parametrize("width", (128, 14336))
def test_logical_mixed_radix_hadamard_matches_butterfly(width: int) -> None:
    base, base_size = get_hadK(width)
    if base is None:
        base = torch.ones((1, 1), dtype=torch.float32)
    hidden = torch.randn((2, width), dtype=torch.float16)
    expected = _butterfly_hadamard_reference(hidden, base.float(), base_size)
    actual = torch.ops.vortex.hadamard(hidden, base.float(), base_size)
    absolute_error = (actual.float() - expected.float()).abs()
    small = expected.float().abs() < 1.0
    small_max_absolute_error = (
        absolute_error[small].max().item() if torch.any(small) else 0.0
    )
    relative_l2 = torch.linalg.vector_norm(
        actual.float() - expected.float()
    ) / torch.linalg.vector_norm(expected.float()).clamp_min(1e-12)
    cosine = torch.nn.functional.cosine_similarity(
        actual.float().flatten(), expected.float().flatten(), dim=0
    )
    assert small_max_absolute_error <= 5e-4
    assert relative_l2.item() <= 1e-5
    assert cosine.item() >= 0.99999


@pytest.mark.parametrize("batch,prompt,capacity", [(1, 1, 8), (2, 3, 8)])
def test_prefill_then_three_decode_steps_reuse_functional_cache(
    batch: int, prompt: int, capacity: int
) -> None:
    layer = _tiny_layer(batch=batch, sequence=prompt + 3)
    case = create_random_decode_case(
        DecodeConfig(layer, prompt, 3, capacity), seed=107 + batch + prompt
    )
    parameters = _parameters(case.tensors)
    reference = DecodeExecutor(TorchBackend("cpu")).run(case)
    prefill_module = Llama3LayerPrefill(
        _export_config(layer, query=prompt, capacity=capacity)
    )
    decode_module = Llama3LayerDecode(_export_config(layer, query=1, capacity=capacity))
    state = prefill_module(
        case.tensors["prompt_input"],
        case.tensors["prompt_position_ids"],
        parameters,
    )
    torch.testing.assert_close(
        state[0],
        reference.prefill.captures["final_residual"],
        rtol=5e-3,
        atol=5e-3,
    )
    addresses = tuple(tensor.data_ptr() for tensor in state[1:7])
    previous = tuple(tensor.clone() for tensor in state[1:7])

    exported_decode = torch.export.export(
        decode_module,
        (
            case.tensors["decode_inputs"][0],
            case.tensors["decode_position_ids"][0],
            parameters,
            *state[1:7],
            state[7],
        ),
        strict=True,
    )
    assert not exported_graph_has_physical_c4_ops(exported_decode)
    graph = str(exported_decode.graph_module.graph)
    assert graph.count("torch.ops.vortex.kv_cache_update_dynamic.default") == 2

    for step in range(3):
        state = decode_module(
            case.tensors["decode_inputs"][step],
            case.tensors["decode_position_ids"][step],
            parameters,
            *state[1:7],
            state[7],
        )
        torch.testing.assert_close(
            state[0],
            reference.steps[step].captures["final_residual"],
            rtol=5e-3,
            atol=5e-3,
        )
        expected_length = prompt + step + 1
        assert state[7].item() == expected_length
        for old, new in zip(previous, state[1:7]):
            torch.testing.assert_close(
                new[..., : expected_length - 1, :],
                old[..., : expected_length - 1, :],
                rtol=0,
                atol=0,
            )
        _assert_cache_suffix_zero(state, expected_length)
        previous = tuple(tensor.clone() for tensor in state[1:7])

    assert addresses != tuple(tensor.data_ptr() for tensor in state[1:7])
    if batch == 2:
        assert not torch.equal(state[0][0], state[0][1])


@pytest.mark.parametrize("cache_length", [-1, 8])
def test_decode_rejects_cache_length_outside_capacity(cache_length: int) -> None:
    layer = _tiny_layer(batch=1, sequence=1)
    config = _export_config(layer, query=1, capacity=8)
    module = Llama3LayerDecode(config)
    parameters = {
        name: torch.empty_like(value, device="cpu")
        for name, value in make_meta_parameters(config).items()
    }
    packed = torch.zeros((1, 2, 8, 4), dtype=torch.uint8)
    scale = torch.zeros((1, 2, 8, 1), dtype=torch.float16)
    zero = torch.zeros((1, 2, 8, 1), dtype=torch.int16)
    arguments = (
        torch.zeros((1, 1, 32), dtype=torch.float16),
        torch.zeros((1, 1), dtype=torch.int64),
        parameters,
        packed,
        scale,
        zero,
        packed,
        scale,
        zero,
        torch.tensor(cache_length, dtype=torch.int64),
    )

    with pytest.raises(RuntimeError, match="allocated KV cache capacity"):
        module(*arguments)


@pytest.mark.parametrize("num_layers", [2, 4])
def test_decoder_stack_matches_sequential_layers_and_exports(num_layers: int) -> None:
    config = _export_config(_tiny_layer(batch=1, sequence=1), query=1, capacity=8)
    parameters = _stack_parameters(config, num_layers)
    hidden = torch.full((1, 1, config.hidden_size), 1.0 / 64.0, dtype=torch.float16)
    positions = torch.zeros((1, 1), dtype=torch.int64)

    expected_states = []
    expected_hidden = hidden
    for layer_index in range(num_layers):
        state = Llama3LayerPrefill(config)(
            expected_hidden,
            positions,
            _select_layer_parameters(parameters, layer_index),
        )
        expected_hidden = state[0]
        expected_states.append(state)
    expected_prefill = (
        expected_hidden,
        *(
            torch.stack([state[index] for state in expected_states])
            for index in range(1, 7)
        ),
        torch.stack([state[7] for state in expected_states]),
    )
    prefill = Llama3StackPrefill(config, num_layers)
    actual_prefill = prefill(hidden, positions, parameters)
    for actual, expected in zip(actual_prefill, expected_prefill):
        torch.testing.assert_close(actual, expected, rtol=0, atol=0)
    assert actual_prefill[1].shape[:2] == (num_layers, config.batch_size)
    assert actual_prefill[7].tolist() == [1] * num_layers

    exported_prefill = torch.export.export(
        prefill, (hidden, positions, parameters), strict=True
    )
    assert not exported_graph_has_physical_c4_ops(exported_prefill)

    decode_hidden = torch.full_like(hidden, -1.0 / 128.0)
    decode_positions = torch.ones_like(positions)
    expected_states = []
    expected_hidden = decode_hidden
    for layer_index in range(num_layers):
        state = Llama3LayerDecode(config)(
            expected_hidden,
            decode_positions,
            _select_layer_parameters(parameters, layer_index),
            *(tensor[layer_index] for tensor in actual_prefill[1:7]),
            actual_prefill[7][layer_index],
        )
        expected_hidden = state[0]
        expected_states.append(state)
    expected_decode = (
        expected_hidden,
        *(
            torch.stack([state[index] for state in expected_states])
            for index in range(1, 7)
        ),
        torch.stack([state[7] for state in expected_states]),
    )
    decode = Llama3StackDecode(config, num_layers)
    actual_decode = decode(
        decode_hidden,
        decode_positions,
        parameters,
        *actual_prefill[1:],
    )
    for actual, expected in zip(actual_decode, expected_decode):
        torch.testing.assert_close(actual, expected, rtol=0, atol=0)
    assert actual_decode[7].tolist() == [2] * num_layers

    exported_decode = torch.export.export(
        decode,
        (decode_hidden, decode_positions, parameters, *actual_prefill[1:]),
        strict=True,
    )
    assert not exported_graph_has_physical_c4_ops(exported_decode)


def test_real_llama3_stack_parameter_indexing_has_32_distinct_layers() -> None:
    config = Llama3ExportConfig(batch_size=1, query_length=1, cache_capacity=8)
    shapes = stack_parameter_shapes(config, 32)
    per_layer = len(stack_parameter_shapes(config, 1))
    assert len(shapes) == 32 * per_layer
    assert "layers.0.q_proj.qweight" in shapes
    assert "layers.31.down_proj.zeros" in shapes
    layer_zero = {
        name.removeprefix("layers.0.")
        for name in shapes
        if name.startswith("layers.0.")
    }
    layer_last = {
        name.removeprefix("layers.31.")
        for name in shapes
        if name.startswith("layers.31.")
    }
    assert layer_zero == layer_last


def test_full_model_boundary_prefill_then_three_decode_steps_exports() -> None:
    num_layers = 2
    config = Llama3ExportConfig(
        batch_size=1,
        query_length=1,
        cache_capacity=8,
        hidden_size=128,
        intermediate_size=128,
        num_attention_heads=4,
        num_key_value_heads=2,
        head_dim=32,
        weight_group_size=32,
        kv_group_size=32,
        vocabulary_size=64,
    )
    parameters = _full_model_parameters(config, num_layers)
    token_ids = torch.tensor([[3]], dtype=torch.int64)
    positions = torch.zeros((1, 1), dtype=torch.int64)
    prefill = Llama3ModelPrefill(config, num_layers)
    state = prefill(token_ids, positions, parameters)
    assert state[0].shape == (1, 1, config.vocabulary_size)
    assert state[1].shape == (1, 1, config.hidden_size)
    assert state[-1].tolist() == [1, 1]
    prefill_export = torch.export.export(
        prefill, (token_ids, positions, parameters), strict=True
    )
    assert not exported_graph_has_physical_c4_ops(prefill_export)

    decode = Llama3ModelDecode(config, num_layers)
    for step in range(3):
        token_ids = torch.tensor([[4 + step]], dtype=torch.int64)
        positions = torch.tensor([[1 + step]], dtype=torch.int64)
        state = decode(token_ids, positions, parameters, *state[2:])
        assert state[0].shape == (1, 1, config.vocabulary_size)
        assert state[-1].tolist() == [2 + step, 2 + step]
    decode_export = torch.export.export(
        decode,
        (token_ids, positions, parameters, *state[2:]),
        strict=True,
    )
    assert not exported_graph_has_physical_c4_ops(decode_export)


def test_partitioned_model_boundaries_match_full_model_helpers() -> None:
    config = Llama3ExportConfig(
        batch_size=1,
        query_length=2,
        cache_capacity=8,
        hidden_size=128,
        intermediate_size=128,
        num_attention_heads=4,
        num_key_value_heads=2,
        head_dim=32,
        weight_group_size=32,
        kv_group_size=32,
        vocabulary_size=64,
    )
    parameters = _full_model_parameters(config, 2)
    token_ids = torch.tensor([[3, 7]], dtype=torch.int64)
    embedding_parameters = {
        name: parameters[name] for name in embedding_parameter_shapes(config)
    }
    head_parameters = {
        name: parameters[name] for name in final_head_parameter_shapes(config)
    }

    embedding = Llama3TokenEmbedding()
    (hidden,) = embedding(token_ids, embedding_parameters)
    torch.testing.assert_close(
        hidden,
        torch.nn.functional.embedding(token_ids, parameters["token_embedding.weight"]),
        rtol=0,
        atol=0,
    )
    embedding_export = torch.export.export(
        embedding, (token_ids, embedding_parameters), strict=True
    )
    assert not exported_graph_has_physical_c4_ops(embedding_export)

    head = Llama3FinalHead(config)
    logits, normalized = head(hidden, head_parameters)
    model = Llama3ModelPrefill(config, 2)
    expected_logits, expected_normalized = model._finalize(hidden, parameters)
    torch.testing.assert_close(logits, expected_logits, rtol=0, atol=0)
    torch.testing.assert_close(normalized, expected_normalized, rtol=0, atol=0)
    head_export = torch.export.export(head, (hidden, head_parameters), strict=True)
    assert not exported_graph_has_physical_c4_ops(head_export)
    assert (
        str(head_export.graph_module.graph).count("torch.ops.vortex.mm_w4a16.default")
        == 1
    )


@pytest.mark.parametrize("batch,prompt", [(1, 1), (1, 7), (2, 1), (2, 7)])
def test_real_llama3_partitioned_boundaries_export_on_meta(
    batch: int, prompt: int
) -> None:
    config = Llama3ExportConfig(batch, prompt, max(prompt + 3, 8))
    token_ids = torch.empty((batch, prompt), dtype=torch.int64, device="meta")
    embedding_parameters = {
        name: torch.empty(shape, dtype=dtype, device="meta")
        for name, (shape, dtype) in embedding_parameter_shapes(config).items()
    }
    embedding_export = torch.export.export(
        Llama3TokenEmbedding().to("meta"),
        (token_ids, embedding_parameters),
        strict=True,
    )
    assert not exported_graph_has_physical_c4_ops(embedding_export)

    hidden = torch.empty(
        (batch, prompt, config.hidden_size), dtype=torch.float16, device="meta"
    )
    head_parameters = {
        name: torch.empty(shape, dtype=dtype, device="meta")
        for name, (shape, dtype) in final_head_parameter_shapes(config).items()
    }
    head_export = torch.export.export(
        Llama3FinalHead(config).to("meta"),
        (hidden, head_parameters),
        strict=True,
    )
    assert not exported_graph_has_physical_c4_ops(head_export)


@pytest.mark.parametrize(
    "batch,prompt,capacity",
    [(1, 1, 8), (1, 7, 16), (2, 1, 8), (2, 7, 16)],
)
def test_real_llama3_geometry_exports_s1_s4_on_meta(
    batch: int, prompt: int, capacity: int
) -> None:
    prefill_config = Llama3ExportConfig(batch, prompt, capacity)
    prefill = Llama3LayerPrefill(prefill_config).to("meta")
    parameters = make_meta_parameters(prefill_config)
    hidden = torch.empty((batch, prompt, 4096), dtype=torch.float16, device="meta")
    positions = torch.empty((batch, prompt), dtype=torch.int64, device="meta")
    exported_prefill = torch.export.export(
        prefill, (hidden, positions, parameters), strict=True
    )
    assert not exported_graph_has_physical_c4_ops(exported_prefill)

    decode_config = Llama3ExportConfig(batch, 1, capacity)
    decode = Llama3LayerDecode(decode_config).to("meta")
    decode_parameters = make_meta_parameters(decode_config)
    packed = torch.empty((batch, 8, capacity, 64), dtype=torch.uint8, device="meta")
    scale = torch.empty((batch, 8, capacity, 1), dtype=torch.float16, device="meta")
    zero = torch.empty((batch, 8, capacity, 1), dtype=torch.int16, device="meta")
    exported_decode = torch.export.export(
        decode,
        (
            torch.empty((batch, 1, 4096), dtype=torch.float16, device="meta"),
            torch.empty((batch, 1), dtype=torch.int64, device="meta"),
            decode_parameters,
            packed,
            scale,
            zero,
            packed,
            scale,
            zero,
            torch.empty((), dtype=torch.int64, device="meta"),
        ),
        strict=True,
    )
    assert not exported_graph_has_physical_c4_ops(exported_decode)
