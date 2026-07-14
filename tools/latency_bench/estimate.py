from __future__ import annotations

import json
import math
import shlex
import warnings
from dataclasses import dataclass

import numpy as np
import pandas as pd
from sklearn.feature_extraction import DictVectorizer
from sklearn.linear_model import LinearRegression, Ridge
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler


DEFAULT_GROUP_COLUMNS = ("fpga_bin_label", "app", "name", "stage")
MODEL_CHOICES = ("auto_shape", "linear_1d", "linear_2d", "linear_3d", "ridge_log")
FALLBACK_CHOICES = ("nearest_scale", "none")
ARG_NUMERIC_KEYS = {
    "-m": "M",
    "-n": "N",
    "-k": "K",
    "-q": "QBLK",
    "-t": "WTRANS",
    "-d": "QDIR",
}
PRIMARY_WORK_FEATURES = (
    "M*N*K",
    "size",
    "rows*dim",
    "batch*seq*hidden",
    "batch*heads*seqk*seqq",
    "batch*seqk*seqq",
    "seqk*seqq*heads",
    "M*N",
    "batch*seq",
    "heads*headdim",
)
SHAPE_1D_FEATURES = (
    "M*N*K",
    "M*N",
    "batch*seq*hidden",
    "batch*seq",
    "rows*dim",
    "batch*heads*seqk*seqq",
    "batch*seqk*seqq",
    "batch*heads*seqk",
    "batch*seqk",
    "seqk*seqq*heads",
    "seqk*seqq",
    "N*K",
    "M*K",
    "heads*headdim",
    "N",
    "M",
    "K",
    "seq",
    "size",
)
SHAPE_2D_AXES = (
    ("M", "N"),
    ("M", "K"),
    ("N", "K"),
    ("batch", "seq"),
    ("rows", "dim"),
    ("seqk", "seqq"),
    ("batch", "seqk"),
    ("batch", "seqk*seqq"),
)
SHAPE_3D_AXES = (
    ("M", "N", "K"),
    ("batch", "seq", "hidden"),
    ("batch", "seqk", "seqq"),
)
SHAPE_MODEL_COMPLEXITY = {"linear_1d": 0, "linear_2d": 1, "linear_3d": 2, "ridge_log": 3}
_MAPE_EPS = 1.0e-12


@dataclass(frozen=True)
class LatencyEstimateOptions:
    enabled: bool = True
    group_columns: tuple[str, ...] = DEFAULT_GROUP_COLUMNS
    min_train_rows: int = 3
    model: str = "auto_shape"
    fallback: str = "nearest_scale"
    ridge_alpha: float = 1.0
    warn_extrapolation: bool = True


@dataclass(frozen=True)
class _EstimateResult:
    latency: float
    model_name: str
    distance: float
    nearest: pd.Series
    basis: str = ""
    selected_by: str = ""
    cv_mape: float | None = None
    train_mape: float | None = None


@dataclass
class _EstimateGroupCache:
    train: pd.DataFrame
    train_maps: list[dict[str, float]]
    shape_scores: dict[str, list[dict[str, object]]]
    ridge_models: dict[float, object]


def _unique_join(values: pd.Series | list[object]) -> str:
    out: list[str] = []
    seen: set[str] = set()
    iterable = values.dropna().tolist() if isinstance(values, pd.Series) else values
    for value in iterable:
        text = str(value)
        if not text or text == "nan" or text in seen:
            continue
        seen.add(text)
        out.append(text)
    return ";".join(out)


def _is_missing(value: object) -> bool:
    if value is None:
        return True
    try:
        return bool(pd.isna(value))
    except (TypeError, ValueError):
        return False


def _float_or_none(value: object) -> float | None:
    if _is_missing(value) or isinstance(value, bool):
        return None
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    return out if math.isfinite(out) else None


