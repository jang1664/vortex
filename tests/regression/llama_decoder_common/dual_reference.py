"""Compare saved decoder output with independent IEEE and known-IP references.

No FPGA is needed. Both references start from fixture inputs, weights and initial
KV cache; neither consumes device intermediates. Existing verification files and
fixture references are preserved. Only the characterized MXU QROW half multiplier
FTZ policy is accepted; custom converter defects are deliberately excluded.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import torch

import reference as common

base = common.base


def xilinx_half_mul(lhs, rhs):
    """Native-half latency1 IP: input FTZ, normal-significand RNE, output FTZ.

    The boundary rounds at 11-bit normal precision before flushing an exponent
    underflow. It is not equivalent to first rounding into IEEE subnormals.
    """
    a, b = lhs.double(), rhs.double()
    a = torch.where(a.abs() < 2**-14, torch.copysign(torch.zeros_like(a), a), a)
    b = torch.where(b.abs() < 2**-14, torch.copysign(torch.zeros_like(b), b), b)
    product = a * b
    rounded = product.half()
    return torch.where(product.abs() < 2**-14 - 2**-26,
                       torch.copysign(torch.zeros_like(rounded), rounded), rounded)


class KnownIPAttention:
    def _attention_checkpoints(self, query, key_cache, value_cache,
                               valid_length, position_ids):
        scores, masked, probabilities, context = super()._attention_checkpoints(
            query, key_cache, value_cache, valid_length, position_ids)
        if self.attention_compute == 'w4':
            cfg = self.config
            packed, scale, zero = value_cache
            shape = [cfg.batch_size, cfg.num_key_value_heads,
                     cfg.cache_capacity, cfg.head_dim]
            weight = base._unpack_signed_int4(packed, shape, 3).float() - zero.float()
            # PV QDIR=1 scales each probability in FP16 before the INT4 dot.
            scaled = xilinx_half_mul(
                probabilities, scale.squeeze(-1).unsqueeze(2).unsqueeze(2))
            context = (scaled.float() @ weight.unsqueeze(2)).half().reshape(
                cfg.batch_size, cfg.num_attention_heads, query.shape[-2], cfg.head_dim)
        return scores, masked, probabilities, context


def compare(args):
    meta = json.loads((args.fixture / 'fixture.json').read_text())
    candidate = meta.get('candidate', 'C4')
    if candidate not in ('C1', 'C2', 'C3', 'C4'):
        raise ValueError(f'unsupported candidate: {candidate}')
    if meta.get('decoder_stage') != 'decode':
        raise ValueError('dual-reference comparison currently supports decode fixtures only')
    cfg = base.Llama3ExportConfig(**meta['config'])
    backend_candidate = 'C3' if candidate == 'C4' else candidate
    model = common.model_for(cfg, backend_candidate, decode=True)
    params = common.parameters_for(cfg, np.load(args.fixture / 'canonical.npz'), backend_candidate)
    hidden = torch.from_numpy(np.fromfile(args.fixture / 'tensors/hidden.bin', dtype='float16')
                              .reshape(cfg.batch_size, cfg.query_length, cfg.hidden_size))
    past = meta['past_kv_len']
    positions = (torch.arange(cfg.query_length) + past).expand(cfg.batch_size, -1)
    initial = np.load(args.fixture / 'initial_cache.npz')
    caches = [torch.from_numpy(initial[f'cache_{i}'].copy()) for i in range(6)]
    inputs = (hidden, positions, params, *caches, torch.tensor(past))
    expected_elements = cfg.batch_size * cfg.query_length * cfg.hidden_size
    actual = np.fromfile(args.output / 'output.bin', dtype='float16')
    if actual.size != expected_elements:
        raise ValueError('final output shape mismatch')
    names = base.layer_checkpoint_names(cfg)
    output_index = names.index('output')
    with torch.inference_mode():
        ieee = model(*inputs)[output_index].numpy()
        # Verify that the standard reference is unchanged before adding a mode.
        saved = np.load(args.fixture / 'reference.npz')['output']
        if not np.array_equal(ieee.view('uint16'), saved.reshape(ieee.shape).view('uint16')):
            raise ValueError('IEEE replay differs from fixture reference; regenerate/audit fixture first')
        ip_type = type('KnownIPDecoder', (KnownIPAttention, type(model)), {})
        ip_model = ip_type(cfg, linear_compute=model.linear_compute,
                           attention_compute=model.attention_compute)
        ip = ip_model(*inputs)[output_index].numpy()
    actual = actual.reshape(ieee.shape)
    results = {}
    for mode, expected in (('ieee', ieee), ('ip', ip)):
        metrics = base.hybrid_metrics(actual, expected, base.OUTPUT_THRESHOLDS,
                                      name=f'{mode} final output', enforce=False)
        metrics['max_absolute_error'] = float(np.max(np.abs(actual.astype('float64') - expected.astype('float64'))))
        results[mode] = metrics
        print(mode.upper(), 'PASS' if metrics['pass'] else 'FAIL',
              'relative_l2', metrics['relative_l2'], flush=True)
    result = dict(candidate=candidate, fixture=str(args.fixture.resolve()),
                  reference_scope='independent decode step from fixture and initial cache',
                  ieee_replay_bit_exact=True, references=results,
                  accepted_ip_policy='MXU QROW native-half latency1 multiplier input/output FTZ only',
                  excluded_defects=['TCU subnormal input x4', 'MXU output converter missing hidden bit'],
                  applicable_ip_adjustment=candidate in ('C3', 'C4'),
                  thresholds=base.OUTPUT_THRESHOLDS, selected_gate=args.gate,
                  selected_gate_pass=bool(results[args.gate]['pass']))
    (args.output / 'dual_reference.json').write_text(json.dumps(result, indent=2) + '\n')
    np.savez(args.output / 'dual_reference_outputs.npz', ieee=ieee, ip=ip)
    return 0 if result['selected_gate_pass'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='existing decoder dump directory')
    parser.add_argument('--gate', choices=('ieee', 'ip'), default='ieee',
                        help='exit-status criterion; both results are always recorded')
    args = parser.parse_args()
    torch.set_num_threads(4)
    raise SystemExit(compare(args))


if __name__ == '__main__':
    main()
