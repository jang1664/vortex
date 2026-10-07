# from tvm.script import ir as I
# from tvm.script import tirx as T
# from tvm.tirx.layout import Axis
# from tvm.script import relax as R

@I.ir_module
class Module:
    I.module_attrs({"vortex.c4.layout_policy": "fused", "vortex.w4a16.lowered": 2})
    @T.prim_func(private=True)
    def vortex_gemm_a_tiled_1_256(source: T.Buffer((1, 256), "float16"), tiled: T.Buffer((2048,), "float16")):
        T.func_attr({"op_pattern": 8, "tirx.is_scheduled": True, "tirx.noalias": True})
        for bx in T.thread_binding(16, thread="blockIdx.x"):
            for tx in T.thread_binding(128, thread="threadIdx.x"):
                index: T.int32 = bx * 128 + tx
                if index < 2048:
                    mt: T.int32 = index // 32768
                    within_mt: T.int32 = index % 32768
                    cur_m: T.int32 = T.min(128, 1 - mt * 128)
                    slot_m: T.int32 = (cur_m + 8 - 1) // 8 * 8
                    kt: T.int32 = within_mt // (slot_m * 128)
                    within_kt: T.int32 = within_mt % (slot_m * 128)
                    cur_k: T.int32 = T.min(128, 256 - kt * 128)
                    tiled[index] = T.float16(0.0)
                    if within_kt < cur_m * cur_k:
                        micro_k: T.int32 = within_kt // (cur_m * 16)
                        within_micro: T.int32 = within_kt % (cur_m * 16)
                        local_m: T.int32 = within_micro // 16
                        inner_k: T.int32 = within_micro % 16
                        global_m: T.int32 = mt * 128 + local_m
                        global_k: T.int32 = kt * 128 + micro_k * 16 + inner_k
                        if global_k < 256:
                            tiled[index] = source[global_m, global_k]

    @T.prim_func(private=True)
    def vortex_gemm_c_detile(tiled: T.Buffer((2048,), "float16"), output: T.Buffer((1, 256), "float16")):
        T.func_attr({"op_pattern": 8, "tirx.is_scheduled": True, "tirx.noalias": True})
        for bx in T.thread_binding(2, thread="blockIdx.x"):
            for tx in T.thread_binding(128, thread="threadIdx.x"):
                if bx * 128 + tx < 256:
                    index: T.int32 = bx * 128 + tx
                    global_m: T.int32 = index // 256
                    global_n: T.int32 = index % 256
                    mt: T.int32 = global_m // 128
                    local_m: T.int32 = global_m % 128
                    cur_m: T.int32 = T.min(128, 1 - mt * 128)
                    slot_m: T.int32 = (cur_m + 8 - 1) // 8 * 8
                    nt: T.int32 = global_n // 16
                    inner_n: T.int32 = global_n % 16
                    output[global_m, global_n] = tiled[mt * 128 * 256 + nt * slot_m * 16 + local_m * 16 + inner_n]

    @T.prim_func(private=True)
    def vortex_gemm_scale_tiled(source: T.Buffer((8, 256), "float16"), tiled: T.Buffer((2048,), "float16")):
        T.func_attr({"op_pattern": 8, "tirx.is_scheduled": True, "tirx.noalias": True})
        for bx in T.thread_binding(16, thread="blockIdx.x"):
            for tx in T.thread_binding(128, thread="threadIdx.x"):
                if bx * 128 + tx < 2048:
                    index: T.int32 = bx * 128 + tx
                    kt: T.int32 = index // 1024
                    within_kt: T.int32 = index % 1024
                    cur_k: T.int32 = T.min(128, 256 - kt * 128)
                    full_n_payload_bytes: T.int32 = cur_k // 32 * 128 * 2
                    full_n_slot_elements: T.int32 = (full_n_payload_bytes + 512 - 1) // 512 * 512 // 2
                    nt_dma: T.int32 = within_kt // full_n_slot_elements
                    slot_index: T.int32 = within_kt % full_n_slot_elements
                    cur_n: T.int32 = T.min(128, 256 - nt_dma * 128)
                    payload_elements: T.int32 = cur_k // 32 * cur_n
                    tiled[index] = T.Cast("float16", 0)
                    if slot_index < payload_elements:
                        groups: T.int32 = cur_k // 32
                        nb: T.int32 = slot_index // (groups * 16)
                        within_nb: T.int32 = slot_index % (groups * 16)
                        group: T.int32 = within_nb // 16
                        inner_n: T.int32 = within_nb % 16
                        global_group: T.int32 = kt * 4 + group
                        global_n: T.int32 = nt_dma * 128 + nb * 16 + inner_n
                        if global_group < 8 and global_n < 256:
                            tiled[index] = source[global_group, global_n]

    @T.prim_func(private=True)
    def vortex_gemm_w_tiled(source: T.Buffer((256, 128), "uint8"), tiled: T.Buffer((32768,), "uint8")):
        T.func_attr({"op_pattern": 8, "tirx.is_scheduled": True, "tirx.noalias": True})
        for bx in T.thread_binding(256, thread="blockIdx.x"):
            for tx in T.thread_binding(128, thread="threadIdx.x"):
                if bx * 128 + tx < 32768:
                    index: T.int32 = bx * 128 + tx
                    kt: T.int32 = index // 16384
                    within_kt: T.int32 = index % 16384
                    cur_k: T.int32 = T.min(128, 256 - kt * 128)
                    bytes_per_nt: T.int32 = cur_k * 16 // 2
                    nt: T.int32 = within_kt // bytes_per_nt
                    within_nt: T.int32 = within_kt % bytes_per_nt
                    tiled[index] = T.uint8(0)
                    local_k: T.int32 = within_nt // 8
                    n_pair: T.int32 = within_nt % 8
                    global_k: T.int32 = kt * 128 + local_k
                    global_n: T.int32 = nt * 16 + n_pair * 2
                    if global_k < 256 and global_n < 256:
                        tiled[index] = source[global_k, global_n // 2]
                        if global_n + 1 >= 256:
                            tiled[index] = T.bitwise_and(tiled[index], T.uint8(15))

    @T.prim_func(private=True)
    def vortex_gemm_zero_point_tiled(source: T.Buffer((8, 256), "int16"), tiled: T.Buffer((2048,), "int16")):
        T.func_attr({"op_pattern": 8, "tirx.is_scheduled": True, "tirx.noalias": True})
        for bx in T.thread_binding(16, thread="blockIdx.x"):
            for tx in T.thread_binding(128, thread="threadIdx.x"):
                if bx * 128 + tx < 2048:
                    index: T.int32 = bx * 128 + tx
                    kt: T.int32 = index // 1024
                    within_kt: T.int32 = index % 1024
                    cur_k: T.int32 = T.min(128, 256 - kt * 128)
                    full_n_payload_bytes: T.int32 = cur_k // 32 * 128 * 2
                    full_n_slot_elements: T.int32 = (full_n_payload_bytes + 512 - 1) // 512 * 512 // 2
                    nt_dma: T.int32 = within_kt // full_n_slot_elements
                    slot_index: T.int32 = within_kt % full_n_slot_elements
                    cur_n: T.int32 = T.min(128, 256 - nt_dma * 128)
                    payload_elements: T.int32 = cur_k // 32 * cur_n
                    tiled[index] = T.Cast("int16", 0)
                    if slot_index < payload_elements:
                        groups: T.int32 = cur_k // 32
                        nb: T.int32 = slot_index // (groups * 16)
                        within_nb: T.int32 = slot_index % (groups * 16)
                        group: T.int32 = within_nb // 16
                        inner_n: T.int32 = within_nb % 16
                        global_group: T.int32 = kt * 4 + group
                        global_n: T.int32 = nt_dma * 128 + nb * 16 + inner_n
                        if global_group < 8 and global_n < 256:
                            tiled[index] = source[global_group, global_n]

    @T.prim_func(private=True)
    def vortex_mm_w4a16_improve(lhs: T.Buffer((2048,), "float16"), packed: T.Buffer((32768,), "uint8"), scale: T.Buffer((2048,), "float16"), zero_point: T.Buffer((2048,), "int16"), output: T.Buffer((2048,), "float16")):
        T.func_attr({"op_pattern": 8, "tirx.is_scheduled": True, "tirx.noalias": True})
        for bx in T.thread_binding(1, thread="blockIdx.x"):
            for tx in T.thread_binding(1, thread="threadIdx.x"):
                T.call_extern("int32", "vx_tvm_gemm_w4a16_v2", lhs.data, packed.data, scale.data, zero_point.data, output.data, 1, 256, 256, 32, 0, 0, 2, 256, 256, 2)

    @R.function
    def main(a: R.Tensor((1, 256), dtype="float16"), w1: R.Tensor((256, 128), dtype="uint8"), s1: R.Tensor((8, 256), dtype="float16"), z1: R.Tensor((8, 256), dtype="int16"), w2: R.Tensor((256, 128), dtype="uint8"), s2: R.Tensor((8, 256), dtype="float16"), z2: R.Tensor((8, 256), dtype="int16")) -> R.Tensor((1, 256), dtype="float16"):
        cls = Module
        with R.dataflow():
            gemm_a_tiled = R.call_tir(cls.vortex_gemm_a_tiled_1_256, (a,), out_ty=R.Tensor((2048,), dtype="float16"))
            gemm_w_tiled = R.call_tir(cls.vortex_gemm_w_tiled, (w1,), out_ty=R.Tensor((32768,), dtype="uint8"))
            gemm_scale_tiled = R.call_tir(cls.vortex_gemm_scale_tiled, (s1,), out_ty=R.Tensor((2048,), dtype="float16"))
            gemm_zero_point_tiled = R.call_tir(cls.vortex_gemm_zero_point_tiled, (z1,), out_ty=R.Tensor((2048,), dtype="int16"))
            gemm_c_tiled = R.call_tir(cls.vortex_mm_w4a16_improve, (gemm_a_tiled, gemm_w_tiled, gemm_scale_tiled, gemm_zero_point_tiled), out_ty=R.Tensor((2048,), dtype="float16"))
            vortex_mm_w4a16 = R.call_tir(cls.vortex_gemm_c_detile, (gemm_c_tiled,), out_ty=R.Tensor((1, 256), dtype="float16"))
            gemm_a_tiled1 = R.call_tir(cls.vortex_gemm_a_tiled_1_256, (vortex_mm_w4a16,), out_ty=R.Tensor((2048,), dtype="float16"))
            gemm_w_tiled1 = R.call_tir(cls.vortex_gemm_w_tiled, (w2,), out_ty=R.Tensor((32768,), dtype="uint8"))
            gemm_scale_tiled1 = R.call_tir(cls.vortex_gemm_scale_tiled, (s2,), out_ty=R.Tensor((2048,), dtype="float16"))
            gemm_zero_point_tiled1 = R.call_tir(cls.vortex_gemm_zero_point_tiled, (z2,), out_ty=R.Tensor((2048,), dtype="int16"))
            gemm_c_tiled1 = R.call_tir(cls.vortex_mm_w4a16_improve, (gemm_a_tiled1, gemm_w_tiled1, gemm_scale_tiled1, gemm_zero_point_tiled1), out_ty=R.Tensor((2048,), dtype="float16"))
            vortex_mm_w4a161 = R.call_tir(cls.vortex_gemm_c_detile, (gemm_c_tiled1,), out_ty=R.Tensor((1, 256), dtype="float16"))
            gv: R.Tensor((1, 256), dtype="float16") = vortex_mm_w4a161
            R.output(gv)
        return gv