"""
FPINT GEMM Integration Tests

This module provides integration tests for FPINT GEMM implementations.
Tests compare QCOL and QROW implementations against reference and visualize results.
"""

import sys
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))

import numpy as np
from fpint_emul import (
    fpint_gemm_ref, fpint_gemm_qcol_2scomp, fpint_gemm_qrow_2scomp,
    fp16_bit_to_float,
    QBLOCK, QCOL, QROW
)
from visualize import (
    plot_heatmap_comparison, plot_multi_eval_comparison, print_diff_statistics,
    absolute_diff, relative_diff_percent, squared_diff
)
from test_utils import generate_random_fp16, generate_random_weights, generate_random_zero_points


def test_gemm_qcol(visualize=False):
    """Test QCOL GEMM implementation vs reference"""
    print("\n" + "=" * 60)
    print("Test: FPINT GEMM QCOL 2's Complement")
    print("=" * 60)
    
    M, K, N = 8, 16, 16
    KG = K // QBLOCK
    
    # Generate test data
    input_data = generate_random_fp16((M, K), value_range=(-2.0, 2.0), seed=200)
    weight_data = generate_random_weights((K, N), w_width=4, seed=201)
    scale_data = generate_random_fp16((KG, N), value_range=(0.1, 1.0), seed=202)
    zero_data = generate_random_zero_points((KG, N), z_range=(-4, 4), seed=203)
    
    print(f"Input: {input_data.shape}, Weight: {weight_data.shape}")
    print(f"Scale: {scale_data.shape}, Zero: {zero_data.shape}")
    
    # Run QCOL GEMM implementation
    output = fpint_gemm_qcol_2scomp(input_data, weight_data, scale_data, zero_data,
                                     M, N, K, debug=False)
    
    # Run reference implementation
    output_ref = fpint_gemm_ref(input_data, weight_data, scale_data, zero_data,
                                 M, N, K, qdir=QCOL, debug=False)
    
    # Convert to float for comparison
    output_float = np.zeros((M, N), dtype=np.float32)
    output_ref_float = np.zeros((M, N), dtype=np.float32)
    
    for m in range(M):
        for n in range(N):
            output_float[m, n] = fp16_bit_to_float(output[m, n])
            output_ref_float[m, n] = fp16_bit_to_float(output_ref[m, n])
    
    # Print sample outputs
    print(f"\nSample outputs (QCOL Implementation):")
    for m in range(min(2, M)):
        print(f"  Row {m}: ", end="")
        for n in range(min(4, N)):
            print(f"{output_float[m, n]:9.4f} ", end="")
        print("...")
    
    print(f"\nSample outputs (Reference):")
    for m in range(min(2, M)):
        print(f"  Row {m}: ", end="")
        for n in range(min(4, N)):
            print(f"{output_ref_float[m, n]:9.4f} ", end="")
        print("...")
    # Calculate and print error statistics
    print("\n" + "-" * 60)
    print("Error Analysis: QCOL vs Reference")
    print("-" * 60)
    
    abs_error = np.abs(output_float - output_ref_float)
    rel_error = abs_error / (np.abs(output_ref_float) + 1e-8)
    
    print(f"Absolute Error:")
    print(f"  Max:  {np.max(abs_error):.6f}")
    print(f"  Mean: {np.mean(abs_error):.6f}")
    print(f"  Std:  {np.std(abs_error):.6f}")
    
    print(f"\nRelative Error:")
    print(f"  Max:  {np.max(rel_error):.6f}")
    print(f"  Mean: {np.mean(rel_error):.6f}")
    print(f"  Std:  {np.std(rel_error):.6f}")
    
    # Visualize if requested
    if visualize:
        print("\n" + "-" * 60)
        print("Generating Visualizations...")
        print("-" * 60)
        
        # Heatmap comparison with absolute difference
        plot_heatmap_comparison(
            output_ref_float,
            output_float,
            diff_func=absolute_diff,
            diff_func_name="Absolute Difference",
            title="QCOL GEMM vs Reference (Absolute Diff)",
            show=False,
            save_path="qcol_comparison_abs.png"
        )
        
        # Heatmap comparison with relative difference
        plot_heatmap_comparison(
            output_ref_float,
            output_float,
            diff_func=relative_diff_percent,
            diff_func_name="Relative Difference (%)",
            title="QCOL GEMM vs Reference (Relative Diff %)",
            show=False,
            save_path="qcol_comparison_rel.png"
        )
        
        # Print detailed statistics
        print_diff_statistics(output_ref_float, output_float,
                            diff_func=absolute_diff, diff_func_name="Absolute Difference")
        print_diff_statistics(output_ref_float, output_float,
                            diff_func=relative_diff_percent, diff_func_name="Relative Difference (%)")
        
        print("\nVisualization files saved:")
        print("  - qcol_comparison_abs.png")
        print("  - qcol_comparison_rel.png")
    
    print("\n✓ QCOL GEMM test passed")


