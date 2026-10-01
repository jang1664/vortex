# Four-profile PnR status

Stopped at user request: 2026-10-01T22:11:23.269742+09:00

| Profile | State |
|---|---|
| C1 | CANCELLED |
| C2 | CANCELLED |
| C3 | CANCELLED |
| C4 | CANCELLED |

All four execution sessions have zero remaining live processes. Periodic in-session monitoring stopped. Logs and build artifacts preserved; RTL and memory configs unchanged.

C2/C3 first attempts failed the SLR1 BRAM capacity DRC (585 RAMB36 required, 576 sites available); attempt2 with `--slr-floorplan 0` was stopped at user request.