def _shape_from_row(row: pd.Series) -> dict[str, object]:
    raw = row.get("shape_json", "")
    if not raw or _is_missing(raw):
        return {}
    try:
        value = json.loads(str(raw))
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def _args_numeric_features(args: object) -> dict[str, float]:
    try:
        tokens = shlex.split(str(args or ""))
    except ValueError:
        tokens = str(args or "").split()
    out: dict[str, float] = {}
    idx = 0
    while idx < len(tokens):
        token = tokens[idx]
        key = ARG_NUMERIC_KEYS.get(token)
        if key and idx + 1 < len(tokens):
            value = _float_or_none(tokens[idx + 1])
            if value is not None:
                out.setdefault(key, value)
            idx += 2
            continue
        idx += 1
    return out


def _numeric_shape_features(row: pd.Series) -> dict[str, float]:
    shape = _shape_from_row(row)
    out = _args_numeric_features(row.get("args", ""))
    for key, value in shape.items():
        numeric = _float_or_none(value)
        if numeric is not None:
            out[key] = numeric

    def add_product(name: str, keys: tuple[str, ...]) -> None:
        values = [out.get(key) for key in keys]
        if any(value is None for value in values):
            return
        product = 1.0
        for value in values:
            product *= float(value)
        out[name] = product

    add_product("M*N", ("M", "N"))
    add_product("M*K", ("M", "K"))
    add_product("N*K", ("N", "K"))
    add_product("M*N*K", ("M", "N", "K"))
    add_product("batch*seq", ("batch", "seq"))
    add_product("batch*seq*hidden", ("batch", "seq", "hidden"))
    add_product("rows*dim", ("rows", "dim"))
    add_product("heads*headdim", ("heads", "headdim"))
    add_product("seqk*seqq", ("seqk", "seqq"))
    add_product("seqk*seqq*heads", ("seqk", "seqq", "heads"))
    add_product("batch*seqk", ("batch", "seqk"))
    add_product("batch*seqk*seqq", ("batch", "seqk", "seqq"))
    add_product("batch*heads*seqk", ("batch", "heads", "seqk"))
    add_product("batch*heads*seqk*seqq", ("batch", "heads", "seqk", "seqq"))
    return out


def latency_feature_dict(row: pd.Series) -> dict[str, object]:
    shape = _shape_from_row(row)
    numeric = _numeric_shape_features(row)
    features: dict[str, object] = {}
    for key, value in numeric.items():
        features[f"num:{key}"] = float(value)
        if value >= 0:
            features[f"log1p:{key}"] = math.log1p(float(value))
    for key, value in shape.items():
        if key in numeric:
            continue
        if isinstance(value, bool):
            features[f"cat:{key}={int(value)}"] = 1.0
        elif value is not None:
            features[f"cat:{key}={value}"] = 1.0
    return features


def _group_value(row: pd.Series, column: str) -> str:
    if column == "fpga_bin_label" and "expected_fpga_bin_label" in row:
        value = row.get("expected_fpga_bin_label", "")
    else:
        value = row.get(column, "")
    return "" if _is_missing(value) else str(value)


def _group_key(row: pd.Series, columns: tuple[str, ...]) -> tuple[str, ...]:
    return tuple(_group_value(row, column) for column in columns)


def _group_label(columns: tuple[str, ...], key: tuple[str, ...]) -> str:
    return ";".join(f"{column}={value}" for column, value in zip(columns, key))


def _warning_row_label(prefix: str, row: pd.Series) -> str:
    fields = ("case_id", "app", "args")
    parts: list[str] = []
    for field in fields:
        value = row.get(field, "")
        text = "" if _is_missing(value) else str(value)
        parts.append(f"{prefix}_{field}={text!r}")
    return "; ".join(parts)


def _validate_options(options: LatencyEstimateOptions) -> None:
    if options.model not in MODEL_CHOICES:
        raise ValueError(f"unsupported latency estimate model: {options.model}")
    if options.fallback not in FALLBACK_CHOICES:
        raise ValueError(f"unsupported latency estimate fallback: {options.fallback}")
    if options.min_train_rows <= 0:
        raise ValueError("min_train_rows must be positive")
    if not math.isfinite(float(options.ridge_alpha)) or options.ridge_alpha <= 0.0:
        raise ValueError("ridge_alpha must be positive and finite")


