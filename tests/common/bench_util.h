#pragma once

// Minimal header-only benchmark helpers for tests/regression/<app>/bench_main.cpp.
//
// Usage sketch:
//   #include "bench_util.h"
//   int main(int argc, char** argv) {
//     auto bench = vx_bench::parse(argc, argv);   // strips --warmup/--iterations/--csv/--output(-append) from argv
//     // ... existing setup, allocations, kernel arg upload ...
//     for (int i = 0; i < bench.warmup; ++i) {
//       vx_start(...); vx_ready_wait(...);
//     }
//     vx_bench::Stats stats;
//     for (int i = 0; i < bench.iterations; ++i) {
//       vx_bench::Stopwatch sw; sw.start();
//       vx_start(...); vx_ready_wait(...);
//       stats.record(sw.stop_us());
//     }
//     // Honors bench.output (--output=PATH) / bench.output_append (--output-append).
//     // Falls back to stdout when --output is not given.
//     stats.report("softmax", bench);
//   }

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <fcntl.h>
#include <limits>
#include <signal.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>
#include <vortex.h>

namespace vx_bench {

enum class PowerMode {
    Off,
    Separate,
};

struct Args {
    int         warmup        = 3;
    int         iterations    = 10;
    bool        latency_enabled = true;
    // Payload uploads are enabled by default. Latency-only experiments may
    // explicitly disable host preparation and H2D copies.
    bool        copy_inputs   = true;
    bool        csv           = false;
    // Optional report file. Empty => write report to stdout.
    std::string output;
    // Append instead of truncate when writing to `output`. Useful for sweep
    // drivers that aggregate one CSV row per shape into a shared file.
    bool        output_append = false;
    PowerMode   power_mode    = PowerMode::Off;
    std::string power_csv     = "fpga_power.csv";
    std::string power_summary;
    // double      power_interval   = 0.1;
    double      power_interval   = 0.05;
    int         power_fpga_id    = 0;
    int         power_iterations = -1;
    double      power_idle_sec   = 2.0;
    std::string power_idle_policy;
    std::string power_idle_guard_script;
    uint64_t    power_csv_max_bytes = 1024ull * 1024ull;
    std::string power_script;
    bool        power_measure_latency = false;
    int         power_kernel_iterations = 1;
    bool        power_kernel_iterations_auto = false;
    double      power_target_sec = 1.0;
    double      power_fpga_freq_mhz = 100.0;
    bool        power_fpga_freq_mhz_auto = true;
    std::string power_xclbin_info;
    bool        power_auto_duration = false;
    double      power_min_run_sec = 10.0;
    double      power_max_run_sec = 60.0;
    int         power_max_iterations = 1024;
    int         power_target_samples = 100;
    double      power_latency_interval = 1.0;
    double      power_min_interval = 0.05;
    double      power_max_interval = 1.0;
    bool        power_latency_sampled = false;
    double      power_latency_idle_start_s = 0.0;
    double      power_latency_idle_end_s = 0.0;
    double      power_latency_run_start_s = 0.0;
    double      power_latency_run_end_s = 0.0;
    size_t      power_latency_samples = 0;
    double      power_latency_min_us = 0.0;
    double      power_latency_avg_us = 0.0;
    double      power_latency_max_us = 0.0;
    double      power_latency_p50_us = 0.0;
    double      power_latency_p95_us = 0.0;
    bool        power_latency_has_fpga_cycle = false;
    uint64_t    power_latency_fpga_cycle = 0;
    int         power_latency_kernel_iterations = 1;
    bool        parse_error = false;
    std::string parse_error_message;
};

inline const char* power_mode_name(PowerMode mode) {
    switch (mode) {
    case PowerMode::Off:      return "off";
    case PowerMode::Separate: return "separate";
    }
    return "off";
}

inline bool latency_enabled(const Args& args) {
    return args.latency_enabled;
}

inline bool power_enabled(const Args& args) {
    return args.power_mode != PowerMode::Off;
}

inline bool path_exists(const std::string& path) {
    struct stat st;
    return !path.empty() && ::stat(path.c_str(), &st) == 0;
}

inline bool parse_frequency_mhz_line(const char* line, double* freq_mhz) {
    const char* p = std::strchr(line, ':');
    if (!p) p = line;
    char* end = nullptr;
    double value = std::strtod(p + 1, &end);
    if (end == p + 1 || !std::isfinite(value) || value <= 0.0)
        return false;
    *freq_mhz = value;
    return true;
}

inline bool parse_kernel_clock_achieved_mhz_from_xclbin_info(const std::string& path, double* freq_mhz) {
    FILE* f = std::fopen(path.c_str(), "r");
    if (!f)
        return false;

    bool in_kernel_clock = false;
    char line[1024];
    while (std::fgets(line, sizeof(line), f)) {
        if (std::strstr(line, "Name:") != nullptr) {
            in_kernel_clock = (std::strstr(line, "ulp_ucs_aclk_kernel_00") != nullptr);
        }
        if (in_kernel_clock && std::strstr(line, "Achieved Freq:") != nullptr) {
            double parsed_mhz = 0.0;
            if (parse_frequency_mhz_line(line, &parsed_mhz)) {
                std::fclose(f);
                *freq_mhz = parsed_mhz;
                return true;
            }
        }
    }

    std::fclose(f);
    return false;
}

inline std::string default_xclbin_info_path() {
    const char* explicit_info = std::getenv("VORTEX_POWER_XCLBIN_INFO");
    if (explicit_info && path_exists(explicit_info))
        return explicit_info;

    const char* xclbin = std::getenv("XRT_XCLBIN_PATH");
    if (xclbin) {
        std::string info = std::string(xclbin) + ".info";
        if (path_exists(info))
            return info;
    }

    const char* fpga_bin_dir = std::getenv("FPGA_BIN_DIR");
    if (fpga_bin_dir) {
        std::string info = std::string(fpga_bin_dir) + "/vortex_afu.xclbin.info";
        if (path_exists(info))
            return info;
    }

    return std::string();
}

inline double resolve_power_fpga_freq_mhz(const Args& args, FILE* msg = stderr) {
    if (!args.power_fpga_freq_mhz_auto)
        return args.power_fpga_freq_mhz;

    std::string info = args.power_xclbin_info.empty() ? default_xclbin_info_path() : args.power_xclbin_info;
    double parsed_mhz = 0.0;
    if (!info.empty() && parse_kernel_clock_achieved_mhz_from_xclbin_info(info, &parsed_mhz)) {
        if (msg) {
            std::fprintf(msg, "[power] stage=fpga_freq_resolve source=xclbin_info path=%s kernel_clock_achieved_mhz=%.6f\n",
                         info.c_str(), parsed_mhz);
        }
        return parsed_mhz;
    }

    if (msg) {
        std::fprintf(msg, "[power] stage=fpga_freq_resolve source=fallback kernel_clock_achieved_mhz=%.6f",
                     args.power_fpga_freq_mhz);
        if (!info.empty())
            std::fprintf(msg, " xclbin_info=%s", info.c_str());
        std::fprintf(msg, "\n");
    }
    return args.power_fpga_freq_mhz;
}

inline int compute_power_kernel_iterations(const Args& args,
                                           double first_latency_us,
                                           uint64_t fpga_cycle = 0,
                                           bool has_fpga_cycle = false,
                                           const char* label = "",
                                           FILE* msg = stderr) {
    if (!args.power_kernel_iterations_auto)
        return args.power_kernel_iterations;

    const char* source = "host_latency";
    double kernel_s = 0.0;
    double fpga_freq_mhz = 0.0;
    if (has_fpga_cycle && fpga_cycle > 0) {
        fpga_freq_mhz = resolve_power_fpga_freq_mhz(args, msg);
        if (std::isfinite(fpga_freq_mhz) && fpga_freq_mhz > 0.0) {
            kernel_s = static_cast<double>(fpga_cycle) / (fpga_freq_mhz * 1000000.0);
            source = "fpga_cycle";
        }
    }

    if (kernel_s <= 0.0 || !std::isfinite(kernel_s)) {
        if (first_latency_us <= 0.0 || !std::isfinite(first_latency_us))
            return 1;
        kernel_s = first_latency_us / 1000000.0;
        source = "host_latency";
    }

    double iterations = std::ceil(args.power_target_sec / kernel_s);
    if (!std::isfinite(iterations) || iterations < 1.0)
        return 1;

    const double max_iterations = static_cast<double>(std::numeric_limits<int>::max());
    if (iterations > max_iterations)
        return std::numeric_limits<int>::max();

    int planned_iterations = static_cast<int>(iterations);
    if (msg) {
        std::fprintf(msg,
            "[power] stage=kernel_iterations_auto label=%s source=%s target_s=%.6f "
            "kernel_s=%.9f host_latency_us=%.3f fpga_cycle=%llu fpga_freq_mhz=%.6f "
            "kernel_iterations=%d\n",
            label ? label : "",
            source,
            args.power_target_sec,
            kernel_s,
            first_latency_us,
            static_cast<unsigned long long>(fpga_cycle),
            fpga_freq_mhz,
            planned_iterations);
    }
    return planned_iterations;
}

inline bool parse_power_mode(const char* value, PowerMode* mode) {
    if (std::strcmp(value, "off") == 0 ||
        std::strcmp(value, "false") == 0 ||
        std::strcmp(value, "0") == 0) {
        *mode = PowerMode::Off;
    } else if (std::strcmp(value, "separate") == 0 ||
               std::strcmp(value, "on") == 0 ||
               std::strcmp(value, "true") == 0 ||
               std::strcmp(value, "1") == 0) {
        *mode = PowerMode::Separate;
    } else {
        return false;
    }
    return true;
}

inline bool parse_bool_arg(const char* value, bool* out) {
    if (std::strcmp(value, "1") == 0 ||
        std::strcmp(value, "true") == 0 ||
        std::strcmp(value, "on") == 0 ||
        std::strcmp(value, "yes") == 0) {
        *out = true;
    } else if (std::strcmp(value, "0") == 0 ||
               std::strcmp(value, "false") == 0 ||
               std::strcmp(value, "off") == 0 ||
               std::strcmp(value, "no") == 0) {
        *out = false;
    } else {
        return false;
    }
    return true;
}

inline void parse_power_kernel_iterations_arg(const char* value, Args& args) {
    if (std::strcmp(value, "auto") == 0) {
        args.power_kernel_iterations_auto = true;
        args.power_kernel_iterations = 1;
        return;
    }
    args.power_kernel_iterations_auto = false;
    args.power_kernel_iterations = std::atoi(value);
}

inline void parse_power_fpga_freq_mhz_arg(const char* value, Args& args) {
    if (std::strcmp(value, "auto") == 0) {
        args.power_fpga_freq_mhz_auto = true;
        return;
    }
    args.power_fpga_freq_mhz_auto = false;
    args.power_fpga_freq_mhz = std::atof(value);
}

inline void set_parse_error(Args& args, const std::string& message) {
    if (!args.parse_error) {
        args.parse_error = true;
        args.parse_error_message = message;
    }
}

inline bool read_next_value(int& r, int argc, char** argv, const char* flag, const char** value, Args& args) {
    if (r + 1 >= argc) {
        set_parse_error(args, std::string("missing value for ") + flag);
        return false;
    }
    *value = argv[++r];
    return true;
}

// Parses --warmup=N / --iterations=N / --latency / --no-latency /
// --input-copy=skip|copy / --copy-inputs / --skip-input-copy /
// --csv / --output=PATH / --output-append
// plus optional --power* flags in place:
// matched flags are removed from argv and argc is decremented so the caller's
// existing argument parser sees only its own flags.
inline Args parse(int& argc, char** argv) {
    Args a;
    int  w = 1;
    for (int r = 1; r < argc; ++r) {
        const char* s = argv[r];
        if (std::strncmp(s, "--warmup=", 9) == 0) {
            a.warmup = std::atoi(s + 9);
        } else if (std::strncmp(s, "--iterations=", 13) == 0) {
            a.iterations = std::atoi(s + 13);
        } else if (std::strcmp(s, "--latency") == 0) {
            a.latency_enabled = true;
            if (r + 1 < argc && argv[r + 1][0] != '-') {
                const char* value = argv[++r];
                if (!parse_bool_arg(value, &a.latency_enabled)) {
                    set_parse_error(a, std::string("invalid --latency value: ") + value);
                }
            }
        } else if (std::strncmp(s, "--latency=", 10) == 0) {
            if (!parse_bool_arg(s + 10, &a.latency_enabled)) {
                set_parse_error(a, std::string("invalid --latency value: ") + (s + 10));
            }
        } else if (std::strcmp(s, "--no-latency") == 0 ||
                   std::strcmp(s, "--skip-latency") == 0) {
            a.latency_enabled = false;
        } else if (std::strcmp(s, "--copy-inputs") == 0 ||
                   std::strcmp(s, "--input-copy=copy") == 0) {
            a.copy_inputs = true;
        } else if (std::strcmp(s, "--skip-input-copy") == 0 ||
                   std::strcmp(s, "--input-copy=skip") == 0) {
            a.copy_inputs = false;
        } else if (std::strncmp(s, "--input-copy=", 13) == 0) {
            set_parse_error(a, std::string("invalid --input-copy mode: ") + (s + 13));
        } else if (std::strcmp(s, "--csv") == 0) {
            a.csv = true;
        } else if (std::strncmp(s, "--output=", 9) == 0) {
            a.output = s + 9;
        } else if (std::strcmp(s, "--output-append") == 0) {
            a.output_append = true;
        } else if (std::strncmp(s, "--power=", 8) == 0) {
            if (!parse_power_mode(s + 8, &a.power_mode)) {
                set_parse_error(a, std::string("invalid --power mode: ") + (s + 8));
            }
        } else if (std::strcmp(s, "--power") == 0) {
            a.power_mode = PowerMode::Separate;
            if (r + 1 < argc && argv[r + 1][0] != '-') {
                const char* mode = argv[++r];
                if (!parse_power_mode(mode, &a.power_mode)) {
                    set_parse_error(a, std::string("invalid --power mode: ") + mode);
                }
            }
        } else if (std::strncmp(s, "--power-csv=", 12) == 0) {
            a.power_csv = s + 12;
        } else if (std::strcmp(s, "--power-csv") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-csv", &value, a)) a.power_csv = value;
        } else if (std::strncmp(s, "--power-summary=", 16) == 0) {
            a.power_summary = s + 16;
        } else if (std::strcmp(s, "--power-summary") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-summary", &value, a)) a.power_summary = value;
        } else if (std::strncmp(s, "--power-interval=", 17) == 0) {
            a.power_interval = std::atof(s + 17);
        } else if (std::strcmp(s, "--power-interval") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-interval", &value, a)) a.power_interval = std::atof(value);
        } else if (std::strncmp(s, "--power-fpga-id=", 16) == 0) {
            a.power_fpga_id = std::atoi(s + 16);
        } else if (std::strcmp(s, "--power-fpga-id") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-fpga-id", &value, a)) a.power_fpga_id = std::atoi(value);
        } else if (std::strncmp(s, "--power-iterations=", 19) == 0) {
            a.power_iterations = std::atoi(s + 19);
        } else if (std::strcmp(s, "--power-iterations") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-iterations", &value, a)) a.power_iterations = std::atoi(value);
        } else if (std::strncmp(s, "--power-idle-sec=", 17) == 0) {
            a.power_idle_sec = std::atof(s + 17);
        } else if (std::strcmp(s, "--power-idle-sec") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-idle-sec", &value, a)) a.power_idle_sec = std::atof(value);
        } else if (std::strncmp(s, "--power-idle-policy=", 20) == 0) {
            a.power_idle_policy = s + 20;
        } else if (std::strcmp(s, "--power-idle-policy") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-idle-policy", &value, a)) a.power_idle_policy = value;
        } else if (std::strncmp(s, "--power-idle-guard-script=", 26) == 0) {
            a.power_idle_guard_script = s + 26;
        } else if (std::strcmp(s, "--power-idle-guard-script") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-idle-guard-script", &value, a)) a.power_idle_guard_script = value;
        } else if (std::strncmp(s, "--power-csv-max-bytes=", 22) == 0) {
            a.power_csv_max_bytes = static_cast<uint64_t>(std::strtoull(s + 22, nullptr, 0));
        } else if (std::strcmp(s, "--power-csv-max-bytes") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-csv-max-bytes", &value, a)) {
                a.power_csv_max_bytes = static_cast<uint64_t>(std::strtoull(value, nullptr, 0));
            }
        } else if (std::strncmp(s, "--power-script=", 15) == 0) {
            a.power_script = s + 15;
        } else if (std::strcmp(s, "--power-script") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-script", &value, a)) a.power_script = value;
        } else if (std::strncmp(s, "--power-kernel-iterations=", 26) == 0) {
            parse_power_kernel_iterations_arg(s + 26, a);
        } else if (std::strcmp(s, "--power-kernel-iterations") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-kernel-iterations", &value, a)) {
                parse_power_kernel_iterations_arg(value, a);
            }
        } else if (std::strcmp(s, "--power-kernel-iterations-auto") == 0) {
            a.power_kernel_iterations_auto = true;
            if (r + 1 < argc && argv[r + 1][0] != '-') {
                const char* value = argv[++r];
                if (!parse_bool_arg(value, &a.power_kernel_iterations_auto)) {
                    set_parse_error(a, std::string("invalid --power-kernel-iterations-auto value: ") + value);
                }
            }
        } else if (std::strncmp(s, "--power-kernel-iterations-auto=", 31) == 0) {
            if (!parse_bool_arg(s + 31, &a.power_kernel_iterations_auto)) {
                set_parse_error(a, std::string("invalid --power-kernel-iterations-auto value: ") + (s + 31));
            }
        } else if (std::strcmp(s, "--no-power-kernel-iterations-auto") == 0) {
            a.power_kernel_iterations_auto = false;
        } else if (std::strncmp(s, "--power-target-sec=", 19) == 0) {
            a.power_target_sec = std::atof(s + 19);
        } else if (std::strcmp(s, "--power-target-sec") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-target-sec", &value, a)) a.power_target_sec = std::atof(value);
        } else if (std::strncmp(s, "--power-fpga-freq-mhz=", 22) == 0) {
            parse_power_fpga_freq_mhz_arg(s + 22, a);
        } else if (std::strcmp(s, "--power-fpga-freq-mhz") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-fpga-freq-mhz", &value, a)) {
                parse_power_fpga_freq_mhz_arg(value, a);
            }
        } else if (std::strncmp(s, "--power-xclbin-info=", 20) == 0) {
            a.power_xclbin_info = s + 20;
        } else if (std::strcmp(s, "--power-xclbin-info") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-xclbin-info", &value, a)) a.power_xclbin_info = value;
        } else if (std::strcmp(s, "--power-measure-latency") == 0) {
            a.power_measure_latency = true;
            if (r + 1 < argc && argv[r + 1][0] != '-') {
                const char* value = argv[++r];
                if (!parse_bool_arg(value, &a.power_measure_latency)) {
                    set_parse_error(a, std::string("invalid --power-measure-latency value: ") + value);
                }
            }
        } else if (std::strncmp(s, "--power-measure-latency=", 24) == 0) {
            if (!parse_bool_arg(s + 24, &a.power_measure_latency)) {
                set_parse_error(a, std::string("invalid --power-measure-latency value: ") + (s + 24));
            }
        } else if (std::strcmp(s, "--no-power-measure-latency") == 0) {
            a.power_measure_latency = false;
        } else if (std::strcmp(s, "--power-auto-duration") == 0) {
            a.power_auto_duration = true;
            if (r + 1 < argc && argv[r + 1][0] != '-') {
                const char* value = argv[++r];
                if (!parse_bool_arg(value, &a.power_auto_duration)) {
                    set_parse_error(a, std::string("invalid --power-auto-duration value: ") + value);
                }
            }
        } else if (std::strncmp(s, "--power-auto-duration=", 22) == 0) {
            if (!parse_bool_arg(s + 22, &a.power_auto_duration)) {
                set_parse_error(a, std::string("invalid --power-auto-duration value: ") + (s + 22));
            }
        } else if (std::strcmp(s, "--no-power-auto-duration") == 0) {
            a.power_auto_duration = false;
        } else if (std::strncmp(s, "--power-min-run-sec=", 20) == 0) {
            a.power_min_run_sec = std::atof(s + 20);
        } else if (std::strcmp(s, "--power-min-run-sec") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-min-run-sec", &value, a)) a.power_min_run_sec = std::atof(value);
        } else if (std::strncmp(s, "--power-max-run-sec=", 20) == 0) {
            a.power_max_run_sec = std::atof(s + 20);
        } else if (std::strcmp(s, "--power-max-run-sec") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-max-run-sec", &value, a)) a.power_max_run_sec = std::atof(value);
        } else if (std::strncmp(s, "--power-max-iterations=", 23) == 0) {
            a.power_max_iterations = std::atoi(s + 23);
        } else if (std::strcmp(s, "--power-max-iterations") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-max-iterations", &value, a)) a.power_max_iterations = std::atoi(value);
        } else if (std::strncmp(s, "--power-target-samples=", 23) == 0) {
            a.power_target_samples = std::atoi(s + 23);
        } else if (std::strcmp(s, "--power-target-samples") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-target-samples", &value, a)) a.power_target_samples = std::atoi(value);
        } else if (std::strncmp(s, "--power-latency-interval=", 25) == 0) {
            a.power_latency_interval = std::atof(s + 25);
        } else if (std::strcmp(s, "--power-latency-interval") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-latency-interval", &value, a)) a.power_latency_interval = std::atof(value);
        } else if (std::strncmp(s, "--power-min-interval=", 21) == 0) {
            a.power_min_interval = std::atof(s + 21);
        } else if (std::strcmp(s, "--power-min-interval") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-min-interval", &value, a)) a.power_min_interval = std::atof(value);
        } else if (std::strncmp(s, "--power-max-interval=", 21) == 0) {
            a.power_max_interval = std::atof(s + 21);
        } else if (std::strcmp(s, "--power-max-interval") == 0) {
            const char* value = nullptr;
            if (read_next_value(r, argc, argv, "--power-max-interval", &value, a)) a.power_max_interval = std::atof(value);
        } else if (std::strcmp(s, "--warmup") == 0 && r + 1 < argc) {
            a.warmup = std::atoi(argv[++r]);
        } else if (std::strcmp(s, "--iterations") == 0 && r + 1 < argc) {
            a.iterations = std::atoi(argv[++r]);
        } else if (std::strcmp(s, "--output") == 0 && r + 1 < argc) {
            a.output = argv[++r];
        } else {
            argv[w++] = argv[r];
        }
    }
    argc = w;
    if (a.warmup < 0)     a.warmup = 0;
    if (a.iterations < 1) a.iterations = 1;
    if (a.power_interval <= 0.0) a.power_interval = 0.1;
    if (a.power_idle_sec < 0.0)  a.power_idle_sec = 0.0;
    if (a.power_iterations < 0)  a.power_iterations = a.iterations;
    if (a.power_iterations < 1)  a.power_iterations = 1;
    if (a.power_kernel_iterations < 1) a.power_kernel_iterations = 1;
    if (a.power_target_sec <= 0.0) a.power_target_sec = 1.0;
    if (a.power_fpga_freq_mhz <= 0.0) a.power_fpga_freq_mhz = 100.0;
    if (a.power_min_run_sec < 0.0) a.power_min_run_sec = 0.0;
    if (a.power_max_run_sec <= 0.0) a.power_max_run_sec = a.power_min_run_sec;
    if (a.power_max_run_sec < a.power_min_run_sec) a.power_max_run_sec = a.power_min_run_sec;
    if (a.power_max_iterations < 0) a.power_max_iterations = 0;
    if (a.power_target_samples < 1) a.power_target_samples = 1;
    if (a.power_latency_interval <= 0.0) a.power_latency_interval = 1.0;
    if (a.power_min_interval <= 0.0) a.power_min_interval = 0.05;
    if (a.power_max_interval <= 0.0) a.power_max_interval = a.power_min_interval;
    if (a.power_max_interval < a.power_min_interval) a.power_max_interval = a.power_min_interval;
    if (a.power_summary.empty()) a.power_summary = a.power_csv + ".summary.csv";
    if (a.power_kernel_iterations_auto) a.latency_enabled = true;
    if (!a.latency_enabled) {
        a.warmup = 0;
        a.iterations = 0;
    }
    return a;
}

