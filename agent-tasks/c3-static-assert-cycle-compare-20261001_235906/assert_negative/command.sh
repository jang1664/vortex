set -e
source /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/agent-tasks/c3-static-assert-cycle-compare-20261001_235906/config_invalid.sh
make -C hw config
make -C sim/xrtsim_vcs simv CONFIGS="$CONFIGS"
