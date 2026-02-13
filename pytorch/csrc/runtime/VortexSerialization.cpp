#include "VortexSerialization.h"

namespace c10::vortex {

struct VortexBackendMeta : public c10::BackendMeta {
  VortexBackendMeta(int version_number, int format_number)
      : version_number_(version_number), format_number_(format_number) {}

  int version_number_{-1};
  int format_number_{-1};
};

void for_serialization(
    const at::Tensor& t,
    std::unordered_map<std::string, bool>& m) {
  auto meta_ptr = t.unsafeGetTensorImpl()->get_backend_meta();
  if (meta_ptr != nullptr) {
    auto v_meta = dynamic_cast<VortexBackendMeta*>(meta_ptr);
    if (v_meta && v_meta->version_number_ == 1) {
      m["version_number"] = true;
    }
    if (v_meta && v_meta->format_number_ == 29) {
      m["format_number"] = true;
    }
  }
}

void for_deserialization(
    const at::Tensor& t,
    std::unordered_map<std::string, bool>& m) {
  int version_number = -1;
  int format_number = -1;

  if (m.find("version_number") != m.end()) {
    version_number = 1;
  }
  if (m.find("format_number") != m.end()) {
    format_number = 29;
  }

  c10::intrusive_ptr<c10::BackendMeta> meta{std::unique_ptr<c10::BackendMeta>(
      new VortexBackendMeta(version_number, format_number))};
  t.unsafeGetTensorImpl()->set_backend_meta(meta);
}

REGISTER_PRIVATEUSE1_SERIALIZATION(&for_serialization, &for_deserialization)

} // namespace c10::vortex
