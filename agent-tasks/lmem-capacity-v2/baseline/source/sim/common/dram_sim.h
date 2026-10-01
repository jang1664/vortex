// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#pragma once
#include <stdint.h>

namespace vortex {

class DramSim {
public:
  typedef void (*ResponseCallback)(void *arg);

  DramSim(uint32_t num_channels, uint32_t channel_size, float clock_ratio);
  enum class Profile { U55c };
  explicit DramSim(Profile profile, uint64_t frequency_hz = 1000000000);
  ~DramSim();

  void reset();

  void tick();

  // VCS raw path: exactly one DRAM cycle, no legacy ratio accumulator.
  void tick_raw();
  // No software queue or address rescaling. False means controller backpressure.
  // Write callback denotes buffered controller acceptance, not media completion.
  bool try_send_raw(uint64_t byte_addr, bool is_write, ResponseCallback callback, void* arg);
  uint64_t tck_ps() const;
  uint32_t transaction_bytes() const;

  // addr: per-channel block address
  void send_request(uint64_t addr, bool is_write, ResponseCallback response_cb, void* arg);

private:
	class Impl;
	Impl* impl_;
};

}
