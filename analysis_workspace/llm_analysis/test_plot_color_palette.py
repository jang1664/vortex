import ast
from pathlib import Path


HERE = Path(__file__).resolve().parent


def top_level_literals(script_name: str) -> tuple[dict[str, object], str]:
    source = (HERE / script_name).read_text()
    tree = ast.parse(source)
    values = {}
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id.isupper():
                try:
                    values[target.id] = ast.literal_eval(node.value)
                except ValueError:
                    pass
    return values, source


def test_long_sequence_breakdown_uses_gray_and_blue_palette():
    values, source = top_level_literals("plot_long_seq_attn_breakdown.py")

    assert values["LINEAR_COLOR"] == "#7a7f85"
    assert values["ATTENTION_COLOR"] == "#2f80b7"
    assert values["BAR_EDGE_COLOR"] == "#4f545a"
    assert 'color=LINEAR_COLOR' in source
    assert 'color=ATTENTION_COLOR' in source
    assert '"#E45756"' not in source


def test_progression_roofline_uses_gray_and_blue_palette():
    values, source = top_level_literals("plot_progression_roofline.py")

    assert values["ROOFLINE_COLOR"] == "#4f545a"
    assert values["RIDGE_COLOR"] == "#7a7f85"
    assert values["MARKER_EDGE_COLOR"] == "#4f545a"
    assert values["PROGRESSION_COLORS"] == (
        "#7a7f85",
        "#9ecae1",
        "#6baed6",
        "#2f80b7",
        "#0f4c81",
        "#08306b",
    )
    assert 'color=ROOFLINE_COLOR' in source
    assert 'color=RIDGE_COLOR' in source
    assert 'markeredgecolor=MARKER_EDGE_COLOR' in source
    assert "plt.get_cmap" not in source
    assert '"plasma"' not in source