def _numeric_distance(target: dict[str, float], train_maps: list[dict[str, float]]) -> tuple[float, int]:
    best_distance = math.inf
    best_idx = 0
    keys = sorted(key for key in target if any(key in train for train in train_maps))
    if not keys:
        return 0.0, 0

    train_logs: dict[str, list[float]] = {
        key: [math.log1p(max(float(train[key]), 0.0)) for train in train_maps if key in train]
        for key in keys
    }
    for idx, train in enumerate(train_maps):
        terms: list[float] = []
        for key in keys:
            if key not in train:
                continue
            values = train_logs[key]
            spread = max(max(values) - min(values), 1.0)
            left = math.log1p(max(float(target[key]), 0.0))
            right = math.log1p(max(float(train[key]), 0.0))
            terms.append(((left - right) / spread) ** 2)
        distance = math.sqrt(sum(terms) / max(len(terms), 1))
        if distance < best_distance:
            best_distance = distance
            best_idx = idx
    return float(best_distance if math.isfinite(best_distance) else 0.0), best_idx


def _estimate_mode(target: dict[str, float], train_maps: list[dict[str, float]]) -> str:
    for key, value in target.items():
        train_values = [train[key] for train in train_maps if key in train]
        if not train_values:
            continue
        if value < min(train_values) or value > max(train_values):
            return "extrapolation"
    return "interpolation"


def _format_optional_float(value: float | None) -> str:
    if value is None or not math.isfinite(float(value)):
        return ""
    return f"{float(value):.12g}"


def _latency_values(train: pd.DataFrame) -> np.ndarray:
    return pd.to_numeric(train["latency_us"], errors="coerce").astype(float).to_numpy()


def _mape(actual: np.ndarray, predicted: np.ndarray) -> float:
    mask = np.isfinite(actual) & np.isfinite(predicted) & (np.abs(actual) > _MAPE_EPS)
    if not bool(mask.any()):
        return math.inf
    return float(np.mean(np.abs(predicted[mask] - actual[mask]) / np.maximum(np.abs(actual[mask]), _MAPE_EPS)))


def _shape_feature_names(model_name: str, basis: tuple[str, ...]) -> tuple[str, ...]:
    if model_name == "linear_1d":
        return basis
    if model_name == "linear_2d":
        x, y = basis
        return (x, y, f"{x}*{y}")
    if model_name == "linear_3d":
        x, y, z = basis
        return (x, y, z, f"{x}*{y}", f"{x}*{z}", f"{y}*{z}", f"{x}*{y}*{z}")
    raise ValueError(f"unsupported shape model: {model_name}")


def _basis_label(model_name: str, basis: tuple[str, ...]) -> str:
    return ",".join(_shape_feature_names(model_name, basis))


def _shape_matrix_from_maps(
    numeric_maps: list[dict[str, float]],
    *,
    model_name: str,
    basis: tuple[str, ...],
) -> np.ndarray | None:
    rows: list[list[float]] = []
    for numeric in numeric_maps:
        if any(axis not in numeric for axis in basis):
            return None
        values = [float(numeric[axis]) for axis in basis]
        if not all(math.isfinite(value) for value in values):
            return None
        if model_name == "linear_1d":
            row = [values[0]]
        elif model_name == "linear_2d":
            x, y = values
            row = [x, y, x * y]
        elif model_name == "linear_3d":
            x, y, z = values
            row = [x, y, z, x * y, x * z, y * z, x * y * z]
        else:
            raise ValueError(f"unsupported shape model: {model_name}")
        rows.append(row)
    matrix = np.asarray(rows, dtype=float)
    return matrix if matrix.ndim == 2 and matrix.shape[0] else None