class Stopwatch {
public:
    void   start()    { t0_ = clock::now(); }
    double stop_us() {
        auto t1 = clock::now();
        return std::chrono::duration<double, std::micro>(t1 - t0_).count();
    }
private:
    using clock = std::chrono::steady_clock;
    clock::time_point t0_{};
};

struct StatsSummary {
    size_t n = 0;
    double min = 0.0;
    double avg = 0.0;
    double max = 0.0;
    double p50 = 0.0;
    double p95 = 0.0;
};

class Stats {
public:
    void record(double us) { samples_.push_back(us); }
    float last() {return samples_.back();}

    StatsSummary summary() const {
        StatsSummary out;
        if (samples_.empty()) {
            return out;
        }
        std::vector<double> s = samples_;
        std::sort(s.begin(), s.end());
        const size_t n = s.size();
        double sum = 0.0;
        for (double v : s) sum += v;
        out.n = n;
        out.avg = sum / static_cast<double>(n);
        out.min = s.front();
        out.max = s.back();
        out.p50 = pct(s, 0.50);
        out.p95 = pct(s, 0.95);
        return out;
    }

    void report(const char* label, FILE* out, bool csv) const {
        auto s = summary();
        if (s.n == 0) {
            if (csv) {
                std::fprintf(out, "%s,0,nan,nan,nan,nan,nan\n", label);
                return;
            }
            std::fprintf(out, "[bench] %s: no samples\n", label);
            return;
        }

        if (csv) {
            // Header is emitted once externally if needed; we just print the row.
            std::fprintf(out,
                "%s,%zu,%.3f,%.3f,%.3f,%.3f,%.3f\n",
                label, s.n, s.min, s.avg, s.max, s.p50, s.p95);
        } else {
            std::fprintf(out,
                "[bench] %s  iters=%zu  min=%.3f  avg=%.3f  max=%.3f  "
                "p50=%.3f  p95=%.3f  (us)\n",
                label, s.n, s.min, s.avg, s.max, s.p50, s.p95);
        }
    }