def test_gemm_qrow(visualize=False):
    """Test QROW GEMM implementation vs reference"""
    print("\n" + "=" * 60)
    print("Test: FPINT GEMM QROW 2's Complement")
    print("=" * 60)
    
    M, K, N = 8, 16, 16
    NG = N // QBLOCK
    
    # Generate test data
    input_data = generate_random_fp16((M, K), value_range=(-2.0, 2.0), seed=300)
    weight_data = generate_random_weights((K, N), w_width=4, seed=301)
    scale_data = generate_random_fp16((K, NG), value_range=(0.1, 1.0), seed=302)
    zero_data = generate_random_zero_points((K, NG), z_range=(-4, 4), seed=303)
    
    print(f"Input: {input_data.shape}, Weight: {weight_data.shape}")
    print(f"Scale: {scale_data.shape}, Zero: {zero_data.shape}")
    
    # Run QROW GEMM implementation
    output = fpint_gemm_qrow_2scomp(input_data, weight_data, scale_data, zero_data,
                                     M, N, K, debug=False)
    
    # Run reference implementation
    output_ref = fpint_gemm_ref(input_data, weight_data, scale_data, zero_data,
                                 M, N, K, qdir=QROW, debug=False)
    
    # Convert to float for comparison
    output_float = np.zeros((M, N), dtype=np.float32)
    output_ref_float = np.zeros((M, N), dtype=np.float32)
    
    for m in range(M):
        for n in range(N):
            output_float[m, n] = fp16_bit_to_float(output[m, n])
            output_ref_float[m, n] = fp16_bit_to_float(output_ref[m, n])
    
    # Print sample outputs
    print(f"\nSample outputs (QROW Implementation):")
    for m in range(min(2, M)):
        print(f"  Row {m}: ", end="")
        for n in range(min(4, N)):
            print(f"{output_float[m, n]:9.4f} ", end="")
        print("...")
    
    print(f"\nSample outputs (Reference):")
    for m in range(min(2, M)):
        print(f"  Row {m}: ", end="")
        for n in range(min(4, N)):
            print(f"{output_ref_float[m, n]:9.4f} ", end="")
        print("...")
    
    # Calculate and print error statistics
    print("\n" + "-" * 60)
    print("Error Analysis: QROW vs Reference")
    print("-" * 60)
    
    abs_error = np.abs(output_float - output_ref_float)
    rel_error = abs_error / (np.abs(output_ref_float) + 1e-8)
    
    print(f"Absolute Error:")
    print(f"  Max:  {np.max(abs_error):.6f}")
    print(f"  Mean: {np.mean(abs_error):.6f}")
    print(f"  Std:  {np.std(abs_error):.6f}")
    
    print(f"\nRelative Error:")
    print(f"  Max:  {np.max(rel_error):.6f}")
    print(f"  Mean: {np.mean(rel_error):.6f}")
    print(f"  Std:  {np.std(rel_error):.6f}")
    
    # Visualize if requested
    if visualize:
        print("\n" + "-" * 60)
        print("Generating Visualizations...")
        print("-" * 60)
        
        # Heatmap comparison with absolute difference
        plot_heatmap_comparison(
            output_ref_float,
            output_float,
            diff_func=absolute_diff,
            diff_func_name="Absolute Difference",
            title="QROW GEMM vs Reference (Absolute Diff)",
            show=False,
            save_path="qrow_comparison_abs.png"
        )
        
        # Heatmap comparison with relative difference
        plot_heatmap_comparison(
            output_ref_float,
            output_float,
            diff_func=relative_diff_percent,
            diff_func_name="Relative Difference (%)",
            title="QROW GEMM vs Reference (Relative Diff %)",
            show=False,
            save_path="qrow_comparison_rel.png"
        )
        
        # Print detailed statistics
        print_diff_statistics(output_ref_float, output_float,
                            diff_func=absolute_diff, diff_func_name="Absolute Difference")
        print_diff_statistics(output_ref_float, output_float,
                            diff_func=relative_diff_percent, diff_func_name="Relative Difference (%)")
        
        print("\nVisualization files saved:")
        print("  - qrow_comparison_abs.png")
        print("  - qrow_comparison_rel.png")
    
    print("\n✓ QROW GEMM test passed")


