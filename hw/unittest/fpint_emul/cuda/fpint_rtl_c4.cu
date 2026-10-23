// A numerical CUDA emulator, not a throughput-optimized GEMM implementation.
// Frozen C4 geometry: K tile 16, N 16, signed INT4 weights, 19 extra bits.
#include <cuda_fp16.h>
#include <cuda_runtime.h>
#include <cstdint>
#include <cstring>

__global__ void rtl_c4_v1(const uint16_t* a, const int8_t* w,
                         const uint16_t* s, const int16_t* z,
                         const uint32_t* initial, uint16_t* result,
                         uint32_t* trace, int m_count, int k_count, int qdir) {
    int out = blockIdx.x * blockDim.x + threadIdx.x;
    if (out >= m_count * 16) return;
    int m = out / 16, n = out % 16;
    float acc = initial ? __uint_as_float(initial[out]) : 0.0f;
    for (int t = 0; t < k_count / 16; ++t) {
        uint16_t input[16];
        int max_exp = 1;
        for (int j = 0; j < 16; ++j) {
            int k = t * 16 + j;
            uint16_t bits = a[m * k_count + k];
            if (qdir == 1) {
                // A half product has <=22 significant bits, exact in FP32.
                float product = __fmul_rn(__half2float(__ushort_as_half(bits)),
                                          __half2float(__ushort_as_half(s[k])));
                bits = __half_as_ushort(__float2half_rn(product));
            }
            input[j] = bits;
            max_exp = max(max_exp, int((bits >> 10) & 31));
        }
        long long post = 0;
        for (int j = 0; j < 16; ++j) {
            uint16_t bits = input[j];
            int exp = (bits >> 10) & 31;
            long long mant = (bits & 1023) | (exp ? 1024 : 0);
            long long aligned = (mant << 19) >> (max_exp - max(exp, 1));
            if (bits & 0x8000) aligned = -aligned;
            int k = t * 16 + j;
            int param = qdir == 0 ? t * 16 + n : k;
            int neg_zero = ((-int(z[param]) + 32768) & 65535) - 32768;
            post += aligned * (int(w[k * 16 + n]) + neg_zero);
        }
        post = ((post + (1LL << 39)) & ((1LL << 40) - 1)) - (1LL << 39);
        // Conversion rounds once; power-of-two scaling stays normal/exact.
        float tile = ldexpf(__ll2float_rn(post), max_exp - 44);
        if (qdir == 0) {
            uint32_t h = s[t * 16 + n];
            // Intentional RTL behavior for zero/subnormal scales as well.
            uint32_t bits = ((h & 0x8000) << 16) | ((((h >> 10) & 31) + 112) << 23)
                            | ((h & 1023) << 13);
            tile = __fmul_rn(tile, __uint_as_float(bits));
        }
        acc = (t == 0 && !initial) ? tile : __fadd_rn(acc, tile);
        trace[t * m_count * 16 + out] = __float_as_uint(acc);
    }
    result[out] = __half_as_ushort(__float2half_rn(acc));
}

// Small checked host interface for ctypes. No CPU fallback.
template <typename T> struct DeviceBuffer {
    T* ptr = nullptr;
    ~DeviceBuffer() { if (ptr) cudaFree(ptr); }
    cudaError_t allocate(size_t count) { return cudaMalloc(reinterpret_cast<void**>(&ptr), count * sizeof(T)); }
    cudaError_t copy_in(const T* src, size_t count) { return cudaMemcpy(ptr, src, count * sizeof(T), cudaMemcpyHostToDevice); }
    cudaError_t copy_out(T* dst, size_t count) { return cudaMemcpy(dst, ptr, count * sizeof(T), cudaMemcpyDeviceToHost); }
};

#define CUDA_CHECK(expr) do { cudaError_t status = (expr); if (status != cudaSuccess) return int(status); } while (0)

extern "C" const char* fpint_cuda_version() { return "rtl-c4-v1"; }
extern "C" const char* fpint_cuda_error(int code) { return cudaGetErrorString(cudaError_t(code)); }
extern "C" int fpint_cuda_gemm(const char* version, int qdir, int m, int k,
                               const uint16_t* a, const int8_t* w,
                               const uint16_t* s, const int16_t* z,
                               const uint32_t* initial, uint16_t* result, uint32_t* trace) {
    if (std::strcmp(version, "rtl-c4-v1") || m < 1 || k < 16 || k % 16 || (qdir != 0 && qdir != 1))
        return int(cudaErrorInvalidValue);
    size_t ac = size_t(m)*k, wc = size_t(k)*16, sc = k, oc = size_t(m)*16, tc = oc*(k/16);
    DeviceBuffer<uint16_t> da, ds, dout;
    DeviceBuffer<int8_t> dw;
    DeviceBuffer<int16_t> dz;
    DeviceBuffer<uint32_t> di, dt;
    CUDA_CHECK(da.allocate(ac)); CUDA_CHECK(da.copy_in(a, ac));
    CUDA_CHECK(dw.allocate(wc)); CUDA_CHECK(dw.copy_in(w, wc));
    CUDA_CHECK(ds.allocate(sc)); CUDA_CHECK(ds.copy_in(s, sc));
    CUDA_CHECK(dz.allocate(sc)); CUDA_CHECK(dz.copy_in(z, sc));
    CUDA_CHECK(dout.allocate(oc)); CUDA_CHECK(dt.allocate(tc));
    if (initial) { CUDA_CHECK(di.allocate(oc)); CUDA_CHECK(di.copy_in(initial, oc)); }
    rtl_c4_v1<<<(oc+127)/128, 128>>>(da.ptr, dw.ptr, ds.ptr, dz.ptr, di.ptr,
                                   dout.ptr, dt.ptr, m, k, qdir);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());
    CUDA_CHECK(dout.copy_out(result, oc)); CUDA_CHECK(dt.copy_out(trace, tc));
    return 0;
}
