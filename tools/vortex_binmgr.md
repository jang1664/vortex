# Vortex FPGA bin manager

Run `python3 tools/vortex_binmgr.py --dir BUILD_DIRECTORY` to preview a move.
Add `--apply` to execute it. Relative input paths are relative to the current
working directory; reported destinations are absolute. `--dir` is repeatable.

The default archive is `/opt/vortex_fpga_bins`. Builds go directly under its
`baseline` or `fpint` leaf. Passing a leaf as `--root` uses that leaf directly.
Without `--dir`, scan the root and its two leaves, without descending into
build internals. The existing fpint classification rules remain in use.

## Naming and metadata

Names retain the existing form:

```text
xrt_<target>_<platform>_c<cores>_f<requested-frequency>[_flags]_<hash>[_collision]
```

Platform identifiers and relative/absolute `.xpfm` paths are supported. For
example, `/opt/xilinx/platforms/.../xilinx_u55c_....xpfm` produces `u55c`,
never nested directories. Invalid path components, unsupported target values,
missing core counts and invalid frequencies stop apply before builds move.

Blank stamp values use fallbacks. Core counts are resolved from stamp,
CONFIGS, sources defines, then the directory name. Conflicting explicit core
counts are rejected. Vitis link summaries support `<ENTRY>` JSON records,
argument arrays, quoted command lines and embedded kernel-frequency config.
The historical `CLOCK_FREQ_HZ` field and requested-frequency naming convention
are retained; this tool does not change or claim the packaged hardware clock.

Valid schema-v2 manifest identities are preserved, including the original
short hash length. `--hash-len` (1–64) applies to newly computed identities.
Existing parameters, source provenance, notes and timestamps are retained.
Resolved display parameters are recorded in the additive `resolved_params`
field. Location/name and original-name metadata are updated during a repair.
`--force` rewrites metadata; it never replaces an existing build directory or
changes an archived identity. A collision gets the next free numeric suffix.
An already assigned suffix remains stable when the command is repeated.

## Apply output

```text
MOVING: /absolute/source -> /absolute/destination
MOVED: /absolute/source -> /absolute/destination
SYMLINK: /original/build/path -> /absolute/destination
MANIFEST: /absolute/destination/manifest.json
INDEX UPDATED: /opt/vortex_fpga_bins/fpint
DONE: moved=1 unchanged=0 failed=0
```

`MOVING` announces work; `MOVED` follows a committed destination, manifest and
aliases. A later source-backup cleanup or index error is reported separately
and exits nonzero. Repeated commands print `UNCHANGED` and the actual location.
Source aliases explicitly passed to the command are pointed directly at the
destination; a compatibility link also preserves the previous physical path.

Indices use each archived manifest's ID and actual directory name/path. They
do not rename peer builds or recompute peer IDs from current RTL. `by-hash`
links remain stable; only broken tool-generated hash links are removed. Live
legacy aliases are preserved even when their targets lack build metadata.
`latest` uses the archived build timestamp, falling back to directory mtime.

## Failure handling and recovery

Apply obtains nonblocking archive locks before planning collisions or moving
data. This implementation targets Linux (`flock` and `renameat2` with
`RENAME_NOREPLACE`). A destination appearing after preflight cannot be silently
replaced, including an empty directory. Real entries at metadata/link locations
are not silently removed to make room for links.

Each build has an atomic `.vortex_binmgr_journal_<id>.json` in the destination
leaf. Same-filesystem transfers use rename. Cross-filesystem transfers copy
to a hidden destination staging directory, compare full file inventories,
sizes, SHA-256 contents and literal symlink targets, and check the source again
before publishing. The original copy is only retired after metadata and links
commit. File hashing is streamed; directory symlinks are not traversed.

On an ordinary error, roll back the current uncommitted build and stop the
batch. Previously committed builds remain in place and partial completion is
reported. On interruption, rerun the command with the same `--root` to inspect
journals, roll back incomplete moves, finish committed cleanup and rebuild
indices. Destination/source inode checks and alias checks reject ambiguous
external changes; errors report the source, destination and journal to inspect.
Do not edit or discard a retained journal before locating its data.

Failed cross-filesystem copies are retained under hidden
`.vortex_binmgr_copy_*` paths and reported as `RECOVERY COPY RETAINED`.
They are excluded from build scans. Inspection and disposal of these copies
is separate from a successful move; no archive-wide cleanup is performed.

## Regression checks

```bash
python3 -m unittest tools.test_vortex_binmgr
```

Tests cover the malformed absolute-platform path, empty metadata, manifest
compatibility, collisions, aliases, repeat execution, root/leaf scans, locks,
preflight rejection and injected move/copy/verification/metadata/index failures.
Journal interruption tests cover both rename and copy phases. A real
cross-filesystem fixture uses `/dev/shm` when available, in addition to EXDEV
fault injection. All test moves and recovery operations use temporary archives.

## Verified repair on 2026-09-17

The naive TH16/MXU16 L16 all-BRAM ACC base PnR build was recovered from the
malformed `fpint/xrt_hw_/opt/xilinx/platforms/...` hierarchy to:

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_c26f196986
```

Its ID, raw manifest parameters, directory inode and xclbin SHA-256 were
preserved. Both the original build-tree alias and the malformed former
location resolve to the corrected directory. The repaired build appears in
`hashes.json` and `by-hash/c26f196986`. Repeating the user's relative command
from the XRT build directory reported `moved=0 unchanged=1 failed=0`.

Final checks confirmed that all 23 peer build directories/manifests and all
24 pre-existing live hash-link targets were preserved. An initial index
cleanup removed one live legacy alias whose target lacked build metadata;
that alias was restored from the pre-apply snapshot, the preservation rule
was corrected, and a regression test now covers it. The final suite has 36
passing tests. Local repair receipts, snapshots and output are retained under
`build/vortex_binmgr_repair_20260917_122041/`.
