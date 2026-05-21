import multiprocessing
import os
import platform
import shutil
import subprocess
import sys
import sysconfig
from distutils.command.clean import clean

from setuptools import Extension, find_packages, setup


IS_DARWIN = platform.system() == "Darwin"
IS_WINDOWS = platform.system() == "Windows"
IS_LINUX = platform.system() == "Linux"

BASE_DIR = os.path.dirname(os.path.realpath(__file__))
RUN_BUILD_DEPS = any(arg in {"clean", "dist_info"} for arg in sys.argv)


def make_relative_rpath_args(path):
    if IS_DARWIN:
        return ["-Wl,-rpath,@loader_path/" + path]
    elif IS_WINDOWS:
        return []
    else:
        return ["-Wl,-rpath,$ORIGIN/" + path]


def get_pytorch_dir():
    os.environ["TORCH_DEVICE_BACKEND_AUTOLOAD"] = "0"
    import torch
    return os.path.dirname(os.path.realpath(torch.__file__))


def get_vortex_root():
    return os.environ.get("VORTEX_HOME", os.path.realpath(os.path.join(BASE_DIR, "..")))


def build_deps():
    build_dir = os.path.join(BASE_DIR, "build")
    os.makedirs(build_dir, exist_ok=True)

    vortex_root = get_vortex_root()
    vortex_build = os.path.join(vortex_root, "build")

    cmake_args = [
        "-DCMAKE_INSTALL_PREFIX=" + os.path.realpath(os.path.join(BASE_DIR, "torch_vortex")),
        "-DPYTHON_INCLUDE_DIR=" + sysconfig.get_paths().get("include"),
        "-DPYTORCH_INSTALL_DIR=" + get_pytorch_dir(),
        "-DVORTEX_HOME=" + vortex_root,
        "-DVORTEX_BUILD_DIR=" + vortex_build,
    ]

    # Parse CMAKE_ARGS environment variable if present
    cmake_args_env = os.environ.get("CMAKE_ARGS", "")
    if cmake_args_env:
        cmake_args.extend(cmake_args_env.split())

    subprocess.check_call(
        ["cmake", BASE_DIR] + cmake_args, cwd=build_dir, env=os.environ
    )

    build_args = [
        "--build", ".",
        "--target", "install",
        "--config", "Release",
        "--",
    ]

    if IS_WINDOWS:
        build_args += ["/m:" + str(multiprocessing.cpu_count())]
    else:
        build_args += ["-j", str(multiprocessing.cpu_count())]

    subprocess.check_call(["cmake"] + build_args, cwd=build_dir, env=os.environ)

    # Patch RPATH on the bundled Vortex runtime libs so they can find each
    # other via $ORIGIN (the torch_vortex/lib/ directory) without requiring
    # the user to set LD_LIBRARY_PATH.
    patch_vortex_rpath(os.path.join(BASE_DIR, "torch_vortex", "lib"))


def patch_vortex_rpath(lib_dir):
    """Set RPATH=$ORIGIN on all Vortex runtime .so files in *lib_dir*."""
    patchelf = shutil.which("patchelf")
    if not patchelf:
        print("WARNING: patchelf not found — skipping RPATH patching. "
              "You may need to set LD_LIBRARY_PATH at runtime.")
        return
    for fname in os.listdir(lib_dir):
        if fname.endswith(".so") and fname.startswith("lib"):
            fpath = os.path.join(lib_dir, fname)
            try:
                subprocess.check_call(
                    [patchelf, "--set-rpath", "$ORIGIN", fpath],
                    stderr=subprocess.DEVNULL,
                )
            except subprocess.CalledProcessError:
                pass  # some files may not be ELF


class BuildClean(clean):
    def run(self):
        for i in ["build", "install", "torch_vortex/lib"]:
            dirs = os.path.join(BASE_DIR, i)
            if os.path.exists(dirs) and os.path.isdir(dirs):
                shutil.rmtree(dirs)

        for dirpath, _, filenames in os.walk(os.path.join(BASE_DIR, "torch_vortex")):
            for filename in filenames:
                if filename.endswith(".so"):
                    os.remove(os.path.join(dirpath, filename))


def main():
    if not RUN_BUILD_DEPS:
        build_deps()

    extra_link_args = [*make_relative_rpath_args("lib")]
    extra_compile_args = [
        "-Wall",
        "-Wextra",
        "-Wno-strict-overflow",
        "-Wno-unused-parameter",
        "-Wno-missing-field-initializers",
        "-Wno-unknown-pragmas",
        "-fno-strict-aliasing",
    ]

    ext_modules = [
        Extension(
            name="torch_vortex._C",
            sources=["torch_vortex/csrc/stub.c"],
            language="c",
            extra_compile_args=extra_compile_args,
            libraries=["torch_vortex_bindings"],
            library_dirs=[os.path.join(BASE_DIR, "torch_vortex/lib")],
            extra_link_args=extra_link_args,
        )
    ]

    package_data = {
        "torch_vortex": [
            "lib/*.so*",
            "lib/*.dylib*",
            "kernels/*.vxbin",
        ]
    }

    setup(
        packages=find_packages(),
        package_data=package_data,
        ext_modules=ext_modules,
        cmdclass={
            "clean": BuildClean,
        },
        include_package_data=False,
        entry_points={
            "torch.backends": [
                "torch_vortex = torch_vortex:_autoload",
            ],
        },
    )


if __name__ == "__main__":
    main()
