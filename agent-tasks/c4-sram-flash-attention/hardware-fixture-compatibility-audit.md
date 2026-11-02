# Nine-fixture compatibility contract

This is a read-only producer/consumer audit, not acceptance of the pending R5 image. All nine existing fixtures have the same old-rev8 fingerprint `d2a5780f434d824c6486b559005c3a6bb8173841d2d2c345570f4da39963033b`; their parameter-archive profiles also match the actual current TVM profile loader. The executed baseline check reports nine cases, no metadata errors, `new_image_pending=true`, and `metadata_comparison_pass=false`. No fixture, alias, shared source, running process or FPGA tool was changed/invoked.

The scope remains Llama3/Llama2 decode P16/C32, P128/C160, P128/C256 and Llama3 prefill 16/128/144, each legacy/resident/resident-fp32. This audit does not replace the full hardware matrix or its numerical checks.

## Fingerprints and acceptance paths

`tvm/python/tvm/support/vortex.py:237–284` loads **params.CONFIGS**, parses every `-D` macro and hashes JSON of sorted macro/value pairs. Macro order and identical duplicate definitions do not matter. The hash includes `GEMM_SRAM_FUSION` even though `_normalize_accelerator_profile` does not use that macro to change packing. Nondefault `vortex_layout_abi_version` and `vortex_gemm_abi_version` suffix the hash; omitted fields default to integer 2. Hence adding only the feature macro changes the fingerprint while leaving the normalized layout unchanged. This is an explanation for an expected difference, not proof of compatibility with any completed image.

The paths enforce different contracts:

| Path | Actual behavior |
|---|---|
| Raw C++ decoder (`decoder.cpp:38–60,82–112`) | Reads config.txt model/dimensions and decode stage/past/capacity, then tensors.tsv and exact file lengths. It never reads fixture.json, the parameter archive or its fingerprint. Device check compares cores and threads with compilation; warps are queried but not compared there. Thus a bad packing profile can get past startup. |
| Fixture generation (`reference.py:54–169`) | Uses the requested manifest target and fingerprint, `prepare_c4_parameter_archive`, then `C4ParameterArchive`; exports packed raw tensors plus CPU reference and hashes. Decode K/V use `plan_improve_layout`, `prepack_improve_weight`, `prepack_improve_qparam`. |
| TVM parameter archive (`parameter_archive.py:243–270`) | Requires exact expected fingerprint, schema/format/layer count/model metadata, file length and data hash. A physically benign feature-only fingerprint difference still rejects an old archive loaded with the new expected fingerprint. |
| CPU comparator (`reference.py:190–343`) | Uses fixture.json's original manifest to reconstruct packed-cache expectations. It does **not** compare that fingerprint to the actual loaded FPGA. It does not certify new-image provenance. Preserve this original producer manifest rather than relabeling the fixture. |
| TVM stage command (`reference.py:344+`) | Explicitly rejects fixture/profile fingerprint mismatch and uses the fingerprint-checked archive. It is separate from the C++ hardware matrix and does not support decode fixtures. |

Do not rewrite fixture fingerprints/manifests or weaken the archive checks. The C++ matrix consumes raw fixture tensors, so a separately documented packing/ABI proof can authorize their reuse without pretending that TVM's exact-profile contract has passed.

## Exact profile to preserve

`ImproveProfile.from_target`/`validate` in `tvm/python/tvm/relax/backend/vortex/layout.py:62–158` supplies these fields. Full JSON values and target attributes are in `logs/hardware_fixture_compatibility/baseline.json`.

| Fields | All-nine producer value |
|---|---|
| dma_mt, dma_nt, dma_kt | 128, 128, 128 |
| mxu_kt, mxu_nt; target mxu_col_tile | 16, 16; 16 |
| row_alignment, qparam_slot_alignment, tmem_alignment | 8 rows, 512 bytes, 64 bytes |
| num_dma_channels, num_tmem_banks, tmem_bank_size | 4, 8, 32768 bytes |
| accumulator_depth, job_entries, num_cores | 1024, 4, 1 |
| dimension_bits, address_bits, tile_counter_bits | 32, 64, 32 (address_bits is software ABI, not HBM physical width) |
| supported_qblocks; layout_abi_version, gemm_abi_version | 16/32/64/128; 2, 2 |
| dram_capacity_bytes | 18446744073709551615 (profile default, not measured board capacity) |
| target threads/warps, local_mem_size, xlen | 16/4, 1048576 bytes, 64 |
| target architecture/ABI/backend | rv64imaf_zfh / lp64f / improve |

