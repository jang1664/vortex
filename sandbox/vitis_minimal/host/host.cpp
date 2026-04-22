// Minimal XRT host: load the xclbin, create the kernel handle, optionally
// start it, and exit. Enough to trigger hw_emu simv startup so the time-0
// initial blocks (including the bind-injected $fsdbDump* calls) fire and
// the FSDB file is written before the emulation is torn down.

#include <xrt/xrt_bo.h>
#include <xrt/xrt_device.h>
#include <xrt/xrt_kernel.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <thread>

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <xclbin>\n", argv[0]);
        return 2;
    }
    const char* xclbin_path = argv[1];

    std::cout << "host: opening device 0\n";
    xrt::device dev{0};

    std::cout << "host: loading xclbin " << xclbin_path << "\n";
    auto uuid = dev.load_xclbin(xclbin_path);

    std::cout << "host: creating kernel handle vortex_afu\n";
    xrt::kernel k{dev, uuid, "vortex_afu"};

    // Allocate a small dummy buffer for MEM_0. Not exercised by the stub
    // kernel (AXI master is tied off), but the kernel's register map
    // expects one pointer arg.
    xrt::bo dummy(dev, 4096, k.group_id(0));
    dummy.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    std::cout << "host: starting kernel with dummy buffer\n";
    auto run = k(dummy);

    // Give simv a generous window to elaborate and write the FSDB. The
    // kernel itself holds ap_done within a few cycles of ap_start, but
    // emulation cold-start dominates wall-clock here.
    std::cout << "host: waiting up to 30s for ap_done\n";
    auto state = run.wait(std::chrono::seconds(30));
    std::cout << "host: run.wait returned state=" << static_cast<int>(state) << "\n";

    // Even if we timed out, the FSDB should already be on disk (it's written
    // at sim time 0). Let simv finish flushing.
    std::this_thread::sleep_for(std::chrono::seconds(1));

    std::cout << "host: done\n";
    return 0;
}
