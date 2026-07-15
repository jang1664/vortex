#!/usr/bin/env python3
"""Inspect Vivado utilization reports through hwexplorer."""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
from pathlib import Path
from typing import Any, Sequence


SUMMARY_ROWS = {
    "clb_logic": ["CLB LUTs", "LUT as Logic", "LUT as Memory", "CLB Registers"],
    "blockram": ["Block RAM Tile", "RAMB36/FIFO*", "RAMB18", "URAM"],
    "arithmetic": ["DSPs"],
}


class HwexplorerUnavailable(RuntimeError):
    """Raised when the hwexplorer package or one of its dependencies is absent."""


def _hwexplorer_candidates() -> list[Path]:
    candidates = []
    env_root = os.environ.get("HWEXPLORER_ROOT")
    if env_root:
        candidates.append(Path(env_root).expanduser())

    repo_root = Path(__file__).resolve().parents[1]
    candidates.append(repo_root.parent / "hwexplorer")
    candidates.append(repo_root.parent / "research" / "hwexplorer")
    return candidates


def _import_utilization_parser():
    for candidate in _hwexplorer_candidates():
        if (candidate / "hwexplorer" / "report_parser.py").is_file():
            candidate_str = str(candidate)
            if candidate_str not in sys.path:
                sys.path.insert(0, candidate_str)
            break

    previous_disable_level = logging.root.manager.disable
    logging.disable(logging.INFO)
    try:
        from hwexplorer.report_parser import VivadoUtilizationParser
    except ModuleNotFoundError as exc:
        raise HwexplorerUnavailable(
            "cannot import hwexplorer or one of its dependencies; install it with "
            "'pip install -e /path/to/hwexplorer' or run this command in an environment "
            "that provides pandas, matplotlib, and multimethod"
        ) from exc
    finally:
        logging.disable(previous_disable_level)

    hwexplorer_logger = logging.getLogger("hwexplorer")
    hwexplorer_logger.setLevel(logging.WARNING)
    for handler in hwexplorer_logger.handlers:
        handler.setLevel(logging.WARNING)

    return VivadoUtilizationParser


def load_database(report: str | Path):
    report_path = Path(report).expanduser()
    if not report_path.is_file():
        raise FileNotFoundError(f"utilization report not found: {report_path}")

    parser_cls = _import_utilization_parser()
    return parser_cls().load(str(report_path.resolve()))


def _clean_cell(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def build_summary(db):
    import pandas as pd

    records: list[dict[str, str]] = []
    for table_name, resources in SUMMARY_ROWS.items():
        if not db.has_table(table_name):
            continue

        table = db.table(table_name)
        if table.empty:
            continue
        resource_column = table.columns[0]
        normalized = table[resource_column].astype(str).str.strip()

        for resource in resources:
            matches = table.loc[normalized == resource]
            if matches.empty:
                continue
            row = matches.iloc[0]
            record = {"Section": table_name, "Resource": resource}
            for column in ("Used", "Fixed", "Available", "Util%"):
                record[column] = _clean_cell(row[column]) if column in table.columns else ""
            records.append(record)

    return pd.DataFrame(
        records,
        columns=["Section", "Resource", "Used", "Fixed", "Available", "Util%"],
    )


def select_table(db, table_name: str, row_filter: str | None = None):
    if not db.has_table(table_name):
        available = ", ".join(db.list_tables())
        raise KeyError(f"unknown table {table_name!r}; available tables: {available}")

    table = db.table(table_name).copy()
    table = table.apply(lambda column: column.map(_clean_cell))
    if row_filter and not table.empty:
        pattern = re.compile(row_filter)
        first_column = table.columns[0]
        mask = table[first_column].astype(str).map(lambda value: pattern.search(value) is not None)
        table = table.loc[mask]
    return table.reset_index(drop=True)


def select_columns(table, columns: str | None):
    if not columns:
        return table
    requested = [column.strip() for column in columns.split(",") if column.strip()]
    missing = [column for column in requested if column not in table.columns]
    if missing:
        raise KeyError(
            f"unknown column(s): {', '.join(missing)}; available columns: "
            f"{', '.join(str(column) for column in table.columns)}"
        )
    return table.loc[:, requested]


def render_dataframe(table, output_format: str) -> str:
    if output_format == "text":
        return table.to_string(index=False)
    if output_format == "csv":
        return table.to_csv(index=False).rstrip("\n")
    if output_format == "json":
        return table.to_json(orient="records", indent=2)
    raise ValueError(f"unsupported output format: {output_format}")


def _render_metadata(metadata: dict[str, Any], output_format: str) -> str:
    visible = {key: value for key, value in metadata.items() if key != "header_lines"}
    if output_format == "json":
        return json.dumps(visible, indent=2, default=str)
    return "\n".join(f"{key}: {value}" for key, value in visible.items())


def _write_output(content: str, output: Path | None) -> None:
    if output is None:
        print(content)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content + ("" if content.endswith("\n") else "\n"), encoding="utf-8")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Parse Vivado utilization reports with hwexplorer.",
    )
    parser.add_argument("report", type=Path, help="Vivado report_utilization output")

    commands = parser.add_subparsers(dest="command")
    summary = commands.add_parser("summary", help="show major CLB, memory, and DSP resources")
    summary.add_argument("--filter", help="regular expression applied to resource names")
    summary.add_argument("--format", choices=("text", "csv", "json"), default="text")
    summary.add_argument("-o", "--output", type=Path)
    commands.add_parser("tables", help="list all parsed report tables")

    metadata = commands.add_parser("metadata", help="show report metadata")
    metadata.add_argument("--format", choices=("text", "json"), default="text")
    metadata.add_argument("-o", "--output", type=Path)

    show = commands.add_parser("show", help="show one parsed report table")
    show.add_argument("table", help="table name from the 'tables' command")
    show.add_argument("--filter", help="regular expression applied to the first column")
    show.add_argument("--columns", help="comma-separated output columns")
    show.add_argument("--format", choices=("text", "csv", "json"), default="text")
    show.add_argument("-o", "--output", type=Path)
    return parser


def _summary_header(db) -> str:
    metadata = db.metadata
    return "\n".join(
        [
            f"Report: {metadata.get('source_path', '')}",
            f"Design: {metadata.get('design_name', '')}",
            f"Device: {metadata.get('device', '')}",
            f"State: {metadata.get('design_state', '')}",
        ]
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    try:
        db = load_database(args.report)
        command = args.command or "summary"

        if command == "summary":
            summary = build_summary(db)
            if args.filter:
                pattern = re.compile(args.filter)
                mask = summary["Resource"].map(lambda value: pattern.search(value) is not None)
                summary = summary.loc[mask].reset_index(drop=True)
            rendered = render_dataframe(summary, args.format)
            if args.format == "text":
                rendered = f"{_summary_header(db)}\n\n{rendered}"
            _write_output(rendered, args.output)
            return 0

        if command == "tables":
            rows = []
            for name in db.list_tables():
                table = db.table(name)
                rows.append({"Table": name, "Rows": len(table), "Columns": len(table.columns)})
            import pandas as pd

            print(render_dataframe(pd.DataFrame(rows), "text"))
            return 0

        if command == "metadata":
            _write_output(_render_metadata(db.metadata, args.format), args.output)
            return 0

        if command == "show":
            table = select_table(db, args.table, args.filter)
            table = select_columns(table, args.columns)
            _write_output(render_dataframe(table, args.format), args.output)
            return 0

        parser.error(f"unsupported command: {command}")
    except (FileNotFoundError, HwexplorerUnavailable, KeyError, re.error) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