    // Honors args.output / args.output_append. Writes to stdout when no
    // --output was given. On file-open failure, falls back to stdout and
    // prints a warning so the run still surfaces its numbers.
    void report(const char* label, const Args& args) const {
        if (args.output.empty()) {
            report(label, stdout, args.csv);
            return;
        }
        const char* mode = args.output_append ? "a" : "w";
        FILE* f = std::fopen(args.output.c_str(), mode);
        if (!f) {
            std::fprintf(stderr,
                "[bench] WARNING: cannot open --output=%s (mode=%s); "
                "falling back to stdout\n",
                args.output.c_str(), mode);
            report(label, stdout, args.csv);
            return;
        }
        report(label, f, args.csv);
        std::fclose(f);
    }

private:
    static double pct(const std::vector<double>& sorted, double q) {
        // nearest-rank (no interpolation) — fine for our small N
        if (sorted.empty()) return 0.0;
        size_t idx = static_cast<size_t>(q * (sorted.size() - 1) + 0.5);
        if (idx >= sorted.size()) idx = sorted.size() - 1;
        return sorted[idx];
    }

    std::vector<double> samples_;
};

inline double epoch_seconds() {
    auto now = std::chrono::system_clock::now();
    return std::chrono::duration<double>(now.time_since_epoch()).count();
}

