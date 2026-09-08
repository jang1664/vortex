#include "hbm_model.h"
#include <cassert>
#include <iostream>

int main() {
    for (unsigned beats : {1u, 2u, 4u}) {
        u55c::MemoryModel model;
        u55c::MemoryModel::Data data{};
        model.aw(0, beats, 0, beats);
        for (unsigned beat = 0; beat < beats; ++beat)
            model.w(0, data, ~uint64_t(0), beat + 1 == beats);
        // Request CDC: first fragment on edge 2, then two fragments/beat.
        // Buffered B crosses one return notification edge strictly after the
        // final admission, then two strictly later 1 ns receiving edges.
        uint64_t return_edge = 2 * beats + 2;
        uint64_t return_ps = (return_edge * 1000000000000ULL + U55C_HBM_AXI_FREQ_HZ - 1)
                           / U55C_HBM_AXI_FREQ_HZ;
        uint64_t expected_ps = (return_ps / 1000 + 2) * 1000;
        u55c::MemoryModel::Response response;
        for (uint64_t time = 1000; time <= expected_ps; time += 1000) {
            model.logic_edge(time);
            assert(model.write_response(0, response) == (time == expected_ps));
        }
        assert(response.id == beats);
        model.pop_write(0);
        assert(!model.write_response(0, response));
    }
    std::cout << "HBM write response uses one return notification per burst\n";
}
