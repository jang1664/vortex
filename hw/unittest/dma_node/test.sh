#!/usr/bin/env bash
set -euo pipefail

make clean
make sim SIM_EXEC=vlt