inline void sleep_seconds(double seconds) {
    if (seconds <= 0.0) return;
    std::this_thread::sleep_for(std::chrono::duration<double>(seconds));
}

inline bool is_executable(const std::string& path) {
    return !path.empty() && ::access(path.c_str(), X_OK) == 0;
}

inline std::string resolve_power_script(const Args& args) {
    if (!args.power_script.empty()) {
        return args.power_script;
    }

    std::vector<std::string> candidates;
    const char* vortex_home = std::getenv("VORTEX_HOME");
    if (vortex_home && vortex_home[0] != '\0') {
        candidates.push_back(std::string(vortex_home) + "/ci/measure_power.sh");
    }
    candidates.push_back("../../../ci/measure_power.sh");
    candidates.push_back("./ci/measure_power.sh");

    for (const auto& path : candidates) {
        if (is_executable(path)) {
            return path;
        }
    }
    return candidates.empty() ? std::string() : candidates.front();
}

class PowerSampler {
public:
    ~PowerSampler() {
        stop();
    }

    bool start(const Args& args, FILE* err = stderr) {
        if (pid_ > 0) {
            return true;
        }

        const std::string script = resolve_power_script(args);
        if (!is_executable(script)) {
            std::fprintf(err, "[power] ERROR: sampler script is not executable: %s\n", script.c_str());
            return false;
        }

        const std::string log_path = args.power_csv + ".log";
        int log_fd = ::open(log_path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (log_fd < 0) {
            std::fprintf(err, "[power] ERROR: cannot open sampler log %s: %s\n",
                         log_path.c_str(), std::strerror(errno));
            return false;
        }

        char fpga_id[32];
        char interval[64];
        char max_bytes[64];
        std::snprintf(fpga_id, sizeof(fpga_id), "%d", args.power_fpga_id);
        std::snprintf(interval, sizeof(interval), "%.9g", args.power_interval);
        std::snprintf(max_bytes, sizeof(max_bytes), "%llu",
                      static_cast<unsigned long long>(args.power_csv_max_bytes));

        const pid_t parent_pid = ::getpid();
        pid_t child = ::fork();
        if (child < 0) {
            std::fprintf(err, "[power] ERROR: fork failed: %s\n", std::strerror(errno));
            ::close(log_fd);
            return false;
        }

        if (child == 0) {
            ::setpgid(0, 0);
#ifdef __linux__
            if (::prctl(PR_SET_PDEATHSIG, SIGTERM) != 0 || ::getppid() != parent_pid) {
                _exit(126);
            }
#endif
            ::dup2(log_fd, STDOUT_FILENO);
            ::dup2(log_fd, STDERR_FILENO);
            ::close(log_fd);
            ::execl(script.c_str(), script.c_str(), fpga_id, interval,
                    args.power_csv.c_str(), max_bytes, static_cast<char*>(nullptr));
            _exit(127);
        }

        ::close(log_fd);
        ::setpgid(child, child);
        pid_ = child;
        return true;
    }

    void stop() {
        if (pid_ <= 0) {
            return;
        }

        int status = 0;
        pid_t ret = ::waitpid(pid_, &status, WNOHANG);
        if (ret == pid_) {
            pid_ = -1;
            return;
        }

        ::kill(-pid_, SIGTERM);
        ::kill(pid_, SIGTERM);
        for (int i = 0; i < 20; ++i) {
            ret = ::waitpid(pid_, &status, WNOHANG);
            if (ret == pid_ || (ret < 0 && errno == ECHILD)) {
                pid_ = -1;
                return;
            }
            ::usleep(100000);
        }

        ::kill(-pid_, SIGKILL);
        ::kill(pid_, SIGKILL);
        ::waitpid(pid_, &status, 0);
        pid_ = -1;
    }

private:
    pid_t pid_ = -1;
};

struct PowerStats {
    size_t samples = 0;
    double min_w = std::numeric_limits<double>::quiet_NaN();
    double avg_w = std::numeric_limits<double>::quiet_NaN();
    double max_w = std::numeric_limits<double>::quiet_NaN();
    double std_w = std::numeric_limits<double>::quiet_NaN();
    double elapsed_s = 0.0;
};

struct PowerPhase {
    std::string mode;
    std::string phase;
    double start_s = 0.0;
    double end_s = 0.0;
    bool has_latency = false;
    StatsSummary latency;
    std::vector<uint64_t> fpga_cycles;
};

inline bool read_idle_guard_window(const std::string& path,
                                   PowerPhase* phase,
                                   double not_before_s,
                                   FILE* msg = stderr) {
    FILE* f = std::fopen(path.c_str(), "r");
    if (!f) {
        std::fprintf(msg, "[power] idle guard result missing: %s\n", path.c_str());
        return false;
    }
    char header[1024];
    char row[1024];
    const bool has_rows = std::fgets(header, sizeof(header), f)
                       && std::fgets(row, sizeof(row), f);
    std::fclose(f);
    if (!has_rows) {
        std::fprintf(msg, "[power] idle guard result empty: %s\n", path.c_str());
        return false;
    }
    int stable = 0;
    int samples = 0;
    int observed_samples = 0;
    double start_s = 0.0;
    double end_s = 0.0;
    double mean_w = 0.0;
    double std_w = 0.0;
    double stderr_w = 0.0;
    double slope_w_per_s = 0.0;
    double mean_delta_w = 0.0;
    const int fields = std::sscanf(
        row,
        "%d,%lf,%lf,%d,%lf,%lf,%lf,%lf,%lf,%d",
        &stable,
        &start_s,
        &end_s,
        &samples,
        &mean_w,
        &std_w,
        &stderr_w,
        &slope_w_per_s,
        &mean_delta_w,
        &observed_samples);
    if (fields != 10 || stable != 1 || samples < 2 || end_s < start_s) {
        std::fprintf(msg, "[power] idle guard result invalid: %s\n", row);
        return false;
    }
    phase->start_s = start_s;
    phase->end_s = end_s;
    std::fprintf(msg,
        "[power] stage=idle_stable samples=%d observed_samples=%d elapsed_s=%.6f "
        "selected_window_s=%.6f "
        "mean_w=%.6f std_w=%.6f stderr_w=%.6f slope_w_per_s=%.6f "
        "mean_delta_w=%.6f\n",
        samples,
        observed_samples,
        end_s - not_before_s,
        end_s - start_s,
        mean_w,
        std_w,
        stderr_w,
        slope_w_per_s,
        mean_delta_w);
    std::fflush(msg);
    return true;
}

inline bool capture_idle_phase(const Args& args,
                               PowerPhase* phase,
                               const char* label,
                               FILE* msg = stderr) {
    phase->mode = "idle";
    phase->phase = "idle";
    if (args.power_idle_policy.empty()) {
        phase->start_s = epoch_seconds();
        sleep_seconds(args.power_idle_sec);
        phase->end_s = epoch_seconds();
        return true;
    }
    if (!is_executable(args.power_idle_guard_script)) {
        std::fprintf(msg,
            "[power] stage=idle_guard_error label=%s script_not_executable=%s\n",
            label,
            args.power_idle_guard_script.c_str());
        return false;
    }

    const std::string result_path = args.power_csv + ".idle_guard.csv";
    std::remove(result_path.c_str());
    const double not_before_s = epoch_seconds();
    char not_before[64];
    std::snprintf(not_before, sizeof(not_before), "%.9f", not_before_s);
    std::fprintf(msg,
        "[power] stage=idle_guard_begin label=%s policy=%s not_before_s=%s\n",
        label,
        args.power_idle_policy.c_str(),
        not_before);
    std::fflush(msg);

    const pid_t child = ::fork();
    if (child < 0) {
        std::fprintf(msg, "[power] idle guard fork failed: %s\n", std::strerror(errno));
        return false;
    }
    if (child == 0) {
        ::execl(
            args.power_idle_guard_script.c_str(),
            args.power_idle_guard_script.c_str(),
            "wait",
            "--csv",
            args.power_csv.c_str(),
            "--policy",
            args.power_idle_policy.c_str(),
            "--not-before",
            not_before,
            "--result",
            result_path.c_str(),
            static_cast<char*>(nullptr));
        _exit(127);
    }
    int status = 0;
    if (::waitpid(child, &status, 0) != child) {
        std::fprintf(msg, "[power] idle guard waitpid failed: %s\n", std::strerror(errno));
        return false;
    }
    const int rc = WIFEXITED(status) ? WEXITSTATUS(status) : 128;
    if (rc != 0) {
        std::fprintf(msg,
            "[power] stage=idle_unstable label=%s guard_rc=%d policy=%s\n",
            label,
            rc,
            args.power_idle_policy.c_str());
        std::fflush(msg);
        return false;
    }
    if (!read_idle_guard_window(result_path, phase, not_before_s, msg)) {
        std::fprintf(msg,
            "[power] stage=idle_guard_error label=%s invalid_result=%s\n",
            label,
            result_path.c_str());
        return false;
    }
    return true;
}

struct UIntStatsSummary {
    size_t n = 0;
    uint64_t min = 0;
    double avg = 0.0;
    uint64_t max = 0;
    uint64_t p50 = 0;
    uint64_t p95 = 0;
};

inline UIntStatsSummary summarize_uint64(const std::vector<uint64_t>& samples) {
    UIntStatsSummary out;
    if (samples.empty()) {
        return out;
    }
    std::vector<uint64_t> s = samples;
    std::sort(s.begin(), s.end());
    long double sum = 0.0;
    for (uint64_t v : s) sum += static_cast<long double>(v);
    out.n = s.size();
    out.min = s.front();
    out.avg = static_cast<double>(sum / static_cast<long double>(s.size()));
    out.max = s.back();
    auto pct = [](const std::vector<uint64_t>& sorted, double q) {
        size_t idx = static_cast<size_t>(q * (sorted.size() - 1) + 0.5);
        if (idx >= sorted.size()) idx = sorted.size() - 1;
        return sorted[idx];
    };
    out.p50 = pct(s, 0.50);
    out.p95 = pct(s, 0.95);
    return out;
}

static constexpr uint32_t VX_BENCH_CSR_MCYCLE = 0xB00;

inline bool read_max_fpga_cycle(vx_device_h device, uint64_t* value, FILE* msg = stderr) {
    uint64_t num_cores = 0;
    int ret = vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores);
    if (ret != 0) {
        std::fprintf(msg, "[power] vx_dev_caps(VX_CAPS_NUM_CORES) failed during fpga_cycle read: ret=%d\n", ret);
        return false;
    }