def _shape_candidate_specs(model_name: str) -> list[tuple[str, tuple[str, ...]]]:
    specs: list[tuple[str, tuple[str, ...]]] = []
    if model_name in {"auto_shape", "linear_1d"}:
        specs.extend(("linear_1d", (feature,)) for feature in SHAPE_1D_FEATURES)
    if model_name in {"auto_shape", "linear_2d"}:
        specs.extend(("linear_2d", axes) for axes in SHAPE_2D_AXES)
    if model_name in {"auto_shape", "linear_3d"}:
        specs.extend(("linear_3d", axes) for axes in SHAPE_3D_AXES)
    return specs


def _fit_positive_linear(x_train: np.ndarray, y_train: np.ndarray) -> LinearRegression | None:
    if x_train.size == 0 or y_train.size == 0:
        return None
    if not np.isfinite(x_train).all() or not np.isfinite(y_train).all():
        return None
    if np.any(y_train <= 0):
        return None
    model = LinearRegression(positive=True)
    model.fit(x_train, y_train)
    return model


def _loo_mape(x_train: np.ndarray, y_train: np.ndarray) -> float | None:
    if len(y_train) < 3:
        return None
    predictions: list[float] = []
    actual: list[float] = []
    for idx in range(len(y_train)):
        keep = np.ones(len(y_train), dtype=bool)
        keep[idx] = False
        model = _fit_positive_linear(x_train[keep], y_train[keep])
        if model is None:
            return None
        predictions.append(float(model.predict(x_train[idx:idx + 1])[0]))
        actual.append(float(y_train[idx]))
    return _mape(np.asarray(actual, dtype=float), np.asarray(predictions, dtype=float))


def _score_shape_candidate(
    train: pd.DataFrame,
    *,
    model_name: str,
    basis: tuple[str, ...],
    target_row: pd.Series | None = None,
    train_maps: list[dict[str, float]] | None = None,
) -> dict[str, object] | None:
    if train_maps is None:
        train_maps = [_numeric_shape_features(row) for _, row in train.iterrows()]
    x_train = _shape_matrix_from_maps(train_maps, model_name=model_name, basis=basis)
    if x_train is None:
        return None
    if target_row is not None:
        x_target = _shape_matrix_from_maps(
            [_numeric_shape_features(target_row)],
            model_name=model_name,
            basis=basis,
        )
        if x_target is None:
            return None
    else:
        x_target = None

    y_train = _latency_values(train)
    model = _fit_positive_linear(x_train, y_train)
    if model is None:
        return None

    train_pred = model.predict(x_train)
    train_mape = _mape(y_train, train_pred)
    cv_mape = _loo_mape(x_train, y_train)
    selected_score = cv_mape if cv_mape is not None and math.isfinite(cv_mape) else train_mape
    selected_by = "loo_mape" if cv_mape is not None and math.isfinite(cv_mape) else "train_mape"
    predicted = None if x_target is None else max(float(model.predict(x_target)[0]), 0.0)
    return {
        "model_name": model_name,
        "basis_tuple": basis,
        "basis": _basis_label(model_name, basis),
        "predicted": predicted,
        "model": model,
        "cv_mape": cv_mape,
        "train_mape": train_mape,
        "selected_score": selected_score,
        "selected_by": selected_by,
        "train_rows": len(train),
    }


def _shape_fit_scores(
    train: pd.DataFrame,
    *,
    model_name: str,
    target_row: pd.Series | None = None,
    train_maps: list[dict[str, float]] | None = None,
) -> list[dict[str, object]]:
    scores: list[dict[str, object]] = []
    if train_maps is None:
        train_maps = [_numeric_shape_features(row) for _, row in train.iterrows()]
    for candidate_model, basis in _shape_candidate_specs(model_name):
        score = _score_shape_candidate(
            train,
            model_name=candidate_model,
            basis=basis,
            target_row=target_row,
            train_maps=train_maps,
        )
        if score is not None:
            scores.append(score)
    return scores


def _select_shape_score(scores: list[dict[str, object]]) -> dict[str, object] | None:
    if not scores:
        return None

    def key(score: dict[str, object]) -> tuple[float, int, str]:
        selected_score = float(score.get("selected_score", math.inf))
        model_name = str(score.get("model_name", ""))
        basis = str(score.get("basis", ""))
        return (
            selected_score if math.isfinite(selected_score) else math.inf,
            SHAPE_MODEL_COMPLEXITY.get(model_name, 99),
            basis,
        )

    return sorted(scores, key=key)[0]


