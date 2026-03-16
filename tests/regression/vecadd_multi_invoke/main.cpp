#include <iostream>
#include <unistd.h>
#include <string.h>
#include <vector>
#include <fstream>
#include <sstream>
#include <iomanip>
#include <limits>
#include <type_traits>
#include <cstdint>
#include <cstdlib>
#include <vortex.h>
#include "common.h"

#define FLOAT_ULP 6

#define RT_CHECK(_expr)                                         \
   do {                                                         \
     int _ret = _expr;                                          \
     if (0 == _ret)                                             \
       break;                                                   \
     printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);   \
	 cleanup();			                                              \
     exit(-1);                                                  \
   } while (false)

///////////////////////////////////////////////////////////////////////////////

template <typename Type>
class Comparator {};

template <>
class Comparator<int> {
public:
  static const char* type_str() {
    return "integer";
  }
  static int generate() {
    return (rand() % 65) - 32;
  }
  static bool compare(int a, int b, int index, int errors) {
    if (a != b) {
      if (errors < 100) {
        printf("*** error: [%d] expected=%d, actual=%d\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

template <>
class Comparator<float> {
private:
  union Float_t { float f; int i; };
public:
  static const char* type_str() {
    return "float";
  }
  static float generate() {
    return static_cast<float>(rand()) / RAND_MAX;
  }
  static bool compare(float a, float b, int index, int errors) {
    union fi_t { float f; int32_t i; };
    fi_t fa, fb;
    fa.f = a;
    fb.f = b;
    auto d = std::abs(fa.i - fb.i);
    if (d > FLOAT_ULP) {
      if (errors < 100) {
        printf("*** error: [%d] expected=%f, actual=%f\n", index, b, a);
      }
      return false;
    }
    return true;
  }
};

const char* kernel_file = "kernel.vxbin";
const char* input_file = nullptr;
const char* dump_prefix = nullptr;
uint32_t size = 16;
uint32_t num_iterations = 3;

vx_device_h device = nullptr;
vx_buffer_h src0_buffer = nullptr;
vx_buffer_h src1_buffer = nullptr;
vx_buffer_h dst_buffer = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
kernel_arg_t kernel_arg = {};

static void show_usage() {
   std::cout << "Vortex Test." << std::endl;
   std::cout << "Usage: [-k kernel] [-n words] [-r iterations] [-i input_file] [-d dump_prefix] [-h]" << std::endl;
   std::cout << "  -i input_file : load fixed src0/src1 inputs from file (forces single iteration)" << std::endl;
   std::cout << "  -d dump_prefix: dump per-iteration input/output files" << std::endl;
}

static void parse_args(int argc, char **argv) {
  int c;
  while ((c = getopt(argc, argv, "n:k:r:i:d:h")) != -1) {
    switch (c) {
    case 'n':
      size = atoi(optarg);
      break;
    case 'k':
      kernel_file = optarg;
      break;
    case 'r':
      num_iterations = atoi(optarg);
      break;
    case 'i':
      input_file = optarg;
      break;
    case 'd':
      dump_prefix = optarg;
      break;
    case 'h':
      show_usage();
      exit(0);
      break;
    default:
      show_usage();
      exit(-1);
    }
  }
}

template <typename T>
static bool parse_value(const std::string& token, T& value) {
  std::istringstream iss(token);
  if constexpr (std::is_same<T, int>::value) {
    long long temp = 0;
    iss >> temp;
    if (iss.fail() || !iss.eof())
      return false;
    if (temp < std::numeric_limits<int>::min() || temp > std::numeric_limits<int>::max())
      return false;
    value = static_cast<int>(temp);
    return true;
  } else {
    T temp = 0;
    iss >> temp;
    if (iss.fail() || !iss.eof())
      return false;
    value = temp;
    return true;
  }
}

template <typename T>
static void write_value(std::ostream& os, T value) {
  if constexpr (std::is_floating_point<T>::value) {
    os << std::setprecision(std::numeric_limits<T>::max_digits10) << value;
  } else {
    os << value;
  }
}

template <typename T>
static bool load_input_data(const char* path,
                            uint32_t expected_points,
                            std::vector<T>& src0,
                            std::vector<T>& src1) {
  std::ifstream ifs(path);
  if (!ifs.is_open()) {
    std::cerr << "Failed to open input file: " << path << std::endl;
    return false;
  }

  std::string header;
  if (!std::getline(ifs, header)) {
    std::cerr << "Input file is empty: " << path << std::endl;
    return false;
  }

  auto type_pos = header.find("TYPE=");
  auto size_pos = header.find("SIZE=");
  if (type_pos == std::string::npos || size_pos == std::string::npos) {
    std::cerr << "Invalid input file header: " << header << std::endl;
    return false;
  }

  auto type_end = header.find(' ', type_pos);
  auto size_end = header.find(' ', size_pos);

  std::string file_type = header.substr(type_pos + 5,
    ((type_end == std::string::npos) ? header.size() : type_end) - (type_pos + 5));
  std::string file_size_str = header.substr(size_pos + 5,
    ((size_end == std::string::npos) ? header.size() : size_end) - (size_pos + 5));

  if (file_type != Comparator<T>::type_str()) {
    std::cerr << "Input file type mismatch: file=" << file_type
              << ", expected=" << Comparator<T>::type_str() << std::endl;
    return false;
  }

  char* endptr = nullptr;
  auto file_size_ul = std::strtoul(file_size_str.c_str(), &endptr, 10);
  if (endptr == file_size_str.c_str() || *endptr != '\0') {
    std::cerr << "Invalid SIZE in input file header: " << file_size_str << std::endl;
    return false;
  }

  auto file_size = static_cast<uint32_t>(file_size_ul);
  if (file_size != expected_points) {
    std::cerr << "Input file size mismatch: file=" << file_size
              << ", expected=" << expected_points << std::endl;
    return false;
  }

  src0.resize(file_size);
  src1.resize(file_size);

  uint32_t count = 0;
  std::string line;
  while (std::getline(ifs, line)) {
    if (line.empty() || line[0] == '#')
      continue;
    if (count >= file_size) {
      std::cerr << "Input file has too many data rows: " << path << std::endl;
      return false;
    }

    std::istringstream iss(line);
    std::string s0_token, s1_token, extra_token;
    if (!(iss >> s0_token >> s1_token) || (iss >> extra_token)) {
      std::cerr << "Invalid data row in input file: " << line << std::endl;
      return false;
    }

    if (!parse_value<T>(s0_token, src0[count]) || !parse_value<T>(s1_token, src1[count])) {
      std::cerr << "Failed to parse data row in input file: " << line << std::endl;
      return false;
    }

    ++count;
  }

  if (count != file_size) {
    std::cerr << "Input file row count mismatch: file_rows=" << count
              << ", expected=" << file_size << std::endl;
    return false;
  }

  return true;
}

template <typename T>
static bool dump_input_data(const char* path,
                            const std::vector<T>& src0,
                            const std::vector<T>& src1) {
  std::ofstream ofs(path);
  if (!ofs.is_open()) {
    std::cerr << "Failed to open dump file for input: " << path << std::endl;
    return false;
  }

  ofs << "TYPE=" << Comparator<T>::type_str() << " SIZE=" << src0.size() << "\n";
  for (size_t i = 0; i < src0.size(); ++i) {
    write_value(ofs, src0[i]);
    ofs << ' ';
    write_value(ofs, src1[i]);
    ofs << '\n';
  }

  return true;
}

template <typename T>
static bool dump_output_data(const char* path,
                             const std::vector<T>& src0,
                             const std::vector<T>& src1,
                             const std::vector<T>& dst) {
  std::ofstream ofs(path);
  if (!ofs.is_open()) {
    std::cerr << "Failed to open dump file for output: " << path << std::endl;
    return false;
  }

  ofs << "TYPE=" << Comparator<T>::type_str() << " SIZE=" << src0.size() << "\n";
  ofs << "# idx src0 src1 expected actual\n";
  for (size_t i = 0; i < src0.size(); ++i) {
    auto ref = src0[i] + src1[i];
    ofs << i << ' ';
    write_value(ofs, src0[i]);
    ofs << ' ';
    write_value(ofs, src1[i]);
    ofs << ' ';
    write_value(ofs, ref);
    ofs << ' ';
    write_value(ofs, dst[i]);
    ofs << '\n';
  }

  return true;
}

static std::string make_dump_path(const char* prefix, uint32_t iter, const char* kind) {
  std::ostringstream oss;
  oss << prefix << "_iter" << std::setw(4) << std::setfill('0') << (iter + 1) << "_" << kind << ".txt";
  return oss.str();
}

void cleanup() {
  if (src0_buffer) {
    vx_mem_free(src0_buffer);
    src0_buffer = nullptr;
  }
  if (src1_buffer) {
    vx_mem_free(src1_buffer);
    src1_buffer = nullptr;
  }
  if (dst_buffer) {
    vx_mem_free(dst_buffer);
    dst_buffer = nullptr;
  }
  if (krnl_buffer) {
    vx_mem_free(krnl_buffer);
    krnl_buffer = nullptr;
  }
  if (args_buffer) {
    vx_mem_free(args_buffer);
    args_buffer = nullptr;
  }

  if (device) {
    vx_dev_close(device);
    device = nullptr;
  }
}

int main(int argc, char *argv[]) {
  // parse command arguments
  parse_args(argc, argv);

  std::srand(10);

  // open device connection
  std::cout << "open device connection" << std::endl;
  RT_CHECK(vx_dev_open(&device));

  uint32_t num_points = size;
  uint32_t buf_size = num_points * sizeof(TYPE);

  std::cout << "number of points: " << num_points << std::endl;
  std::cout << "data type: " << Comparator<TYPE>::type_str() << std::endl;
  std::cout << "buffer size: " << buf_size << " bytes" << std::endl;
  std::cout << "number of iterations: " << num_iterations << std::endl;

  kernel_arg.num_points = num_points;

  int total_errors = 0;

  // allocate host buffers
  std::cout << "allocate host buffers" << std::endl;
  std::vector<TYPE> h_src0(num_points);
  std::vector<TYPE> h_src1(num_points);
  std::vector<TYPE> h_dst(num_points);
  std::vector<TYPE> fixed_src0;
  std::vector<TYPE> fixed_src1;

  if (input_file != nullptr) {
    std::cout << "load input data from file: " << input_file << std::endl;
    if (!load_input_data<TYPE>(input_file, num_points, fixed_src0, fixed_src1)) {
      cleanup();
      return -1;
    }
  }

  // generate random data
  for (uint32_t i = 0; i < num_points; ++i) {
    h_src0[i] = Comparator<TYPE>::generate();
    h_src1[i] = Comparator<TYPE>::generate();
  }

  for (uint32_t iter = 0; iter < num_iterations; ++iter) {
    std::cout << std::dec << std::endl;
    std::cout << "=== Iteration " << (iter + 1) << " / " << num_iterations << " ===" << std::endl;

    // if (input_file != nullptr) {
    //   h_src0 = fixed_src0;
    //   h_src1 = fixed_src1;
    // } else {
    //   // generate random data
    //   for (uint32_t i = 0; i < num_points; ++i) {
    //     h_src0[i] = Comparator<TYPE>::generate();
    //     h_src1[i] = Comparator<TYPE>::generate();
    //   }
    // }

    if (dump_prefix != nullptr) {
      auto input_dump_path = make_dump_path(dump_prefix, iter, "input");
      std::cout << "dump input: " << input_dump_path << std::endl;
      if (!dump_input_data<TYPE>(input_dump_path.c_str(), h_src0, h_src1)) {
        cleanup();
        return -1;
      }
    }

    // allocate device memory
    std::cout << "allocate device memory" << std::endl;
    RT_CHECK(vx_mem_alloc(device, buf_size, VX_MEM_READ, &src0_buffer));
    RT_CHECK(vx_mem_address(src0_buffer, &kernel_arg.src0_addr));
    RT_CHECK(vx_mem_alloc(device, buf_size, VX_MEM_READ, &src1_buffer));
    RT_CHECK(vx_mem_address(src1_buffer, &kernel_arg.src1_addr));
    RT_CHECK(vx_mem_alloc(device, buf_size, VX_MEM_READ_WRITE, &dst_buffer));
    RT_CHECK(vx_mem_address(dst_buffer, &kernel_arg.dst_addr));

    std::cout << "dev_src0=0x" << std::hex << kernel_arg.src0_addr << std::endl;
    std::cout << "dev_src1=0x" << std::hex << kernel_arg.src1_addr << std::endl;
    std::cout << "dev_dst=0x" << std::hex << kernel_arg.dst_addr << std::endl;

    // fill dst buffer to fixed pattern
    for(uint32_t i = 0; i < num_points; ++i) {
      h_dst[i] = 0xDEADBEEF;
    }

    // Upload kernel binary (once)
    std::cout << "Upload kernel binary" << std::endl;
    RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

    // upload source buffer0
    std::cout << "upload source buffer0" << std::endl;
    RT_CHECK(vx_copy_to_dev(src0_buffer, h_src0.data(), 0, buf_size));

    // upload source buffer1
    std::cout << "upload source buffer1" << std::endl;
    RT_CHECK(vx_copy_to_dev(src1_buffer, h_src1.data(), 0, buf_size));

    // upload destination buffer (optional, to verify write capability and initial content doesn't affect result)
    std::cout << "upload destination buffer" << std::endl;
    RT_CHECK(vx_copy_to_dev(dst_buffer, h_dst.data(), 0, buf_size));

    // upload kernel argument
    std::cout << "upload kernel argument" << std::endl;
    RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));

    // start device
    std::cout << "start device" << std::endl;
    RT_CHECK(vx_start(device, krnl_buffer, args_buffer));

    // wait for completion
    std::cout << "wait for completion" << std::endl;
    RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
    // usleep(1000); // ensure device has finished all memory transactions after ready

    // download destination buffer
    std::cout << "download destination buffer" << std::endl;
    RT_CHECK(vx_copy_from_dev(h_dst.data(), dst_buffer, 0, buf_size));

    if (dump_prefix != nullptr) {
      auto output_dump_path = make_dump_path(dump_prefix, iter, "output");
      std::cout << "dump output: " << output_dump_path << std::endl;
      if (!dump_output_data<TYPE>(output_dump_path.c_str(), h_src0, h_src1, h_dst)) {
        cleanup();
        return -1;
      }
    }

    // verify result
    std::cout << "verify result" << std::endl;
    int errors = 0;
    for (uint32_t i = 0; i < num_points; ++i) {
      auto ref = h_src0[i] + h_src1[i];
      auto cur = h_dst[i];
      if (!Comparator<TYPE>::compare(cur, ref, i, errors)) {
        ++errors;
      }
    }

    if (errors != 0) {
      std::cout << "Iteration " << (iter + 1) << ": Found " << std::dec << errors << " errors!" << std::endl;
      total_errors += errors;
    } else {
      std::cout << "Iteration " << (iter + 1) << ": PASSED" << std::endl;
    }

    // free all device buffers for this iteration, keep device open
    std::cout << std::endl << "free iteration buffers" << std::endl;
    if (src0_buffer) {
      RT_CHECK(vx_mem_free(src0_buffer));
      src0_buffer = nullptr;
    }
    if (src1_buffer) {
      RT_CHECK(vx_mem_free(src1_buffer));
      src1_buffer = nullptr;
    }
    if (dst_buffer) {
      RT_CHECK(vx_mem_free(dst_buffer));
      dst_buffer = nullptr;
    }
    if (krnl_buffer) {
      RT_CHECK(vx_mem_free(krnl_buffer));
      krnl_buffer = nullptr;
    }
    if (args_buffer) {
      RT_CHECK(vx_mem_free(args_buffer));
      args_buffer = nullptr;
    }
  }

  std::cout << std::endl << "cleanup device" << std::endl;
  cleanup();

  if (total_errors != 0) {
    std::cout << "Total errors: " << std::dec << total_errors << std::endl;
    std::cout << "FAILED!" << std::endl;
    return 1;
  }

  std::cout << "All " << std::dec << num_iterations << " iterations PASSED!" << std::endl;

  return 0;
}