    uint64_t max_cycles = 0;
    for (uint32_t core_id = 0; core_id < num_cores; ++core_id) {
        uint64_t cycles_per_core = 0;
        ret = vx_mpm_query(device, VX_BENCH_CSR_MCYCLE, core_id, &cycles_per_core);
        if (ret != 0) {
            std::fprintf(msg, "[power] vx_mpm_query(VX_CSR_MCYCLE) failed during fpga_cycle read: core=%u ret=%d\n",
                         core_id, ret);
            return false;
        }
        max_cycles = std::max<uint64_t>(max_cycles, cycles_per_core);
    }

    *value = max_cycles;
    return true;
}

inline std::string trim_csv_cell(std::string value) {
    while (!value.empty() && (value.back() == '\n' || value.back() == '\r')) {
        value.pop_back();
    }
    return value;
}

inline std::vector<std::string> split_csv_line(const char* line) {
    std::vector<std::string> fields;
    std::string current;
    for (const char* p = line; *p; ++p) {
        if (*p == ',') {
            fields.push_back(trim_csv_cell(current));
            current.clear();
        } else {
            current.push_back(*p);
        }
    }
    fields.push_back(trim_csv_cell(current));
    return fields;
}

inline int csv_column_index(const std::vector<std::string>& header, const char* column_name) {
    for (size_t i = 0; i < header.size(); ++i) {
        if (header[i] == column_name) {
            return static_cast<int>(i);
        }
    }
    return -1;
}

inline PowerStats read_power_stats(const std::string& csv_path,
                                   double start_s,
                                   double end_s,
                                   const char* power_column = "total_power_w") {
    PowerStats stats;
    stats.elapsed_s = end_s - start_s;
    if (stats.elapsed_s < 0.0) stats.elapsed_s = 0.0;

    FILE* f = std::fopen(csv_path.c_str(), "r");
    if (!f) {
        return stats;
    }

    char line[1024];
    if (!std::fgets(line, sizeof(line), f)) {
        std::fclose(f);
        return stats;
    }

    const std::vector<std::string> header = split_csv_line(line);
    int timestamp_idx = csv_column_index(header, "timestamp_s");
    if (timestamp_idx < 0) {
        timestamp_idx = 0;
    }
    int power_idx = csv_column_index(header, power_column);
    if (power_idx < 0 && std::strcmp(power_column, "total_power_w") == 0) {
        power_idx = csv_column_index(header, "p_total_w");
    }
    if (power_idx < 0) {
        std::fclose(f);
        return stats;
    }

    long double sum = 0.0;
    long double sum_sq = 0.0;
    while (std::fgets(line, sizeof(line), f)) {
        const std::vector<std::string> fields = split_csv_line(line);
        if (timestamp_idx >= static_cast<int>(fields.size())
         || power_idx >= static_cast<int>(fields.size())) {
            continue;
        }
        char* endptr = nullptr;
        double ts = std::strtod(fields[timestamp_idx].c_str(), &endptr);
        if (endptr == fields[timestamp_idx].c_str()) continue;
        if (ts < start_s || ts > end_s) {
            continue;
        }
        double watts = std::strtod(fields[power_idx].c_str(), nullptr);
        if (stats.samples == 0) {
            stats.min_w = watts;
            stats.max_w = watts;
        } else {
            stats.min_w = std::min(stats.min_w, watts);
            stats.max_w = std::max(stats.max_w, watts);
        }
        sum += watts;
        sum_sq += static_cast<long double>(watts) * static_cast<long double>(watts);
        ++stats.samples;
    }
    std::fclose(f);

    if (stats.samples != 0) {
        const long double n = static_cast<long double>(stats.samples);
        stats.avg_w = static_cast<double>(sum / n);
        if (stats.samples == 1) {
            stats.std_w = 0.0;
        } else {
            long double variance = (sum_sq - (sum * sum / n)) / (n - 1.0L);
            if (variance < 0.0L && variance > -1e-12L) {
                variance = 0.0L;
            }
            stats.std_w = (variance >= 0.0L)
                ? std::sqrt(static_cast<double>(variance))
                : std::numeric_limits<double>::quiet_NaN();
        }
    }
    return stats;
}