def _shape_fit_estimate(
    target_row: pd.Series,
    train: pd.DataFrame,
    *,
    requested_model: str,
    train_maps: list[dict[str, float]] | None = None,
    scores: list[dict[str, object]] | None = None,
) -> _EstimateResult | None:
    if train_maps is None:
        train_maps = [_numeric_shape_features(row) for _, row in train.iterrows()]
    if scores is None:
        scores = _shape_fit_scores(train, model_name=requested_model, train_maps=train_maps)

    target_numeric = _numeric_shape_features(target_row)
    compatible_scores: list[dict[str, object]] = []
    for score in scores:
        candidate_model = str(score.get("model_name", ""))
        basis = tuple(score.get("basis_tuple", ()))
        x_target = _shape_matrix_from_maps([target_numeric], model_name=candidate_model, basis=basis)
        if x_target is not None:
            compatible_scores.append(score)

    selected = _select_shape_score(compatible_scores)
    if selected is None:
        return None

    selected_model_name = str(selected["model_name"])
    selected_basis = tuple(selected.get("basis_tuple", ()))
    x_target = _shape_matrix_from_maps([target_numeric], model_name=selected_model_name, basis=selected_basis)
    if x_target is None:
        return None
    model = selected.get("model")
    if model is None:
        return None
    predicted = max(float(model.predict(x_target)[0]), 0.0)
    distance, nearest_idx = _numeric_distance(target_numeric, train_maps)
    model_name = selected_model_name
    if requested_model == "auto_shape":
        model_name = f"auto_shape:{model_name}"
    return _EstimateResult(
        latency=predicted,
        model_name=model_name,
        distance=distance,
        nearest=train.iloc[nearest_idx],
        basis=str(selected.get("basis", "")),
        selected_by=str(selected.get("selected_by", "")),
        cv_mape=selected.get("cv_mape") if selected.get("cv_mape") is not None else None,
        train_mape=selected.get("train_mape") if selected.get("train_mape") is not None else None,
    )


def _nearest_scale_estimate(
    target_row: pd.Series,
    train: pd.DataFrame,
    *,
    train_maps: list[dict[str, float]] | None = None,
    target_numeric: dict[str, float] | None = None,
) -> _EstimateResult:
    if target_numeric is None:
        target_numeric = _numeric_shape_features(target_row)
    if train_maps is None:
        train_maps = [_numeric_shape_features(row) for _, row in train.iterrows()]
    distance, nearest_idx = _numeric_distance(target_numeric, train_maps)
    nearest = train.iloc[nearest_idx]
    nearest_latency = float(pd.to_numeric(nearest["latency_us"], errors="coerce"))
    ratio = 1.0
    nearest_numeric = train_maps[nearest_idx]
    for key in PRIMARY_WORK_FEATURES:
        left = target_numeric.get(key)
        right = nearest_numeric.get(key)
        if left is not None and right is not None and right > 0:
            ratio = max(left / right, 0.0)
            break
    return _EstimateResult(
        latency=max(nearest_latency * ratio, 0.0),
        model_name="nearest_scale",
        distance=distance,
        nearest=nearest,
        basis=key if ratio != 1.0 else "",
        selected_by="fallback",
    )


def _fit_ridge_log_model(
    train: pd.DataFrame,
    *,
    alpha: float,
) -> object:
    feature_rows = [latency_feature_dict(row) for _, row in train.iterrows()]
    y = np.log1p(pd.to_numeric(train["latency_us"], errors="coerce").astype(float).to_numpy())
    model = make_pipeline(
        DictVectorizer(sparse=True),
        StandardScaler(with_mean=False),
        Ridge(alpha=alpha),
    )
    model.fit(feature_rows, y)
    return model


