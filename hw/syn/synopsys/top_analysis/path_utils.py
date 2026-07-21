"""Reconcile elaboration-catalog paths with mapped DC hierarchy paths."""

from __future__ import annotations


def dc_hierarchy_path_candidates(top_design: str, instance_path: str) -> list[str]:
    """Return literal and DC-normalized rooted path candidates.

    DC's mapped area report renders generated array/dotted instance names such
    as ``lanes[0].worker`` as ``lanes_0__worker`` while the elaboration catalog
    preserves the RTL spelling. Keep literal paths first and use the normalized
    form only as a report reconciliation fallback.
    """

    if instance_path in ("", "."):
        return [top_design]
    normalized = (
        instance_path.replace("[", "_").replace("]", "_").replace(".", "_")
    )
    candidates = [instance_path, f"{top_design}/{instance_path}"]
    for candidate in (normalized, f"{top_design}/{normalized}"):
        if candidate not in candidates:
            candidates.append(candidate)
    return candidates
