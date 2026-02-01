# Vortex PyTorch Extension
# Python bindings for Vortex GPU kernels

import os
import torch
import glob

from setuptools import find_packages, setup
from torch.utils.cpp_extension import CppExtension, BuildExtension

library_name = "vortex_torch"

def get_extensions():
    debug_mode = os.getenv("DEBUG", "0") == "1"
    
    # Vortex paths
    vortex_root = os.environ.get("VORTEX_HOME", "/root/workspace/vortex")
    vortex_build = os.path.join(vortex_root, "build")
    vortex_runtime = os.path.join(vortex_build, "runtime")
    
    extra_link_args = [
        f"-L{vortex_runtime}",
        "-lvortex",
        f"-Wl,-rpath,{vortex_runtime}",
    ]
    extra_compile_args = {
        "cxx": [
            "-O3" if not debug_mode else "-O0",
            "-fdiagnostics-color=always",
            "-std=c++17",
        ],
    }
    
    if debug_mode:
        extra_compile_args["cxx"].append("-g")
        extra_link_args.extend(["-O0", "-g"])
    
    # Use relative paths for sources (required for editable installs)
    sources = ["csrc/vortex_ops.cpp"]
    
    include_dirs = [
        os.path.join(vortex_root, "runtime", "include"),
        os.path.join(vortex_build, "hw"),
        os.path.join(vortex_root, "sim", "common"),
    ]
    
    ext_modules = [
        CppExtension(
            f"{library_name}._C",
            sources,
            include_dirs=include_dirs,
            extra_compile_args=extra_compile_args,
            extra_link_args=extra_link_args,
        )
    ]
    
    return ext_modules


setup(
    name=library_name,
    version="0.1.0",
    packages=find_packages(),
    ext_modules=get_extensions(),
    install_requires=["torch"],
    description="PyTorch bindings for Vortex GPU kernels",
    cmdclass={"build_ext": BuildExtension},
)