def _ridge_log_estimate(
    target_row: pd.Series,
    train: pd.DataFrame,
    *,
    alpha: float,
    train_maps: list[dict[str, float]] | None = None,
    model: object | None = None,
) -> _EstimateResult:
    if model is None:
        model = _fit_ridge_log_model(train, alpha=alpha)
    target_features = latency_feature_dict(target_row)
    predicted = float(np.expm1(model.predict([target_features])[0]))

    target_numeric = _numeric_shape_features(target_row)
    if train_maps is None:
        train_maps = [_numeric_shape_features(row) for _, row in train.iterrows()]
    distance, nearest_idx = _numeric_distance(target_numeric, train_maps)
    return _EstimateResult(
        latency=max(predicted, 0.0),
        model_name="ridge_log",
        distance=distance,
        nearest=train.iloc[nearest_idx],
        basis="dict_features",
        selected_by="requested_model",
    )


def _empty_estimate_columns(out: pd.DataFrame) -> pd.DataFrame:
    defaults: dict[str, object] = {
        "estimate_model": "",
        "estimate_basis": "",
        "estimate_selected_by": "",
        "estimate_cv_mape": "",
        "estimate_train_mape": "",
        "estimate_group": "",
        "estimate_mode": "",
        "estimate_train_rows": 0,
        "estimate_distance": "",
        "estimate_source_case_id": "",
        "estimate_source_raw_dbs": "",
    }
    for column, value in defaults.items():
        if column not in out.columns:
            out[column] = value
    return out


def _measured_rows(out: pd.DataFrame) -> pd.DataFrame:
    empty_status = pd.Series("", index=out.index, dtype=object)
    empty_latency = pd.Series(index=out.index, dtype=float)
    status = out.get("compose_status", empty_status).astype(str)
    latency = pd.to_numeric(out.get("latency_us", empty_latency), errors="coerce")
    return out[(status == "pass") & latency.notna() & (latency > 0.0)].copy()


def _estimate_group_caches(
    measured: pd.DataFrame,
    group_columns: tuple[str, ...],
) -> dict[tuple[str, ...], _EstimateGroupCache]:
    buckets: dict[tuple[str, ...], list[object]] = {}
    for idx, row in measured.iterrows():
        buckets.setdefault(_group_key(row, group_columns), []).append(idx)

    caches: dict[tuple[str, ...], _EstimateGroupCache] = {}
    for group_key, indices in buckets.items():
        train = measured.loc[indices].copy()
        caches[group_key] = _EstimateGroupCache(
            train=train,
            train_maps=[_numeric_shape_features(row) for _, row in train.iterrows()],
            shape_scores={},
            ridge_models={},
        )
    return caches


def _shape_scores_for_group(
    cache: _EstimateGroupCache,
    model_name: str,
) -> list[dict[str, object]]:
    scores = cache.shape_scores.get(model_name)
    if scores is None:
        scores = _shape_fit_scores(cache.train, model_name=model_name, train_maps=cache.train_maps)
        cache.shape_scores[model_name] = scores
    return scores


def evaluate_latency_estimator_groups(
    composed: pd.DataFrame,
    options: LatencyEstimateOptions | None,
) -> pd.DataFrame:
    if options is None or not options.enabled:
        return pd.DataFrame()
    _validate_options(options)

    measured = _measured_rows(composed)
    if measured.empty or options.model == "ridge_log":
        return pd.DataFrame()

    rows: list[dict[str, object]] = []
    for group_key, cache in sorted(_estimate_group_caches(measured, options.group_columns).items()):
        scores = _shape_scores_for_group(cache, options.model)
        selected = _select_shape_score(scores)
        selected_key = None if selected is None else (selected["model_name"], selected["basis"])
        for score in scores:
            candidate_key = (score["model_name"], score["basis"])
            model_name = str(score["model_name"])
            if options.model == "auto_shape":
                model_name = f"auto_shape:{model_name}"
            rows.append({
                "estimate_group": _group_label(options.group_columns, group_key),
                "candidate_model": model_name,
                "candidate_basis": str(score["basis"]),
                "selected": candidate_key == selected_key,
                "selected_by": str(score["selected_by"]),
                "cv_mape": score["cv_mape"],
                "train_mape": score["train_mape"],
                "train_rows": int(score["train_rows"]),
            })
    return pd.DataFrame(rows)


