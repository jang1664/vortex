// Operation descriptors already contain device addresses. Move their buffer
// ownership under layer-specific names and feed the previous output directly
// to the next layer without a host transfer.
void Decoder::append_layer(const fs::path& fixture, uint32_t index) {
  if (index != layer_ + 1) throw std::invalid_argument("non-sequential decoder layer");
  auto previous = std::move(buffers_);
  buffers_.clear();
  const std::string prefix = "layer-" + std::to_string(index - 1) + "/";
  for (auto& op : ops_) {
    if (op.name.find('/') != std::string::npos) continue;
    op.name = prefix + op.name;
    for (auto& name : op.inputs) name = prefix + name;
    for (auto& name : op.outputs) name = prefix + name;
  }
  while (!previous.empty()) {
    auto node = previous.extract(previous.begin());
    if (node.key().find('/') == std::string::npos) node.key() = prefix + node.key();
    buffers_.insert(std::move(node));
  }
  auto hidden = buffers_.at(prefix + "output");
  hidden.borrowed = true;
  buffers_.emplace("hidden", hidden);
  layer_ = index;
  starts_.push_back(ops_.size());
  uploads_.emplace_back();
  load(fixture);
  build();
}

void Decoder::prepare_iteration() {
  if (slots_ > layer_) return;
  for (auto& group : uploads_) {
    for (auto& upload : group) {
      if (!upload.host.empty()) continue;
      upload.host.resize(upload.bytes);
      std::ifstream file(upload.file, std::ios::binary);
      if (!file.read(reinterpret_cast<char*>(upload.host.data()), upload.bytes))
        throw std::runtime_error("short stack fixture: " + upload.file.string());
    }
  }
  stage_group(0);
  first_group_ready_ = true;
}

void Decoder::stage_group(uint32_t first) {
  for (uint32_t i = first; i < std::min(layer_ + 1, first + slots_); ++i) {
    for (const auto& upload : uploads_[i]) {
      rt_check(vx_copy_to_dev(upload.buffer, upload.host.data(), 0, upload.bytes),
               "stage decoder layer");
    }
  }
}

void Decoder::spill_kv(uint32_t first, uint32_t end) {
  for (size_t i = starts_.at(first); i < starts_.at(end); ++i) {
    const auto& op = ops_[i];
    if (op.kind != DecoderOp::quant) continue;
    for (const auto& name : op.outputs) {
      // The C4 quantizer also emits scratch copies of its metadata.
      if (name.find(".logical_") != std::string::npos) continue;
      const auto& buffer = buffers_.at(name);
      auto& host = spilled_kv_[name];
      host.resize(buffer.bytes);
      rt_check(vx_copy_from_dev(host.data(), buffer.handle, 0, buffer.bytes),
               "spill decoder KV");
    }
  }
}
