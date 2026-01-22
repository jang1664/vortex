"""
Test utilities for FPINT GEMM Emulation

This module provides common helper functions for generating test data,
running tests, and visualizing results.
"""

import numpy as np
import matplotlib.pyplot as plt
from dataclasses import dataclass
from typing import Dict, Callable

from fpint_emul import (
    float_to_fp16_bit, fp16_bit_to_float,
    fpint_gemm_ref, fpint_gemm_qcol_2scomp, fpint_gemm_qcol_zero_less,
    fpint_gemm_qrow_2scomp, fpint_gemm_qrow_zero_less, fpint_gemm_qrow_real_2scomp,
    QCOL, QROW, QBLOCK
)
from visualize import (
    plot_heatmap_comparison, ulp_diff_fp16, relative_diff_percent, absolute_diff
)


# =============================================================================
# Data Generation Functions
# =============================================================================

def generate_random_fp16(size, value_range=(-10.0, 10.0), seed=None):
    """Generate random FP16 values as uint16 bit representation"""
    if seed is not None:
        np.random.seed(seed)

    # Generate random floats
    low, high = value_range
    float_vals = np.random.uniform(low, high, size=size)

    # Convert to FP16 bit representation
    fp16_vals = np.zeros(size, dtype=np.uint16)
    flat_float = float_vals.flatten()
    flat_fp16 = fp16_vals.ravel()  # Use ravel() to get a view, not a copy

    for i, val in enumerate(flat_float):
        flat_fp16[i] = float_to_fp16_bit(val)

    return fp16_vals


def generate_random_weights(size, w_width=4, seed=None):
    """Generate random quantized weights (0 to 2^w_width - 1)"""
    if seed is not None:
        np.random.seed(seed)

    max_val = (1 << w_width) - 1
    return np.random.randint(0, max_val + 1, size=size, dtype=np.uint8)


def generate_random_zero_points(size, z_range=(-8, 8), seed=None):
    """Generate random zero points"""
    if seed is not None:
        np.random.seed(seed)

    low, high = z_range
    return np.random.randint(low, high, size=size, dtype=np.int16)


# =============================================================================
# Error Function Configurations
# =============================================================================

# Predefined error function configurations
ERROR_FUNCS = {
    'rel_percent': (relative_diff_percent, 'Relative Error (%)'),
    'absolute': (absolute_diff, 'Absolute Error'),
    'ulp_fp16': (ulp_diff_fp16, 'ULP Error (FP16)'),
}


# =============================================================================
# Helper Functions
# =============================================================================

def to_float_matrix(output: np.ndarray) -> np.ndarray:
    """Convert FP16 bit representation matrix to float matrix"""
    M, N = output.shape
    result = np.zeros((M, N), dtype=np.float32)
    for m in range(M):
        for n in range(N):
            result[m, n] = fp16_bit_to_float(output[m, n])
    return result


def print_error_stats(
    name: str,
    output_float: np.ndarray,
    ref_float: np.ndarray,
    err_func: Callable,
    err_name: str
) -> np.ndarray:
    """Print error statistics for a single implementation"""
    error = err_func(ref_float, output_float)

    print(f"\n{name}:")
    print(f"  {err_name} - Max: {np.max(error):.6f}, Mean: {np.mean(error):.6f}, Median: {np.median(error):.6f}")

    return error


# =============================================================================
# Test Result Data Class
# =============================================================================

@dataclass
class TestResult:
    """Container for test results and input data"""
    # Test parameters
    name: str
    M: int
    K: int
    N: int
    seed: int
    ref_version: int
    err_func_name: str

    # Input data (raw)
    input_data: np.ndarray      # FP16 bits (M, K)
    weight_data: np.ndarray     # uint8 (K, N)
    scale_data: np.ndarray      # FP16 bits
    zero_data: np.ndarray       # int16

    # Output data
    output: np.ndarray          # FP16 bits (M, N)
    output_ref: np.ndarray      # FP16 bits (M, N)

    # Float versions
    output_float: np.ndarray    # float32 (M, N)
    ref_float: np.ndarray       # float32 (M, N)

    # Error metrics
    error: np.ndarray

    def __repr__(self):
        return (f"TestResult(name='{self.name}', M={self.M}, K={self.K}, N={self.N}, "
                f"ref_v{self.ref_version}, {self.err_func_name}: "
                f"max={np.max(self.error):.4f}, mean={np.mean(self.error):.4f})")


# =============================================================================
# Single Test Function
# =============================================================================

