#pragma once

#include <memory>

template<class Factory>
std::unique_ptr<Decoder> build_decoder_stack(Factory make_decoder,
    const std::filesystem::path& stack_root, std::filesystem::path& fixture,
    uint32_t layers, uint32_t resident_layers, uint32_t& slots) {
    std::unique_ptr<Decoder> instance;
    slots = std::min(layers, resident_layers);
    uint64_t free_before = 0;
    for (;;) {
      try {
        instance = make_decoder();
        free_before = instance->free_hbm();
        instance->configure_residency(slots);
        fixture = layers == 1 ? stack_root : stack_root / "layer-0";
        instance->load(fixture);
        instance->build();
        for (uint32_t layer = 1; layer < layers; ++layer) {
          fixture = stack_root / ("layer-" + std::to_string(layer));
          instance->append_layer(fixture, layer);
        }
        break;
      } catch (const std::runtime_error& e) {
        if (resident_layers != UINT32_MAX || slots == 1 ||
            std::string(e.what()).find("allocate tensor: status=") != 0) throw;
        instance.reset();
        --slots;
      }
    }

    std::cout << "STACK layers=" << layers << " resident_layers=" << slots
              << " free_hbm_before=" << free_before << " free_hbm_after=" << instance->free_hbm() << std::endl;
    return instance;
}
