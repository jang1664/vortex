import subprocess
import os
import shutil
import sys
import time

SIMV_DIR = os.path.join("sim", "xrtsim_vcs")
FSDB_NAME = "vcs_cosim.fsdb"

def fsdb_wait_timeout():
  try:
    return int(os.environ.get("FSDB_WAIT_TIMEOUT_S", "1800"))
  except ValueError:
    return 1800

def is_fsdb_sidecar_name(name):
  return name.startswith("fsdb.") or ".fsdb." in name

def fsdb_sidecars(simv_dir):
  if not os.path.isdir(simv_dir):
    return []
  return [
      os.path.join(simv_dir, name)
      for name in os.listdir(simv_dir)
      if is_fsdb_sidecar_name(name)
  ]

def remove_path(path):
  if not os.path.exists(path):
    return
  if os.path.isdir(path) and not os.path.islink(path):
    shutil.rmtree(path)
  else:
    os.remove(path)

def clean_stale_fsdb(simv_dir):
  remove_path(os.path.join(simv_dir, FSDB_NAME))
  for path in fsdb_sidecars(simv_dir):
    remove_path(path)

def fsdb_closed_in_log(simv_dir):
  log_path = os.path.join(simv_dir, "novas_dump.log")
  if not os.path.exists(log_path):
    return True
  with open(log_path, "r", errors="ignore") as f:
    return "FSDB closed." in f.read()

def wait_for_fsdb_complete(simv_dir, timeout_s=None, poll_s=2, stable_polls=3):
  timeout_s = fsdb_wait_timeout() if timeout_s is None else timeout_s
  fsdb_path = os.path.join(simv_dir, FSDB_NAME)
  deadline = time.monotonic() + timeout_s
  last_size = None
  stable_count = 0
  last_report = 0

  print(f"Waiting for FSDB dump to finish: {fsdb_path}", flush=True)
  while True:
    exists = os.path.exists(fsdb_path)
    size = os.path.getsize(fsdb_path) if exists else None
    sidecars = fsdb_sidecars(simv_dir)
    closed = fsdb_closed_in_log(simv_dir)

    if exists and size == last_size:
      stable_count += 1
    else:
      stable_count = 0
    last_size = size

    if exists and closed and not sidecars and stable_count >= stable_polls:
      print(f"FSDB ready: {fsdb_path} ({size} bytes)", flush=True)
      return

    now = time.monotonic()
    if now >= deadline:
      sidecar_names = ", ".join(os.path.basename(path) for path in sidecars) or "none"
      raise TimeoutError(
          f"Timed out waiting for FSDB dump to finish: "
          f"exists={exists}, closed={closed}, size={size}, sidecars={sidecar_names}"
      )

    if now - last_report >= 30:
      sidecar_names = ", ".join(os.path.basename(path) for path in sidecars) or "none"
      print(
          f"  FSDB wait: exists={exists}, closed={closed}, "
          f"size={size}, stable={stable_count}/{stable_polls}, "
          f"sidecars={sidecar_names}",
          flush=True,
      )
      last_report = now

    time.sleep(poll_s)

def ignore_copy_artifacts(dirpath, names):
  ignored = set()
  for name in names:
    path = os.path.join(dirpath, name)
    if name.startswith(".verdi_"):
      ignored.add(name)
    elif os.path.islink(path) and not os.path.exists(path):
      ignored.add(name)
  return ignored

def copy_simv_dir(src, dst):
  remove_path(dst)
  shutil.copytree(
      src,
      dst,
      ignore=ignore_copy_artifacts,
      ignore_dangling_symlinks=True,
  )

def run(app, m, k, n, tag, extra_flags=None, extra_configs=None):
  extra_flags = extra_flags or []
  extra_configs = extra_configs or []
  cmd = [
      sys.executable,
      "ci/run_black.py",
      "xrt-vcs-sim",
      f"--app={app}",
      "--debug=0",
      f"--args=-m {m} -k {k} -n {n}",
      "--perf=3",
      *extra_flags,
  ]
  env = os.environ.copy()
  if extra_configs:
    configs = [env.get("CONFIGS", "").strip(), *extra_configs]
    env["CONFIGS"] = " ".join(config for config in configs if config)
  clean_stale_fsdb(SIMV_DIR)
  rc = subprocess.call(cmd, env=env)
  if rc != 0:
    raise RuntimeError(f"run failed for {tag}: rc={rc}")
  wait_for_fsdb_complete(SIMV_DIR)
  os.makedirs(f"logs/{tag}", exist_ok=True)
  subprocess.call(f"mv run.log logs/{tag}/", shell=True)
  dst_simv_dir = os.path.join("logs", tag, "xrtsim_vcs")
  copy_simv_dir(SIMV_DIR, dst_simv_dir)
  app_dir = os.path.join("tests", "regression", app)
  for artifact in ("kernel.elf", "kernel.dump"):
    artifact_path = os.path.join(app_dir, artifact)
    if os.path.exists(artifact_path):
      subprocess.call(["cp", artifact_path, f"logs/{tag}/{artifact}"])

if __name__ == "__main__":
  os.chdir(os.path.dirname(os.path.abspath(__file__)))
  os.makedirs(f"logs", exist_ok=True)
  subprocess.call("make clean-app", shell=True)

  fpint_cases = [
      # (256, 4096, 4096),
      # (256, 1024, 1024),
      # (1, 128, 64),
      # (1, 128, 128),
      # (1, 256, 256),
      # (256, 128, 128),
      # (256, 256, 256),
  ]
  sgemm_tcu_cases = [
      # sgemm_tcu requires M/N/K to be multiples of its WMMA tile dimensions.
      (8, 128, 64),
      # (8, 32, 32),
      # (8, 256, 256),
      # (64, 64, 64),
      # (256, 128, 128),
  ]
  sgemm_tcu_b_col_major_cases = [
      # Compare against the row-major B path above. This stores B in col-major
      # on the device and uses load_matrix_sync<col_major> in the kernel.
      # (64, 64, 64),
  ]

  for m, k, n in fpint_cases:
    run(
        app="fpint_gemm_ffn_hw",
        m=m,
        k=k,
        n=n,
        tag=f"fpint_naive_m{m}_k{k}_n{n}",
    )

  for m, k, n in sgemm_tcu_cases:
    run(
        app="sgemm_tcu",
        m=m,
        k=k,
        n=n,
        tag=f"sgemm_tcu_m{m}_k{k}_n{n}",
        extra_flags=["--tcu_enable"],
    )

  for m, k, n in sgemm_tcu_b_col_major_cases:
    run(
        app="sgemm_tcu",
        m=m,
        k=k,
        n=n,
        tag=f"sgemm_tcu_bcol_m{m}_k{k}_n{n}",
        extra_flags=["--tcu_enable"],
        extra_configs=["-DB_COL_MAJOR=1"],
    )