inline bool write_power_summary(const char* label,
                                const Args& args,
                                const PowerPhase& idle,
                                const std::vector<PowerPhase>& runs,
                                FILE* msg = stderr) {
    FILE* f = std::fopen(args.power_summary.c_str(), "w");
    if (!f) {
        std::fprintf(msg, "[power] ERROR: cannot open summary %s: %s\n",
                     args.power_summary.c_str(), std::strerror(errno));
        return false;
    }

    std::fprintf(f,
        "label,mode,phase,samples,elapsed_s,idle_samples,idle_avg_w,"
        "idle_std_w,idle_vcc_avg_w,idle_pcie_avg_w,"
        "run_min_w,run_avg_w,run_max_w,run_std_w,"
        "run_vcc_min_w,run_vcc_avg_w,run_vcc_max_w,"
        "run_pcie_min_w,run_pcie_avg_w,run_pcie_max_w,"
        "delta_avg_w,delta_peak_w,dynamic_stderr_w,energy_j,"
        "power_latency,power_fpga_cycle,power_kernel_iterations,"
        "power_kernel_iterations_auto,power_target_sec,power_source,"
        "power_raw_truncated,raw_csv\n");

    const PowerStats idle_stats = read_power_stats(args.power_csv, idle.start_s, idle.end_s, "total_power_w");
    const PowerStats idle_vcc_stats = read_power_stats(args.power_csv, idle.start_s, idle.end_s, "vcc_power_w");
    const PowerStats idle_pcie_stats = read_power_stats(args.power_csv, idle.start_s, idle.end_s, "pcie_power_w");
    const double nan = std::numeric_limits<double>::quiet_NaN();
    for (const auto& run : runs) {
        const PowerStats run_stats = read_power_stats(args.power_csv, run.start_s, run.end_s, "total_power_w");
        const PowerStats run_vcc_stats = read_power_stats(args.power_csv, run.start_s, run.end_s, "vcc_power_w");
        const PowerStats run_pcie_stats = read_power_stats(args.power_csv, run.start_s, run.end_s, "pcie_power_w");
        const double dP_avg = (idle_stats.samples && run_stats.samples) ? (run_stats.avg_w - idle_stats.avg_w) : nan;
        const double dP_peak = (idle_stats.samples && run_stats.samples) ? (run_stats.max_w - idle_stats.avg_w) : nan;
        const double dP_stderr = (idle_stats.samples && run_stats.samples)
            ? std::sqrt((run_stats.std_w * run_stats.std_w / static_cast<double>(run_stats.samples))
                      + (idle_stats.std_w * idle_stats.std_w / static_cast<double>(idle_stats.samples)))
            : nan;
        const double energy = (idle_stats.samples && run_stats.samples) ? (dP_avg * run_stats.elapsed_s) : nan;
        const double power_latency = run.has_latency ? run.latency.avg : nan;
        const UIntStatsSummary cycle = summarize_uint64(run.fpga_cycles);
        const double power_fpga_cycle = cycle.n ? cycle.avg : nan;

        std::fprintf(f,
            "%s,%s,%s,%zu,%.6f,%zu,%.6f,%.6f,%.6f,%.6f,"
            "%.6f,%.6f,%.6f,%.6f,"
            "%.6f,%.6f,%.6f,"
            "%.6f,%.6f,%.6f,"
            "%.6f,%.6f,%.6f,%.6f,"
            "%.3f,%.3f,%d,%d,%.6f,%s,%d,%s\n",
            label,
            run.mode.c_str(),
            run.phase.c_str(),
            run_stats.samples,
            run_stats.elapsed_s,
            idle_stats.samples,
            idle_stats.avg_w,
            idle_stats.std_w,
            idle_vcc_stats.samples ? idle_vcc_stats.avg_w : nan,
            idle_pcie_stats.samples ? idle_pcie_stats.avg_w : nan,
            run_stats.min_w,
            run_stats.avg_w,
            run_stats.max_w,
            run_stats.std_w,
            run_vcc_stats.min_w,
            run_vcc_stats.avg_w,
            run_vcc_stats.max_w,
            run_pcie_stats.min_w,
            run_pcie_stats.avg_w,
            run_pcie_stats.max_w,
            dP_avg,
            dP_peak,
            dP_stderr,
            energy,
            power_latency,
            power_fpga_cycle,
            args.power_kernel_iterations,
            args.power_kernel_iterations_auto ? 1 : 0,
            args.power_target_sec,
            run.mode.c_str(),
            ::access((args.power_csv + ".truncated").c_str(), F_OK) == 0 ? 1 : 0,
            args.power_csv.c_str());
    }

    std::fclose(f);
    std::fprintf(msg, "[power] summary written to %s (raw samples: %s)\n",
                 args.power_summary.c_str(), args.power_csv.c_str());
    return true;
}

inline int clamp_power_iterations_from_double(double value) {
    if (!std::isfinite(value) || value < 1.0) {
        return 1;
    }
    const double max_int = static_cast<double>(std::numeric_limits<int>::max());
    if (value > max_int) {
        return std::numeric_limits<int>::max();
    }
    return static_cast<int>(value);
}

inline Args plan_power_measurement_args(const Args& args,
                                        double calibration_us,
                                        const char* label,
                                        FILE* msg = stderr) {
    Args planned = args;
    double kernel_s = calibration_us / 1000000.0;
    if (!std::isfinite(kernel_s) || kernel_s <= 0.0) {
        kernel_s = 0.000001;
    }

    const int desired_iterations =
        clamp_power_iterations_from_double(std::ceil(args.power_min_run_sec / kernel_s));
    const int max_iterations_by_time =
        clamp_power_iterations_from_double(std::floor(args.power_max_run_sec / kernel_s));
    planned.power_iterations = std::max(1, std::min(desired_iterations, max_iterations_by_time));
    const bool capped_by_max_iterations =
        args.power_max_iterations > 0 && planned.power_iterations > args.power_max_iterations;
    if (capped_by_max_iterations) {
        planned.power_iterations = args.power_max_iterations;
    }

    const double planned_run_s = static_cast<double>(planned.power_iterations) * kernel_s;
    double planned_interval = planned_run_s / static_cast<double>(std::max(1, args.power_target_samples));
    if (!std::isfinite(planned_interval) || planned_interval <= 0.0) {
        planned_interval = args.power_min_interval;
    }
    planned.power_interval = std::max(args.power_min_interval, std::min(planned_interval, args.power_max_interval));

    std::fprintf(msg,
        "[power] stage=auto_duration_plan label=%s calibration_us=%.3f "
        "estimated_kernel_s=%.6f iterations=%d interval=%.6g "
        "target_samples=%d min_run_s=%.3f max_run_s=%.3f "
        "max_iterations=%d capped=%s\n",
        label,
        calibration_us,
        kernel_s,
        planned.power_iterations,
        planned.power_interval,
        args.power_target_samples,
        args.power_min_run_sec,
        args.power_max_run_sec,
        args.power_max_iterations,
        capped_by_max_iterations ? "yes" : "no");
    std::fflush(msg);
    return planned;
}

inline bool should_log_power_iteration(int completed, int total) {
    if (total <= 20) {
        return true;
    }
    if (completed == 1 || completed == total) {
        return true;
    }
    const int step = std::max(1, total / 20);
    return (completed % step) == 0;
}

inline bool report_parse_error(const Args& args, FILE* err = stderr) {
    if (!args.parse_error) {
        return false;
    }
    std::fprintf(err, "Argument error: %s\n", args.parse_error_message.c_str());
    return true;
}

inline bool should_dump_iteration_perf(const Args& args) {
    return latency_enabled(args) && args.csv && !args.output.empty();
}

struct IterationPerf {
    bool has_fpga_cycle = false;
    uint64_t fpga_cycle = 0;
};

inline std::string power_truncation_marker(const Args& args) {
    return args.power_csv + ".truncated";
}

inline void reset_power_capture_files(const Args& args) {
    std::remove(args.power_csv.c_str());
    const std::string marker = power_truncation_marker(args);
    std::remove(marker.c_str());
}

class LatencyPowerMeasurement {
public:
    explicit LatencyPowerMeasurement(Args& args, FILE* msg = stderr)
        : args_(args), msg_(msg) {}

    ~LatencyPowerMeasurement() {
        sampler_.stop();
    }

    bool start() {
        return prestart() && begin_latency_window();
    }