def estimate_composed_latency(
    composed: pd.DataFrame,
    options: LatencyEstimateOptions | None,
) -> pd.DataFrame:
    if options is None or not options.enabled:
        return composed.copy()
    _validate_options(options)

    out = _empty_estimate_columns(composed.copy())
    empty_status = pd.Series("", index=out.index, dtype=object)
    status = out.get("compose_status", empty_status).astype(str)
    measured = _measured_rows(out)
    if measured.empty:
        return out

    group_caches = _estimate_group_caches(measured, options.group_columns)
    target_indices = out.index[status == "missing"].tolist()
    warned_groups: set[tuple[str, ...]] = set()
    for idx in target_indices:
        target = out.loc[idx]
        group_key = _group_key(target, options.group_columns)
        cache = group_caches.get(group_key)
        if cache is None or cache.train.empty:
            continue

        result: _EstimateResult | None = None
        if len(cache.train) >= options.min_train_rows:
            if options.model == "ridge_log":
                ridge_model = cache.ridge_models.get(options.ridge_alpha)
                if ridge_model is None:
                    ridge_model = _fit_ridge_log_model(cache.train, alpha=options.ridge_alpha)
                    cache.ridge_models[options.ridge_alpha] = ridge_model
                result = _ridge_log_estimate(
                    target,
                    cache.train,
                    alpha=options.ridge_alpha,
                    train_maps=cache.train_maps,
                    model=ridge_model,
                )
            else:
                result = _shape_fit_estimate(
                    target,
                    cache.train,
                    requested_model=options.model,
                    train_maps=cache.train_maps,
                    scores=_shape_scores_for_group(cache, options.model),
                )
        if result is None and options.fallback == "nearest_scale":
            result = _nearest_scale_estimate(target, cache.train, train_maps=cache.train_maps)
        if result is None:
            continue

        calls = _float_or_none(target.get("calls_per_forward"))
        calls = 1.0 if calls is None else calls
        target_numeric = _numeric_shape_features(target)
        mode = _estimate_mode(target_numeric, cache.train_maps)
        if options.warn_extrapolation and mode == "extrapolation" and group_key not in warned_groups:
            warned_groups.add(group_key)
            warnings.warn(
                "latency estimate for "
                f"{_group_label(options.group_columns, group_key)} uses extrapolation; "
                f"{_warning_row_label('target', target)}; "
                f"{_warning_row_label('source', result.nearest)}",
                RuntimeWarning,
                stacklevel=2,
            )

        out.loc[idx, "latency_us"] = result.latency
        out.loc[idx, "weighted_latency_us"] = result.latency * calls
        out.loc[idx, "compose_status"] = "estimated"
        out.loc[idx, "estimate_model"] = result.model_name
        out.loc[idx, "estimate_basis"] = result.basis
        out.loc[idx, "estimate_selected_by"] = result.selected_by
        out.loc[idx, "estimate_cv_mape"] = _format_optional_float(result.cv_mape)
        out.loc[idx, "estimate_train_mape"] = _format_optional_float(result.train_mape)
        out.loc[idx, "estimate_group"] = _group_label(options.group_columns, group_key)
        out.loc[idx, "estimate_mode"] = mode
        out.loc[idx, "estimate_train_rows"] = int(len(cache.train))
        out.loc[idx, "estimate_distance"] = f"{result.distance:.12g}"
        out.loc[idx, "estimate_source_case_id"] = str(result.nearest.get("case_id", ""))
        out.loc[idx, "estimate_source_raw_dbs"] = _unique_join(cache.train.get("source_raw_dbs", pd.Series(dtype=str)))
        out.loc[idx, "source_raw_dbs"] = out.loc[idx, "estimate_source_raw_dbs"]
        out.loc[idx, "source_run_ids"] = ""
        out.loc[idx, "selected_run_id"] = ""
        out.loc[idx, "selected_timestamp_utc"] = ""

    return out