Also preserve actual C4 external geometry from CONFIGS: MEM_ADDR_WIDTH and PLATFORM_MEMORY_ADDR_WIDTH=34, 32 memory banks, four HBM ports, PLATFORM_MEMORY_DATA_SIZE=64, merged/remapped/interleaved memory. The macro comparison catches fields omitted by the TVM normalization. Any unexplained difference requires review; matching normalized fields alone is insufficient.

Consumer anchors are `fpint_gemm_ffn_hw/layout.h` (64-byte transfer, 512-byte slots, eight-row stripe, quant-direction-dependent qparam payloads and TMEM allocation), its `common.h` (128 DMA dimensions, MXU macros, 44 descriptor registers/four entries), and decoder `op_args.h` (reuses existing operation wire structures). `DecoderDispatch` in `common.h`, `DecoderFlashArgs` in `flash_args.h`, `vx_flash_attention_args_t` and `vx_sram_fusion.h` must match the compiled host/kernel and frozen R5 controller/register interface. Fixtures contain tensors, not serialized DecoderDispatch/FlashArgs, so existing fixture bytes do not encode the newly added resident arguments. Rebuild host/kernel together against the selected image config; preserve generated VX_config.h and actual compile flags, ELF/vxbin and runtime hashes.

## Required completed-image evidence

1. Obtain the **actual completed R5** packaged manifest, xclbin SHA256/UUID, build `.config.stamp`, sources/config provenance and generated configuration. Bind these to the accepted R5 implementation/source receipt and loaded device UUID/BDF. An alias, old manifest, planned config or synthesized checkpoint is insufficient. Record actual achieved clock separately; the producer fingerprint is not a clock certificate.
2. Compare actual manifest `params.CONFIGS` against actual build stamp and `resolved_params.CONFIGS`; compare all normalized target/layout fields and show the complete macro delta. For the expected configuration, only adding `GEMM_SRAM_FUSION` is automatically classified here. Other deltas fail closed for review. ABI fields must remain v2 unless the producer/consumer physical layout is separately proved and fixtures regenerated through the normal producer where necessary.
3. Preserve manifest `id`, `sources.config_stamp`, `sources.sources_txt`, `sources.rtl_sources` and artifact provenance, then verify their referenced hashes against real files. `tools/vortex_binmgr.py:359–418` preserves an existing schema-v2 identity and original params while updating name/resolved_params; `read_manifest` validates identity syntax, not correspondence to loaded silicon. A binmgr build ID is neither the TVM packing fingerprint nor automatically an xclbin content hash. Do not infer image identity from either alone.
4. Before/after all nine cases, hash config.txt, tensors.tsv, fixture.json, parameter metadata, every catalogued tensor, initial_cache.npz where present, reference.npz and reference/output.bin. Check stored tensor hashes/lengths. This audit hashes metadata only; matrix bookends still owe tensor-content/image/binary linkage. Require the existing complete-output, CPU chain and same-input backend checks for all cases. A successful upload is not packing validation.

## Read-only comparison command

`compare_fixture_image_profile.py` reuses the actual TVM profile/layout loader and binmgr stamp parser. It writes JSON only to stdout. With no new-image arguments it audits all nine old producers and explicitly leaves the new-image gate pending. With new arguments it rejects old-manifest substitution, unexplained macro/normalized-profile changes and stamp/manifest inconsistencies. Its pass is **metadata comparison only**; artifact/loaded-image/ABI and tensor checks above remain required.

```bash
source /home/jaeyongjang/project.local/tvm/build/c4_nodsp_fsm_update_20261007_220215/environment.sh
PYTHONDONTWRITEBYTECODE=1 /home/jaeyongjang/.conda/envs/vortex/bin/python \
  /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/c4-sram-flash-attention/compare_fixture_image_profile.py \
  --fixtures /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build_c4_sram_fusion/fixtures/resident_attention \
  --new-manifest /ACTUAL_COMPLETED_R5_IMAGE/manifest.json \
  --new-config-stamp /ACTUAL_COMPLETED_R5_BUILD/.config.stamp
```

Paths are intentionally absolute because the TVM environment changes the working directory. No new image was supplied during this audit. The old-image negative check must exit 1 and is preserved separately from the baseline check.
