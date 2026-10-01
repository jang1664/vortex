#include "tests/regression/softmax_common/fp16_output.h"
#include <cmath>
#include <cstdio>

int main() {
  unsigned cases = 0;
  for (unsigned bits = 0; bits <= 0x3c00; ++bits) {
    const float value = fp16_to_float((fp16_t)bits);
    const float next = fp16_to_float((fp16_t)(bits + 1));
    const float midpoint = (value + next) * 0.5f;
    const float inputs[] = {value, midpoint, std::nextafter(midpoint, 0.0f),
                            std::nextafter(midpoint, INFINITY)};
    for (float input : inputs) {
      if (softmax_probability_to_fp16(input) != float_to_fp16(input)) {
        std::printf("Mismatch: input=%a bits=%x\n", input, bits);
        return 1;
      }
      ++cases;
    }
  }
  std::printf("PASS: %u normal, subnormal, midpoint, and adjacent cases\n", cases);
}