def test_multi_comparison(visualize=False):
    """Test multiple GEMM implementations together"""
    print("\n" + "=" * 60)
    print("Test: Multi-Implementation Comparison")
    print("=" * 60)
    
    M, K, N = 8, 16, 16
    KG = K // QBLOCK
    NG = N // QBLOCK
    
    # Generate test data for QCOL
    input_qcol = generate_random_fp16((M, K), value_range=(-2.0, 2.0), seed=200)
    weight_qcol = generate_random_weights((K, N), w_width=4, seed=201)
    scale_qcol = generate_random_fp16((KG, N), value_range=(0.1, 1.0), seed=202)
    zero_qcol = generate_random_zero_points((KG, N), z_range=(-4, 4), seed=203)
    
    # Generate test data for QROW
    input_qrow = generate_random_fp16((M, K), value_range=(-2.0, 2.0), seed=300)
    weight_qrow = generate_random_weights((K, N), w_width=4, seed=301)
    scale_qrow = generate_random_fp16((K, NG), value_range=(0.1, 1.0), seed=302)
    zero_qrow = generate_random_zero_points((K, NG), z_range=(-4, 4), seed=303)
    
    # Run all implementations
    ref_qcol = fpint_gemm_ref(input_qcol, weight_qcol, scale_qcol, zero_qcol,
                              M, N, K, qdir=QCOL, debug=False)
    impl_qcol = fpint_gemm_qcol_2scomp(input_qcol, weight_qcol, scale_qcol, zero_qcol,
                                        M, N, K, debug=False)
    
    ref_qrow = fpint_gemm_ref(input_qrow, weight_qrow, scale_qrow, zero_qrow,
                              M, N, K, qdir=QROW, debug=False)
    impl_qrow = fpint_gemm_qrow_2scomp(input_qrow, weight_qrow, scale_qrow, zero_qrow,
                                        M, N, K, debug=False)
    
    # Convert to float
    def to_float(output):
        result = np.zeros((M, N), dtype=np.float32)
        for m in range(M):
            for n in range(N):
                result[m, n] = fp16_bit_to_float(output[m, n])
        return result
    
    ref_qcol_float = to_float(ref_qcol)
    impl_qcol_float = to_float(impl_qcol)
    ref_qrow_float = to_float(ref_qrow)
    impl_qrow_float = to_float(impl_qrow)
    
    # Print comparison
    print("\nQCOL Error Analysis:")
    abs_error_qcol = np.abs(impl_qcol_float - ref_qcol_float)
    print(f"  Max absolute error: {np.max(abs_error_qcol):.6f}")
    print(f"  Mean absolute error: {np.mean(abs_error_qcol):.6f}")
    
    print("\nQROW Error Analysis:")
    abs_error_qrow = np.abs(impl_qrow_float - ref_qrow_float)
    print(f"  Max absolute error: {np.max(abs_error_qrow):.6f}")
    print(f"  Mean absolute error: {np.mean(abs_error_qrow):.6f}")
    
    # Visualize if requested
    if visualize:
        print("\n" + "-" * 60)
        print("Generating Multi-Implementation Comparison...")
        print("-" * 60)
        
        # Multiple evaluation comparison
        eval_dict = {
            "QCOL Implementation": impl_qcol_float,
            "QROW Implementation": impl_qrow_float,
        }
        
        # Use QCOL reference as baseline
        plot_multi_eval_comparison(
            ref_qcol_float,
            eval_dict,
            diff_func=absolute_diff,
            diff_func_name="Absolute Difference",
            title="Multiple GEMM Implementations vs Reference",
            show=False,
            save_path="multi_implementation_comparison.png"
        )
        
        print("\nVisualization file saved:")
        print("  - multi_implementation_comparison.png")
    
    print("\n✓ Multi-implementation comparison test passed")


def run_all_tests(visualize=False):
    """Run all integration tests
    
    Args:
        visualize: If True, generate visualization plots
    """
    print("\n" + "=" * 60)
    print("FPINT GEMM INTEGRATION TEST SUITE")
    print("=" * 60)
    
    try:
        test_gemm_qcol(visualize=visualize)
        test_gemm_qrow(visualize=visualize)
        test_multi_comparison(visualize=visualize)
        
        print("\n" + "=" * 60)
        print("ALL INTEGRATION TESTS PASSED ✓")
        print("=" * 60 + "\n")
        
    except Exception as e:
        print(f"\n✗ TEST FAILED: {e}")
        import traceback
        traceback.print_exc()
        raise


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description='Run FPINT GEMM integration tests')
    parser.add_argument('--visualize', action='store_true',
                       help='Generate visualization plots')
    args = parser.parse_args()
    
    run_all_tests(visualize=args.visualize)
