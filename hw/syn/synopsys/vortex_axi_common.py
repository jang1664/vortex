"""Shared Vortex_axi synthesis setup for command-line analysis flows."""

from run_syn_vortex_axi import (  # noqa: F401
    MAX_CORNER,
    RESULT_ROOT,
    VORTEX_HOME,
    _validate_synthesis_result,
    build_vortex_axi_synth_config,
)

__all__ = [
    "MAX_CORNER",
    "RESULT_ROOT",
    "VORTEX_HOME",
    "_validate_synthesis_result",
    "build_vortex_axi_synth_config",
]