    // Fork the sampler before opening XRT; inherited BO mappings break later
    // device-write/host-rewrite synchronization on hardware.
    bool prestart() {
        if (!power_enabled(args_) || !latency_enabled(args_)) {
            return true;
        }
        if (active_) {
            std::fprintf(msg_, "[power] ERROR: latency sampler already active\n");
            return false;
        }

        reset_power_capture_files(args_);

        Args idle_args = args_;
        idle_args.power_interval = args_.power_interval;
        if (!sampler_.start(idle_args, msg_)) {
            return false;
        }
        std::fprintf(msg_,
            "[power] stage=latency_idle_begin duration_s=%.3f interval=%.6g adaptive=%s\n",
            args_.power_idle_sec,
            idle_args.power_interval,
            args_.power_idle_policy.empty() ? "off" : "on");
        std::fflush(msg_);
        PowerPhase idle_phase;
        if (!capture_idle_phase(args_, &idle_phase, "latency", msg_)) {
            sampler_.stop();
            return false;
        }
        args_.power_latency_idle_start_s = idle_phase.start_s;
        args_.power_latency_idle_end_s = idle_phase.end_s;
        sampler_.stop();

        Args latency_args = args_;
        latency_args.power_interval = args_.power_latency_interval;
        if (!sampler_.start(latency_args, msg_)) {
            return false;
        }
        active_ = true;
        std::fprintf(msg_,
            "[power] stage=latency_sampler_start interval=%.6g target_samples=%d\n",
            latency_args.power_interval,
            args_.power_target_samples);
        std::fflush(msg_);
        return true;
    }

    // This only marks the measured interval and never creates a process.
    bool begin_latency_window() {
        if (!active_) {
            return true;
        }
        if (window_started_) {
            std::fprintf(msg_, "[power] ERROR: latency window already active\n");
            return false;
        }
        args_.power_latency_run_start_s = epoch_seconds();
        window_started_ = true;
        std::fprintf(msg_, "[power] stage=latency_window_start\n");
        std::fflush(msg_);
        return true;
    }

    bool finish(const StatsSummary& latency, const IterationPerf& perf) {
        if (!active_) {
            return true;
        }
        if (!window_started_) {
            std::fprintf(msg_, "[power] ERROR: latency window was not started\n");
            sampler_.stop();
            active_ = false;
            return false;
        }

        args_.power_latency_run_end_s = epoch_seconds();
        sampler_.stop();
        active_ = false;
        window_started_ = false;
        args_.power_latency_sampled = true;
        args_.power_latency_samples = latency.n;
        args_.power_latency_min_us = latency.min;
        args_.power_latency_avg_us = latency.avg;
        args_.power_latency_max_us = latency.max;
        args_.power_latency_p50_us = latency.p50;
        args_.power_latency_p95_us = latency.p95;
        args_.power_latency_has_fpga_cycle = perf.has_fpga_cycle;
        args_.power_latency_fpga_cycle = perf.fpga_cycle;
        args_.power_latency_kernel_iterations = args_.power_kernel_iterations;
        std::fprintf(msg_,
            "[power] stage=latency_sampler_stop elapsed_s=%.6f\n",
            args_.power_latency_run_end_s - args_.power_latency_run_start_s);
        std::fflush(msg_);
        return true;
    }

private:
    Args& args_;
    FILE* msg_;
    PowerSampler sampler_;
    bool active_ = false;
    bool window_started_ = false;
};

inline IterationPerf dump_iteration_perf(vx_device_h device,
                                         const Args& args,
                                         int iteration,
                                         FILE* stream = stdout) {
    IterationPerf perf;
    const bool should_dump = should_dump_iteration_perf(args);
    const int completed = iteration + 1;
    if (should_dump) {
        std::fprintf(stream, "[bench-perf] iteration=%d/%d begin\n", completed, args.iterations);
        std::fflush(stream);
        const int ret = vx_dump_perf(device, stream);
        if (ret != 0) {
            std::fprintf(stream, "[bench-perf] iteration=%d/%d vx_dump_perf_ret=%d\n",
                         completed, args.iterations, ret);
        }
        std::fprintf(stream, "[bench-perf] iteration=%d/%d end\n", completed, args.iterations);
        std::fflush(stream);
    }
    if (args.power_kernel_iterations_auto) {
        uint64_t fpga_cycle = 0;
        if (read_max_fpga_cycle(device, &fpga_cycle)) {
            perf.has_fpga_cycle = true;
            perf.fpga_cycle = fpga_cycle;
        }
    }
    return perf;
}

template <typename KernelArgs>
inline bool prepare_power_kernel_iterations(Args& args,
                                            KernelArgs& kernel_args,
                                            vx_buffer_h args_buffer,
                                            double first_latency_us,
                                            const IterationPerf& first_iter_perf,
                                            const char* label,
                                            FILE* msg = stderr) {
    if (!power_enabled(args)) {
        return true;
    }

    args.power_kernel_iterations = compute_power_kernel_iterations(
        args,
        first_latency_us,
        first_iter_perf.fpga_cycle,
        first_iter_perf.has_fpga_cycle,
        label,
        msg);
    kernel_args.power_kernel_iterations =
        static_cast<uint32_t>(args.power_kernel_iterations);

    const int ret = vx_copy_to_dev(args_buffer, &kernel_args, 0, sizeof(kernel_args));
    if (ret != 0) {
        std::fprintf(msg,
                     "[power] vx_copy_to_dev failed while enabling power kernel "
                     "iterations: label=%s ret=%d\n",
                     label,
                     ret);
        return false;
    }
    return true;
}

inline bool run_vx_kernel_once(vx_device_h device,
                               vx_buffer_h kernel_buffer,
                               vx_buffer_h args_buffer,
                               const char* phase,
                               int iter,
                               FILE* msg = stderr) {
    int ret = vx_start(device, kernel_buffer, args_buffer);
    if (ret != 0) {
        std::fprintf(msg, "[power] vx_start failed during %s iter=%d: ret=%d\n",
                     phase, iter, ret);
        return false;
    }

    ret = vx_ready_wait(device, VX_MAX_TIMEOUT);
    if (ret != 0) {
        std::fprintf(msg, "[power] vx_ready_wait failed during %s iter=%d: ret=%d\n",
                     phase, iter, ret);
        return false;
    }

    return true;
}

