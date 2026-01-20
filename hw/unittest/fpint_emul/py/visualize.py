"""
Visualization utilities for FPINT GEMM Emulation

This module provides visualization functions for comparing reference and
evaluated GEMM results using heatmaps.
"""

import numpy as np
import matplotlib.pyplot as plt
from typing import Callable, Dict, Union, Optional, Tuple


# Predefined difference functions
def absolute_diff(ref: np.ndarray, eval: np.ndarray) -> np.ndarray:
    """Calculate absolute difference between reference and evaluation"""
    return np.abs(ref - eval)


def relative_diff(ref: np.ndarray, eval: np.ndarray, epsilon: float = 1e-8) -> np.ndarray:
    """
    Calculate relative difference between reference and evaluation
    
    Args:
        ref: Reference values
        eval: Evaluation values
        epsilon: Small value to prevent division by zero
    
    Returns:
        Relative difference as percentage
    """
    return np.abs(ref - eval) / (np.abs(ref) + epsilon)


def relative_diff_percent(ref: np.ndarray, eval: np.ndarray, epsilon: float = 1e-8) -> np.ndarray:
    """Calculate relative difference as percentage"""
    return 100.0 * relative_diff(ref, eval, epsilon)


def squared_diff(ref: np.ndarray, eval: np.ndarray) -> np.ndarray:
    """Calculate squared difference (useful for MSE visualization)"""
    return (ref - eval) ** 2


def log_absolute_diff(ref: np.ndarray, eval: np.ndarray, epsilon: float = 1e-10) -> np.ndarray:
    """Calculate log of absolute difference (useful for large value ranges)"""
    abs_diff = np.abs(ref - eval)
    return np.log10(abs_diff + epsilon)


def plot_heatmap_comparison(
    ref_value: np.ndarray,
    eval_val: Union[np.ndarray, Dict[str, np.ndarray]],
    diff_func: Callable[[np.ndarray, np.ndarray], np.ndarray] = absolute_diff,
    diff_func_name: str = "Absolute Difference",
    title: Optional[str] = None,
    figsize: Tuple[int, int] = (15, 5),
    cmap: str = "RdYlGn_r",
    save_path: Optional[str] = None,
    show: bool = True,
    vmin: Optional[float] = None,
    vmax: Optional[float] = None
) -> plt.Figure:
    """
    Plot heatmap comparison between reference and evaluation values
    
    Args:
        ref_value: Reference matrix values (M x N)
        eval_val: Evaluation matrix values or dict of evaluation matrices
        diff_func: Function to calculate difference (signature: func(ref, eval) -> diff)
        diff_func_name: Name of the difference function for labeling
        title: Overall title for the figure
        figsize: Figure size (width, height)
        cmap: Colormap for heatmap
        save_path: Path to save the figure (if None, won't save)
        show: Whether to display the plot
        vmin: Minimum value for colorbar
        vmax: Maximum value for colorbar
    
    Returns:
        matplotlib Figure object
    """
    # Handle dict input for eval_val
    if isinstance(eval_val, dict):
        # Use the first key's value as the main eval
        first_key = list(eval_val.keys())[0]
        eval_matrix = eval_val[first_key]
        eval_label = first_key
    else:
        eval_matrix = eval_val
        eval_label = "Evaluation"
    
    # Calculate difference
    diff_matrix = diff_func(ref_value, eval_matrix)
    
    # Create figure with subplots
    fig, axes = plt.subplots(1, 3, figsize=figsize)
    
    # Plot 1: Reference values
    im1 = axes[0].imshow(ref_value, aspect='auto', cmap='viridis')
    axes[0].set_title('Reference Values')
    axes[0].set_xlabel('Column')
    axes[0].set_ylabel('Row')
    plt.colorbar(im1, ax=axes[0])
    
    # Plot 2: Evaluation values
    im2 = axes[1].imshow(eval_matrix, aspect='auto', cmap='viridis')
    axes[1].set_title(f'{eval_label} Values')
    axes[1].set_xlabel('Column')
    axes[1].set_ylabel('Row')
    plt.colorbar(im2, ax=axes[1])
    
    # Plot 3: Difference heatmap
    im3 = axes[2].imshow(diff_matrix, aspect='auto', cmap=cmap, vmin=vmin, vmax=vmax)
    axes[2].set_title(f'{diff_func_name}')
    axes[2].set_xlabel('Column')
    axes[2].set_ylabel('Row')
    plt.colorbar(im3, ax=axes[2])
    
    # Overall title
    if title:
        fig.suptitle(title, fontsize=14, fontweight='bold')
    
    plt.tight_layout()
    
    # Save if path provided
    if save_path:
        plt.savefig(save_path, dpi=300, bbox_inches='tight')
        print(f"Figure saved to: {save_path}")
    
    # Show if requested
    if show:
        plt.show()
    
    return fig