def run_single_test(
    name: str,
    impl_func: Callable,
    qdir: int,
    M: int = 8,
    K: int = 32,
    N: int = 32,
    seed: int = 200,
    ref_version: int = 1,
    err_func: Callable = None,
    err_name: str = 'ULP Error (FP16)',
    make_weight_odd: bool = False,
    visualize: bool = False,
    debug: bool = False
) -> TestResult:
    """
    Generic test function for any FPINT GEMM implementation.

    Args:
        name: Test name for display
        impl_func: Implementation function to test
        qdir: Quantization direction (QCOL or QROW)
        M, K, N: Matrix dimensions
        seed: Random seed for reproducibility
        ref_version: Reference version (1=FP16 bit-exact, 2=FP64 high-precision)
        err_func: Error function (ref, eval) -> error_matrix
        err_name: Name of the error function for display
        make_weight_odd: If True, convert weights to odd values (for zero-less encoding)
        visualize: Show heatmap visualization
        debug: Enable debug output

    Returns:
        TestResult with all data and error metrics
    """
    # Default error function
    if err_func is None:
        err_func = ulp_diff_fp16

    print("=" * 60)
    print(f"Test: {name} (ref_version={ref_version}, err={err_name})")
    print("=" * 60)

    # Determine scale/zero shape based on quantization direction
    if qdir == QCOL:
        KG = K // QBLOCK
        scale_shape = (KG, N)
        zero_shape = (KG, N)
        print(f"Dimensions: M={M}, K={K}, N={N}, KG={KG}")
    else:  # QROW
        NG = (N + QBLOCK - 1) // QBLOCK  # ceil division
        scale_shape = (K, NG)
        zero_shape = (K, NG)
        print(f"Dimensions: M={M}, K={K}, N={N}, NG={NG}")

    # Generate test data
    input_data = generate_random_fp16((M, K), value_range=(-2.0, 2.0), seed=seed)
    weight_data = generate_random_weights((K, N), w_width=4, seed=seed+1)
    if make_weight_odd:
        weight_data = weight_data * 2 + 1  # Make odd: 1, 3, 5, ..., 31
    scale_data = generate_random_fp16(scale_shape, value_range=(0.1, 1.0), seed=seed+2)
    zero_data = generate_random_zero_points(zero_shape, z_range=(-4, 4), seed=seed+3)

    # Run implementation
    output = impl_func(input_data, weight_data, scale_data, zero_data,
                       M, N, K, debug=debug)

    # Run reference
    output_ref = fpint_gemm_ref(input_data, weight_data, scale_data, zero_data,
                                M, N, K, qdir=qdir, version=ref_version, debug=debug)

    # Convert to float
    output_float = to_float_matrix(output)
    ref_float = to_float_matrix(output_ref)

    # Print error stats
    error = print_error_stats(f"{name} vs ref_v{ref_version}", output_float, ref_float, err_func, err_name)

    if visualize:
        plot_heatmap_comparison(
            ref_float,
            {name: output_float},
            diff_func=err_func,
            diff_func_name=err_name,
            title=f"{name} vs Reference (v{ref_version})",
            show=True,
            auto_scale=True,
            shared_scale=False
        )

    print("  PASSED")

    return TestResult(
        name=name,
        M=M, K=K, N=N, seed=seed,
        ref_version=ref_version,
        err_func_name=err_name,
        input_data=input_data,
        weight_data=weight_data,
        scale_data=scale_data,
        zero_data=zero_data,
        output=output,
        output_ref=output_ref,
        output_float=output_float,
        ref_float=ref_float,
        error=error
    )


# =============================================================================
# Run All Tests Function
# =============================================================================

