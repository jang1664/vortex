"""Configuration models for selective block-PnR top analysis."""

from __future__ import annotations

from pathlib import Path
from typing import Union

import yaml
from pydantic import AliasChoices, BaseModel, ConfigDict, Field, model_validator

from hwexplorer.automation.pnr_search import PnRAreaSearchConfig


class CandidatePattern(BaseModel):
    model_config = ConfigDict(extra="forbid")

    pattern: str
    required: bool = False
    diagnostic_only: bool = False


class CandidateInclude(BaseModel):
    model_config = ConfigDict(extra="forbid")

    modules: list[CandidatePattern] = Field(default_factory=list)
    designs: list[CandidatePattern] = Field(default_factory=list)
    instances: list[CandidatePattern] = Field(default_factory=list)


class CandidateExclude(BaseModel):
    model_config = ConfigDict(extra="forbid")

    modules: list[str] = Field(default_factory=list)
    designs: list[str] = Field(default_factory=list)
    instances: list[str] = Field(default_factory=list)


class PnRSearchConfig(PnRAreaSearchConfig):
    model_config = ConfigDict(extra="forbid")

    initial_area_scale: float = Field(
        1.0,
        validation_alias=AliasChoices("initial_area_scale", "initial_area_margin"),
    )
    bracket_factor: float = Field(
        2.0,
        validation_alias=AliasChoices("bracket_factor", "area_margin_multiplier"),
    )
    target_utilization: Union[float, str] = "from_report"
    aspect_ratio: Union[float, str] = "from_report"
    boundary_margin: float = 1.0
    width_grid: float = 0.1
    height_grid: float = 0.1
    max_routing_drc_errors: int = 0

    @model_validator(mode="after")
    def _validate_floorplan(self) -> "PnRSearchConfig":
        if self.max_routing_drc_errors < 0:
            raise ValueError("max_routing_drc_errors cannot be negative")
        return self

    def search_policy(self) -> PnRAreaSearchConfig:
        return PnRAreaSearchConfig.model_validate(
            {
                field: getattr(self, field)
                for field in PnRAreaSearchConfig.model_fields
            }
        )


class AnalysisConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    include: CandidateInclude
    exclude: CandidateExclude = Field(default_factory=CandidateExclude)
    minimum_total_area_um2: float = 0.0
    allow_nested: bool = False
    pnr: PnRSearchConfig = Field(default_factory=PnRSearchConfig)


def load_analysis_config(path: str | Path) -> AnalysisConfig:
    data = yaml.safe_load(Path(path).read_text())
    return AnalysisConfig.model_validate(data)
