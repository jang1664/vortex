#include "common.h"
#include <vx_intrinsics.h>
int llama_gemm_main();
int llama_rms_main();
int llama_rope_main();
int llama_hadamard_main();
int llama_quant_main();
int llama_softmax_main();
int llama_concat_main();
int llama_silu_main();
int llama_elmul_main();
int llama_eladd_main();

int main() {
  auto packet = reinterpret_cast<const DecoderDispatch*>(csr_read(VX_CSR_MSCRATCH));
  auto saved = csr_read(VX_CSR_MSCRATCH);
  const auto operation = packet->operation;
  csr_write(VX_CSR_MSCRATCH, packet->args_address);
  int result = -1;
  switch (operation) {
    case DecoderOp::gemm: result = llama_gemm_main(); break;
    case DecoderOp::rms: result = llama_rms_main(); break;
    case DecoderOp::rope: result = llama_rope_main(); break;
    case DecoderOp::hadamard: result = llama_hadamard_main(); break;
    case DecoderOp::quant: result = llama_quant_main(); break;
    case DecoderOp::softmax: result = llama_softmax_main(); break;
    case DecoderOp::concat: result = llama_concat_main(); break;
    case DecoderOp::silu: result = llama_silu_main(); break;
    case DecoderOp::elmul: result = llama_elmul_main(); break;
    case DecoderOp::eladd: result = llama_eladd_main(); break;
  }
  csr_write(VX_CSR_MSCRATCH, saved);
  return result;
}
