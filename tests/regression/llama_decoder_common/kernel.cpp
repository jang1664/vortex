#include "common.h"
#include <vx_intrinsics.h>
int llama_rms_main();
int llama_rope_main();
int llama_hadamard_main();
int llama_quant_main();
int llama_dequant_main();
int llama_softmax_main();
int llama_concat_main();
int llama_silu_main();
int llama_elmul_main();
int llama_eladd_main();
int llama_tcu_main();
int llama_naive_main();
int llama_reorder_main();
int main() {
 auto saved=csr_read(VX_CSR_MSCRATCH);
 auto* p=reinterpret_cast<const DecoderDispatch*>(saved);
 auto op=p->operation; csr_write(VX_CSR_MSCRATCH,p->args_address);
 int r=-1; switch(op) {
case DecoderOp::rms: r=llama_rms_main(); break;
case DecoderOp::rope: r=llama_rope_main(); break;
case DecoderOp::hadamard: r=llama_hadamard_main(); break;
case DecoderOp::quant: r=llama_quant_main(); break;
case DecoderOp::dequant: r=llama_dequant_main(); break;
case DecoderOp::softmax: r=llama_softmax_main(); break;
case DecoderOp::concat: r=llama_concat_main(); break;
case DecoderOp::silu: r=llama_silu_main(); break;
case DecoderOp::elmul: r=llama_elmul_main(); break;
case DecoderOp::eladd: r=llama_eladd_main(); break;
#if DECODER_CANDIDATE != 3
case DecoderOp::tcu: r=llama_tcu_main(); break;
#endif
#if DECODER_CANDIDATE != 1
case DecoderOp::gemm: r=llama_naive_main(); break;
#endif
case DecoderOp::reorder:r=llama_reorder_main();break;
default:break;
} csr_write(VX_CSR_MSCRATCH,saved);return r;
}