def plot_multi_eval_comparison(
    ref_value: np.ndarray,
    eval_dict: Dict[str, np.ndarray],
    diff_func: Callable[[np.ndarray, np.ndarray], np.ndarray] = absolute_diff,
    diff_func_name: str = "Absolute Difference",
    title: Optional[str] = None,
    figsize: Optional[Tuple[int, int]] = None,
    cmap: str = "RdYlGn_r",
    save_path: Optional[str] = None,
    show: bool = True,
    vmin: Optional[float] = None,
    vmax: Optional[float] = None
) -> plt.Figure:
    """
    Plot comparison of reference with multiple evaluation results
    
    Args:
        ref_value: Reference matrix values (M x N)
        eval_dict: Dictionary of evaluation matrices {name: matrix}
        diff_func: Function to calculate difference
        diff_func_name: Name of the difference function for labeling
        title: Overall title for the figure
        figsize: Figure size (width, height), auto-calculated if None
        cmap: Colormap for difference heatmaps
        save_path: Path to save the figure
        show: Whether to display the plot
        vmin: Minimum value for difference colorbar
        vmax: Maximum value for difference colorbar
    
    Returns:
        matplotlib Figure object
    """
    n_evals = len(eval_dict)
    
    # Auto-calculate figure size if not provided
    if figsize is None:
        figsize = (5 * (n_evals + 1), 5)
    
    # Create figure with subplots (1 for ref + n for each eval)
    fig, axes = plt.subplots(1, n_evals + 1, figsize=figsize)
    
    if n_evals == 1:
        axes = [axes[0], axes[1]]
    
    # Plot reference
    im_ref = axes[0].imshow(ref_value, aspect='auto', cmap='viridis')
    axes[0].set_title('Reference Values')
    axes[0].set_xlabel('Column')
    axes[0].set_ylabel('Row')
    plt.colorbar(im_ref, ax=axes[0])
    
    # Plot each evaluation difference
    for idx, (name, eval_matrix) in enumerate(eval_dict.items(), start=1):
        diff_matrix = diff_func(ref_value, eval_matrix)
        
        im = axes[idx].imshow(diff_matrix, aspect='auto', cmap=cmap, vmin=vmin, vmax=vmax)
        axes[idx].set_title(f'{name}\n{diff_func_name}')
        axes[idx].set_xlabel('Column')
        axes[idx].set_ylabel('Row')
        plt.colorbar(im, ax=axes[idx])
    
    # Overall title
    if title:
        fig.suptitle(title, fontsize=14, fontweight='bold')
    
    plt.tight_layout()
    
    # Save if path provided
    if save_path:
        plt.savefig(save_path, dpi=300, bbox_inches='tight')
        print(f"Figure saved to: {save_path}")
    
    # Show if requested
    if show:
        plt.show()
    
    return fig


def print_diff_statistics(
    ref_value: np.ndarray,
    eval_val: Union[np.ndarray, Dict[str, np.ndarray]],
    diff_func: Callable[[np.ndarray, np.ndarray], np.ndarray] = absolute_diff,
    diff_func_name: str = "Absolute Difference"
) -> None:
    """
    Print statistical summary of differences
    
    Args:
        ref_value: Reference matrix values
        eval_val: Evaluation matrix values or dict of evaluation matrices
        diff_func: Function to calculate difference
        diff_func_name: Name of the difference function for labeling
    """
    print("\n" + "=" * 60)
    print(f"Difference Statistics: {diff_func_name}")
    print("=" * 60)
    
    # Handle dict input
    if isinstance(eval_val, dict):
        for name, eval_matrix in eval_val.items():
            diff_matrix = diff_func(ref_value, eval_matrix)
            print(f"\n{name}:")
            print(f"  Max:  {np.max(diff_matrix):.6e}")
            print(f"  Min:  {np.min(diff_matrix):.6e}")
            print(f"  Mean: {np.mean(diff_matrix):.6e}")
            print(f"  Std:  {np.std(diff_matrix):.6e}")
            print(f"  Median: {np.median(diff_matrix):.6e}")
    else:
        diff_matrix = diff_func(ref_value, eval_val)
        print(f"  Max:  {np.max(diff_matrix):.6e}")
        print(f"  Min:  {np.min(diff_matrix):.6e}")
        print(f"  Mean: {np.mean(diff_matrix):.6e}")
        print(f"  Std:  {np.std(diff_matrix):.6e}")
        print(f"  Median: {np.median(diff_matrix):.6e}")
    
    print("=" * 60)