def run_all_tests(
    M: int = 8,
    K: int = 32,
    N: int = 32,
    ref_version: int = 1,
    err_func: Callable = None,
    err_name: str = 'ULP Error (FP16)',
    visualize: bool = False,
    debug: bool = False
) -> Dict[str, TestResult]:
    """
    Run all 5 FPINT GEMM tests and return results.

    Args:
        M, K, N: Matrix dimensions
        ref_version: Reference version (1=FP16 bit-exact, 2=FP64 high-precision)
        err_func: Error function (ref, eval) -> error_matrix
        err_name: Name of the error function for display
        visualize: Show heatmap for each test
        debug: Enable debug output

    Returns:
        Dictionary mapping test name to TestResult
    """
    # Default error function
    if err_func is None:
        err_func = ulp_diff_fp16

    print("\n" + "=" * 60)
    print(f"FPINT GEMM INTEGRATION TEST SUITE")
    print(f"  ref_version={ref_version}, err_func={err_name}")
    print("=" * 60)

    results = {}

    # Test configurations: (name, impl_func, qdir, seed, make_weight_odd)
    test_configs = [
        ("qcol_2scomp", fpint_gemm_qcol_2scomp, QCOL, 200, False),
        ("qcol_zero_less", fpint_gemm_qcol_zero_less, QCOL, 210, True),
        ("qrow_2scomp", fpint_gemm_qrow_2scomp, QROW, 220, False),
        ("qrow_zero_less", fpint_gemm_qrow_zero_less, QROW, 230, True),
        ("qrow_real_2scomp", fpint_gemm_qrow_real_2scomp, QROW, 240, False),
    ]

    for name, impl_func, qdir, seed, make_weight_odd in test_configs:
        results[name] = run_single_test(
            name=name,
            impl_func=impl_func,
            qdir=qdir,
            M=M, K=K, N=N,
            seed=seed,
            ref_version=ref_version,
            err_func=err_func,
            err_name=err_name,
            make_weight_odd=make_weight_odd,
            visualize=visualize,
            debug=debug
        )

    # Print summary
    print("\n" + "=" * 60)
    print(f"Error Summary ({err_name}) - ref_version={ref_version}")
    print("=" * 60)

    for name, result in results.items():
        print(f"{name:20s}: Max={np.max(result.error):10.4f}, Mean={np.mean(result.error):10.4f}, Median={np.median(result.error):10.4f}")

    print("\n" + "=" * 60)
    print("ALL TESTS PASSED")
    print("=" * 60)

    return results


# =============================================================================
# Visualization Functions
# =============================================================================

def visualize_all_results(
    results: Dict[str, TestResult],
    title_suffix: str = "",
    cmap: str = "hot"
) -> plt.Figure:
    """
    Plot all errors in one figure.

    Args:
        results: Dictionary of test results
        title_suffix: Additional text to append to title
        cmap: Colormap for heatmaps

    Returns:
        matplotlib Figure object
    """
    fig, axes = plt.subplots(2, 3, figsize=(15, 10))
    axes_flat = axes.flatten()

    # Find global min/max for consistent colormap
    all_errors = [result.error for result in results.values()]
    global_vmin = min(np.min(e) for e in all_errors)
    global_vmax = max(np.max(e) for e in all_errors)

    for idx, (name, result) in enumerate(results.items()):
        ax = axes_flat[idx]
        err = result.error

        im = ax.imshow(err, aspect='auto', cmap=cmap, vmin=global_vmin, vmax=global_vmax)
        ax.set_title(f'{name}\n{result.err_func_name}: max={np.max(err):.2f}, mean={np.mean(err):.2f}')
        ax.set_xlabel('Column')
        ax.set_ylabel('Row')
        plt.colorbar(im, ax=ax, label=result.err_func_name)

    # Hide last subplot
    axes_flat[-1].axis('off')

    # Get dimensions from first result
    first_result = next(iter(results.values()))
    M, K, N = first_result.M, first_result.K, first_result.N
    ref_version = first_result.ref_version
    err_name = first_result.err_func_name

    fig.suptitle(f'All FPINT GEMM Implementations vs Reference (v{ref_version})\n'
                 f'(M={M}, K={K}, N={N}) - {err_name}{title_suffix}',
                fontsize=14, fontweight='bold')
    plt.tight_layout()

    return fig


def plot_error_histogram(
    results: Dict[str, TestResult],
    title_suffix: str = ""
) -> plt.Figure:
    """
    Plot histogram of errors for all implementations.

    Args:
        results: Dictionary of test results
        title_suffix: Additional text to append to title

    Returns:
        matplotlib Figure object
    """
    fig, axes = plt.subplots(2, 3, figsize=(15, 8))
    axes_flat = axes.flatten()

    for idx, (name, result) in enumerate(results.items()):
        ax = axes_flat[idx]
        err_flat = result.error.flatten()

        ax.hist(err_flat, bins=50, edgecolor='black', alpha=0.7)
        ax.axvline(np.mean(err_flat), color='r', linestyle='--', label=f'Mean={np.mean(err_flat):.2f}')
        ax.axvline(np.median(err_flat), color='g', linestyle='--', label=f'Median={np.median(err_flat):.2f}')
        ax.set_title(f'{name}')
        ax.set_xlabel(result.err_func_name)
        ax.set_ylabel('Count')
        ax.legend(fontsize=8)

    axes_flat[-1].axis('off')

    # Get info from first result
    first_result = next(iter(results.values()))
    ref_version = first_result.ref_version
    err_name = first_result.err_func_name

    fig.suptitle(f'{err_name} Distribution (ref_version={ref_version}){title_suffix}',
                fontsize=14, fontweight='bold')
    plt.tight_layout()

    return fig
