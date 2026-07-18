"""Configuration models for selective block-PnR top analysis."""

from __future__ import annotations

from pathlib import Path
from typing import Union

import yaml
from pydantic import BaseModel, ConfigDict, Field, model_validator


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


class PnRRetryConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    max_attempts: int = 4
    initial_area_margin: float = 1.10
    area_margin_multiplier: float = 1.15
    target_utilization: Union[float, str] = "from_report"
    aspect_ratio: Union[float, str] = "from_report"
    boundary_margin: float = 1.0
    width_grid: float = 0.1
    height_grid: float = 0.1
    max_routing_drc_errors: int = 0

    @model_validator(mode="after")
    def _validate_retry(self) -> "PnRRetryConfig":
        if self.max_attempts < 1:
            raise ValueError("max_attempts must be at least 1")
        if self.initial_area_margin <= 0:
            raise ValueError("initial_area_margin must be positive")
        if self.area_margin_multiplier < 1:
            raise ValueError("area_margin_multiplier must be at least 1")
        if self.max_routing_drc_errors < 0:
            raise ValueError("max_routing_drc_errors cannot be negative")
        return self

    def margins(self) -> list[float]:
        return [
            self.initial_area_margin * self.area_margin_multiplier**index
            for index in range(self.max_attempts)
        ]


class AnalysisConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    include: CandidateInclude
    exclude: CandidateExclude = Field(default_factory=CandidateExclude)
    minimum_total_area_um2: float = 0.0
    allow_nested: bool = False
    pnr: PnRRetryConfig = Field(default_factory=PnRRetryConfig)


def load_analysis_config(path: str | Path) -> AnalysisConfig:
    data = yaml.safe_load(Path(path).read_text())
    return AnalysisConfig.model_validate(data)
