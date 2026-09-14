# Local experiment archives

On 2026-09-12, the 95 top-level `build_*` experiment directories were archived
under the existing `build/` directory and rebuildable outputs were pruned.
These archives are local files, not a Git backup.

| Original experiment | Current location |
| --- | --- |
| Names containing `pnr`, plus `build_slr_hw` | `build/pnr/<original-directory-name>/` |
| All other archived `build_*` directories | `build/experiment-archive/<original-directory-name>/` |

The relative layout inside each experiment is preserved. PnR archives retain
FPGA output directories, xclbins, implementation/diagnostic checkpoints,
reports, logs, constraints, configuration and source snapshots. Generated IP
checkpoints and compiler outputs were pruned. Simulation archives retain
results, logs, configuration and source snapshots; existing compressed simv
logs were retained conservatively. Artifact directories were retained in full.

## Finding evidence

Experiment notes and STATUS YAML files now use the archive locations.
Historical commands in those notes describe the original runs: do not execute
configure, make, synthesis, or simulation in these pruned archives. Create a
fresh configured build directory for new work. Original runner/status scripts
and raw archived logs retain their historical paths; use the relocation map
when reading old evidence. The archives are not resumable build trees.

`build/cleanup-2026-09-12/manifest.json` records every original file, its
preservation decision and reason, and SHA-256 hashes for retained regular files.
The `mapping` field translates original build directories to archive paths.
`links.json` records relocated links and links removed because their targets
were pruned or already missing. `completed.json` records verification completion.
The cleanup script and before/after disk usage are stored beside the manifest.

Preserved regular-file hashes were verified at their destination before
rebuildable files were deleted. Existing unrelated contents under `build/`
were not part of this cleanup.
