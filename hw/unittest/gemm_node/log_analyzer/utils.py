"""Utility functions for FSIM Log Analyzer."""

from pathlib import Path
from typing import Optional


def parse_patterns(pattern_str: Optional[str]) -> list[str]:
    """Parse comma-separated pattern string into list."""
    if not pattern_str:
        return []
    return [p.strip() for p in pattern_str.split(",") if p.strip()]


def split_log_by_simulation(log_file: Path, output_dir: Path = None) -> list[Path]:
    """
    Split a log file into multiple files based on "Simulation finished." markers.

    Args:
        log_file: Path to the log file to split
        output_dir: Directory to write output files (default: same as input file)

    Returns:
        List of paths to the created output files
    """
    if output_dir is None:
        output_dir = log_file.parent

    output_dir.mkdir(parents=True, exist_ok=True)

    # Get base name without extension
    stem = log_file.stem
    suffix = log_file.suffix

    output_files = []
    current_lines = []
    segment_index = 0

    with open(log_file, "r") as f:
        for line in f:
            current_lines.append(line)

            if "Simulation finished." in line:
                # Write current segment
                output_path = output_dir / f"{stem}_{segment_index}{suffix}"
                with open(output_path, "w") as out:
                    out.writelines(current_lines)
                output_files.append(output_path)

                # Reset for next segment
                current_lines = []
                segment_index += 1

    # Write remaining lines if any (after last "Simulation finished." or if no marker found)
    if current_lines:
        output_path = output_dir / f"{stem}_{segment_index}{suffix}"
        with open(output_path, "w") as out:
            out.writelines(current_lines)
        output_files.append(output_path)

    return output_files