template <typename RunOnce, typename ReadFpgaCycle>
inline bool run_power_measurement_impl(const char* label,
                                       const Args& args,
                                       RunOnce run_once,
                                       ReadFpgaCycle read_fpga_cycle,
                                       bool measure_power_latency,
                                       FILE* msg) {
    if (!power_enabled(args)) {
        return true;
    }

    if (args.power_latency_sampled) {
        const PowerStats captured = read_power_stats(
            args.power_csv,
            args.power_latency_run_start_s,
            args.power_latency_run_end_s,
            "total_power_w");
        std::fprintf(msg,
            "[power] stage=latency_sample_check label=%s samples=%zu target_samples=%d "
            "elapsed_s=%.6f truncated=%s\n",
            label,
            captured.samples,
            args.power_target_samples,
            captured.elapsed_s,
            ::access(power_truncation_marker(args).c_str(), F_OK) == 0 ? "yes" : "no");
        std::fflush(msg);

        if (captured.samples >= static_cast<size_t>(args.power_target_samples)) {
            PowerPhase idle_phase;
            idle_phase.mode = "idle";
            idle_phase.phase = "idle";
            idle_phase.start_s = args.power_latency_idle_start_s;
            idle_phase.end_s = args.power_latency_idle_end_s;

            PowerPhase latency_phase;
            latency_phase.mode = "latency";
            latency_phase.phase = "run";
            latency_phase.start_s = args.power_latency_run_start_s;
            latency_phase.end_s = args.power_latency_run_end_s;
            latency_phase.has_latency = args.power_latency_samples > 0;
            latency_phase.latency.n = args.power_latency_samples;
            latency_phase.latency.min = args.power_latency_min_us;
            latency_phase.latency.avg = args.power_latency_avg_us;
            latency_phase.latency.max = args.power_latency_max_us;
            latency_phase.latency.p50 = args.power_latency_p50_us;
            latency_phase.latency.p95 = args.power_latency_p95_us;
            if (args.power_latency_has_fpga_cycle) {
                latency_phase.fpga_cycles.push_back(args.power_latency_fpga_cycle);
            }

            Args summary_args = args;
            summary_args.power_kernel_iterations = args.power_latency_kernel_iterations;
            summary_args.power_kernel_iterations_auto = false;
            std::fprintf(msg,
                "[power] stage=separate_skip label=%s reason=latency_samples_sufficient\n",
                label);
            std::fflush(msg);
            return write_power_summary(
                label, summary_args, idle_phase, {latency_phase}, msg);
        }

        std::fprintf(msg,
            "[power] stage=separate_fallback label=%s reason=latency_samples_low "
            "samples=%zu target_samples=%d\n",
            label,
            captured.samples,
            args.power_target_samples);
        std::fflush(msg);
    }

    reset_power_capture_files(args);
    Args power_args = args;
    if (args.power_auto_duration) {
        double calibration_us = 0.0;
        if (args.power_latency_sampled && args.power_latency_avg_us > 0.0) {
            calibration_us = args.power_latency_avg_us
                * static_cast<double>(std::max(1, args.power_kernel_iterations));
            std::fprintf(msg,
                "[power] stage=auto_duration_calibration_reuse label=%s "
                "latency_avg_us=%.3f kernel_iterations=%d estimated_us=%.3f\n",
                label,
                args.power_latency_avg_us,
                args.power_kernel_iterations,
                calibration_us);
            std::fflush(msg);
        } else {
            std::fprintf(msg, "[power] stage=auto_duration_calibration_begin label=%s\n", label);
            std::fflush(msg);
            Stopwatch sw;
            sw.start();
            if (!run_once("power_calibrate", 0)) {
                std::fprintf(msg, "[power] stage=auto_duration_calibration_failed label=%s\n", label);
                std::fflush(msg);
                return false;
            }
            calibration_us = sw.stop_us();
            std::fprintf(msg,
                "[power] stage=auto_duration_calibration_end label=%s calibration_us=%.3f\n",
                label,
                calibration_us);
            std::fflush(msg);
        }
        power_args = plan_power_measurement_args(args, calibration_us, label, msg);
    }

    std::fprintf(msg,
        "[power] stage=sampler_start label=%s mode=%s csv=%s summary=%s "
        "idle_s=%.3f iterations=%d kernel_iterations=%d kernel_iterations_auto=%s "
        "target_sec=%.6f interval=%.6g auto_duration=%s max_iterations=%d max_bytes=%llu\n",
        label,
        power_mode_name(power_args.power_mode),
        power_args.power_csv.c_str(),
        power_args.power_summary.c_str(),
        power_args.power_idle_sec,
        power_args.power_iterations,
        power_args.power_kernel_iterations,
        power_args.power_kernel_iterations_auto ? "on" : "off",
        power_args.power_target_sec,
        power_args.power_interval,
        power_args.power_auto_duration ? "on" : "off",
        power_args.power_max_iterations,
        static_cast<unsigned long long>(power_args.power_csv_max_bytes));
    std::fflush(msg);

    PowerSampler sampler;
    if (!sampler.start(power_args, msg)) {
        std::fprintf(msg, "[power] stage=sampler_start_failed label=%s\n", label);
        std::fflush(msg);
        return false;
    }

    PowerPhase idle_phase;
    std::fprintf(msg, "[power] stage=idle_begin label=%s duration_s=%.3f adaptive=%s\n",
                 label,
                 power_args.power_idle_sec,
                 power_args.power_idle_policy.empty() ? "off" : "on");
    std::fflush(msg);
    if (!capture_idle_phase(power_args, &idle_phase, label, msg)) {
        sampler.stop();
        return false;
    }
    std::fprintf(msg, "[power] stage=idle_end label=%s elapsed_s=%.6f\n",
                 label,
                 idle_phase.end_s - idle_phase.start_s);
    std::fflush(msg);

    std::vector<PowerPhase> power_runs;
    bool warned_missing_fpga_cycle = false;
    auto run_power_phase = [&](const char* mode, bool record_power_latency) -> bool {
        PowerPhase phase;
        phase.mode = mode;
        phase.phase = "run";
        phase.start_s = epoch_seconds();
        std::fprintf(msg,
            "[power] stage=run_begin label=%s mode=%s iterations=%d measure_latency=%s\n",
            label,
            mode,
            power_args.power_iterations,
            record_power_latency ? "on" : "off");
        std::fflush(msg);

        Stats phase_latency;
        for (int i = 0; i < power_args.power_iterations; ++i) {
            if (record_power_latency) {
                Stopwatch sw;
                sw.start();
                if (!run_once(mode, i)) {
                    std::fprintf(msg,
                        "[power] stage=run_failed label=%s mode=%s completed=%d/%d\n",
                        label,
                        mode,
                        i,
                        power_args.power_iterations);
                    std::fflush(msg);
                    return false;
                }
                phase_latency.record(sw.stop_us());
                uint64_t fpga_cycle = 0;
                if (read_fpga_cycle(&fpga_cycle)) {
                    phase.fpga_cycles.push_back(fpga_cycle);
                } else if (!warned_missing_fpga_cycle) {
                    std::fprintf(msg,
                        "[power] stage=fpga_cycle_unavailable label=%s mode=%s\n",
                        label,
                        mode);
                    std::fflush(msg);
                    warned_missing_fpga_cycle = true;
                }
            } else {
                if (!run_once(mode, i)) {
                    std::fprintf(msg,
                        "[power] stage=run_failed label=%s mode=%s completed=%d/%d\n",
                        label,
                        mode,
                        i,
                        power_args.power_iterations);
                    std::fflush(msg);
                    return false;
                }
            }
            const int completed = i + 1;
            if (should_log_power_iteration(completed, power_args.power_iterations)) {
                const double elapsed_s = epoch_seconds() - phase.start_s;
                std::fprintf(msg,
                    "[power] stage=run_progress label=%s mode=%s completed=%d/%d elapsed_s=%.6f\n",
                    label,
                    mode,
                    completed,
                    power_args.power_iterations,
                    elapsed_s);
                std::fflush(msg);
            }
        }

        phase.end_s = epoch_seconds();
        std::fprintf(msg,
            "[power] stage=run_end label=%s mode=%s completed=%d/%d elapsed_s=%.6f\n",
            label,
            mode,
            power_args.power_iterations,
            power_args.power_iterations,
            phase.end_s - phase.start_s);
        std::fflush(msg);
        if (record_power_latency) {
            phase.has_latency = true;
            phase.latency = phase_latency.summary();
        }
        power_runs.push_back(phase);
        return true;
    };

    bool power_ok = run_power_phase("separate", measure_power_latency);

    std::fprintf(msg, "[power] stage=sampler_stop_begin label=%s\n", label);
    std::fflush(msg);
    sampler.stop();
    std::fprintf(msg, "[power] stage=sampler_stop_end label=%s\n", label);
    std::fflush(msg);
    if (!power_ok) {
        return false;
    }
    std::fprintf(msg, "[power] stage=summary_begin label=%s summary=%s\n",
                 label,
                 power_args.power_summary.c_str());
    std::fflush(msg);
    return write_power_summary(label, power_args, idle_phase, power_runs, msg);
}

template <typename RunOnce>
inline bool run_power_measurement(const char* label,
                                  const Args& args,
                                  RunOnce run_once,
                                  bool measure_power_latency,
                                  FILE* msg = stderr) {
    return run_power_measurement_impl(
        label, args, run_once,
        [](uint64_t*) -> bool { return false; },
        measure_power_latency,
        msg);
}

template <typename RunOnce>
inline bool run_power_measurement(const char* label,
                                  const Args& args,
                                  RunOnce run_once,
                                  FILE* msg = stderr) {
    return run_power_measurement(label, args, run_once, args.power_measure_latency, msg);
}

template <typename RunOnce>
inline bool run_power_measurement(const char* label,
                                  const Args& args,
                                  vx_device_h device,
                                  RunOnce run_once,
                                  bool measure_power_latency,
                                  FILE* msg = stderr) {
    return run_power_measurement_impl(
        label, args, run_once,
        [device, msg](uint64_t* value) -> bool {
            return read_max_fpga_cycle(device, value, msg);
        },
        measure_power_latency,
        msg);
}

template <typename RunOnce>
inline bool run_power_measurement(const char* label,
                                  const Args& args,
                                  vx_device_h device,
                                  RunOnce run_once,
                                  FILE* msg = stderr) {
    return run_power_measurement(label, args, device, run_once, args.power_measure_latency, msg);
}

inline bool run_power_measurement(const char* label,
                                  const Args& args,
                                  vx_device_h device,
                                  vx_buffer_h kernel_buffer,
                                  vx_buffer_h args_buffer,
                                  bool measure_power_latency,
                                  FILE* msg = stderr) {
    return run_power_measurement(
        label, args, device,
        [&](const char* phase, int iter) -> bool {
            return run_vx_kernel_once(device, kernel_buffer, args_buffer, phase, iter, msg);
        },
        measure_power_latency,
        msg);
}

inline bool run_power_measurement(const char* label,
                                  const Args& args,
                                  vx_device_h device,
                                  vx_buffer_h kernel_buffer,
                                  vx_buffer_h args_buffer,
                                  FILE* msg = stderr) {
    return run_power_measurement(label, args, device, kernel_buffer, args_buffer, args.power_measure_latency, msg);
}

} // namespace vx_bench
