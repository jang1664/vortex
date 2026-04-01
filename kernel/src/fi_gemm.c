#include <stdio.h>
#include <stdbool.h>
#include <math.h>

/*  
    This kernel is designed for fp16 activation - int4 static quantized weight gemm operation. 
    input:
      - shape  : M x K, float16
      - layout : (k,MXU_KT),(m,MT),(k,K/MXU_KT),(m,M/MT))  //가장 안 쪽에 있는 인덱스부터 나열
    weight:
     - K x N, int4 (packed)
     - (n,MXU_NT),(k,KT),(n,N/MXU_NT),(k,K/KT))
     - if transposed : (k,MXU_KT),(n,NT),(k,K/KT),(n,N/MXU_NT))
    output:
      - M x N, float16
      - (n,MXU_NT),(m,MT),(n,N/MXU_NT),(m,M/MT))
      - output layout can be other form.
    scale: //QDIR_COL 기준 설명
      - G x N (G == K / quant_blk_size), float16
      - (n,MXU_NT),(g,KT/quant_blk_size),(n,N/MXU_NT),(g,K/(KT/quant_blk_size)))
    zp:
      - g x N, int16
      - (n,MXU_NT),(g,KT/quant_blk_size),(n,N/MXU_NT),(g,K/(KT/quant_blk_size)))

    quant_blk_size: int
      - 2의 거듭제곱이어야 한다.

    Applied Double buffering in DMA-tile level and MXU-tile level

    Constraints:
      - M, N are multiples of MXU_NT(32), K is a multiple of KT(128).
      - KT % quant_blk_size == 0 for QDIR_COL, NT % quant_blk_size == 0 for QDIR_ROW

*/

// Tiling parameters
static const int MT = 128;
static const int NT = 128;
static const int KT = 128;
static const int MXU_KT = 32;
static const int MXU_NT = 32;

static const int TP = 1; // transpose
static const int NO_TP = 0; // no transpose


#define GMEM_SIZE (512*1024)
#define GMEM_IBUF0_BASE 0x100000
#define GMEM_IBUF1_BASE 0x180000
#define GMEM_WBUF0_BASE 0x200000
#define GMEM_WBUF1_BASE 0x280000
#define GMEM_OBUF0_BASE 0x300000
#define GMEM_OBUF1_BASE 0x380000
#define GEMM_SCBUF0_BASE  0x400000
#define GEMM_ZP0_BASE  0x480000
#define GEMM_SCBUF1_BASE  0x500000
#define GEMM_ZP1_BASE  0x580000

#define QDIR_COL 0
#define QDIR_ROW 1

/*
- quant_direction
  weight quantization direction
  - 0: col direction
  - 1: row direction
- weight_transposed
  flag whether weight is transposed
  0: not
  1: yes

- frequently used combinations
  - is_bias=0, quant_direction=0, weight_transposed=0 -> QKV gen and FFN
  - is_bias=0, quant_direction=0, weight_transposed=1 -> QK^T
  - is_bias=0, quant_direction=1, weight_transposed=0 -> PV
    in this case, you assume quant block size is N
*/
//TODO: we should take layout of operands as arguments.

static void fi_fpint_gemm_tile_layout_general(
  _Float16 *input, int8_t *weight, _Float16 *output, _Float16 *scale, int8_t *zp, _Float16 *bias, 
  int is_bias, int M, int N, int K, int quant_blk_size,
  uint8_t quant_direction, uint8_t weight_transposed){

    // Double buffering for activations, weights, scale, and zp
    uint64_t input_tmem_0  = GMEM_IBUF0_BASE;  // % 2048 == 0 인게 제일 베스트
    uint64_t input_tmem_1  = GMEM_IBUF1_BASE;

    uint64_t weight_tmem_0 = GMEM_WBUF0_BASE;
    uint64_t weight_tmem_1 = GMEM_WBUF1_BASE;

    uint64_t scale_tmem_0  = GEMM_SCBUF0_BASE;
    uint64_t zp_tmem_0     = GEMM_ZP0_BASE;  // GEMM_ZP0_BASE = GEMM_SCBUF0_BASE + KT/quant_blk_size * NT * sizeof(_Float16) 이면 베스트. SC랑 ZP를 한 번에 보낼 수 있음

    uint64_t scale_tmem_1  = GEMM_SCBUF1_BASE;
    uint64_t zp_tmem_1     = GEMM_ZP1_BASE;  // GEMM_ZP1_BASE = GEMM_SCBUF1_BASE + KT/quant_blk_size * NT * sizeof(_Float16) 이면 베스트. SC랑 ZP를 한 번에 보낼 수 있음
    
    uint64_t output_tmem_0 = GMEM_OBUF0_BASE;
    uint64_t output_tmem_1 = GMEM_OBUF1_BASE;

    uint64_t accum_base    = 0;

    // dram address
    uint64_t input_dram  = (uint64_t)input;
    uint64_t weight_dram = (uint64_t)weight;
    uint64_t output_dram = (uint64_t)output;
    uint64_t scale_dram  = (uint64_t)scale;
    uint64_t zp_dram     = (uint64_t)zp;

    // DMA Tile dimensions
    const int mt_dim = CEIL(M, MT);
    const int nt_dim = CEIL(N, NT);
    const int kt_dim = CEIL(K, KT);

    // padding is needed by 32
    const int M_PAD = CEIL(M, 32) * 32;  //padding 붙인 M 크기
    const int m_padding = M_PAD - M;  // 얼만큼 padding 해야하는지
    const int N_PAD = CEIL(N, MXU_NT) * MXU_NT;  //padding 붙인 N 크기
    const int n_padding = N_PAD - N;  // 얼만큼 padding 해야하는지
    // padding is needed by KT
    const int K_PAD = CEIL(K, KT) * KT;  //padding 붙인 K 크기
    const int k_padding = K_PAD - K;  // 얼만큼 padding 해야하는지
    // 사실 패딩 필요없음, 들어올 때부터 M, N은 32의 배수로, K는 128의 배수로 들어온다고 가정

    // size of last DMA tile
    const int m_last = M_PAD - (mt_dim - 1) * MT;
    const int n_last = N_PAD - (nt_dim - 1) * NT;
    const int k_last = K_PAD - (kt_dim - 1) * KT;

    // Inital load for double buffering 
    const int mt_eff_init = (mt_dim == 1) ? m_last : MT;
    const int nt_eff_init = (nt_dim == 1) ? n_last : NT;
    const int kt_eff_init = (kt_dim == 1) ? k_last : KT;
    const int eff_groups_per_tile_init = (quant_direction==QDIR_COL) ? CEIL(kt_eff_init, quant_blk_size) : CEIL(nt_eff_init, quant_blk_size); //quant group 개수

    // Load activation
    DMA_LOAD(input_tmem_0, input_dram, 1); // <Tmem_base_addr(24b), dram_base_address(36b), 1(opcode, 4bit)>
    DMA_LOAD(MT * MXU_KT * sizeof(_Float16), mt_eff_init * MXU_KT * sizeof(_Float16), kt_eff_init/MXU_KT);  // <tmem_stride0(16b), dram_stride0(16b), bound0(16b)>
    DMA_LOAD(mt_eff_init * MXU_KT * sizeof(_Float16));  // <seg_size(32b)>

    // Load weight
    DMA_LOAD(weight_tmem_0, weight_dram, 1); // <Tmem_base_addr(24b), dram_base_address(36b), 1(opcode, 4bit)>
    DMA_LOAD(0, 0, 1);  // <tmem_stride0(16b), dram_stride0(16b), bound0(16b)>
    DMA_LOAD(kt_eff_init * nt_eff_init * (sizeof(int8_t)/2));  // <seg_size(32b)>

    // Load scale and zero point all at once
    if (quant_direction == QDIR_COL) {
      DMA_LOAD(scale_tmem_0, scale_dram, 1); // <Tmem_base_addr(24b), dram_base_address(36b), 1(opcode, 4bit)>
      DMA_LOAD(0, 0, 1);  // <tmem_stride0(16b), dram_stride0(16b), bound0(16b)>
      DMA_LOAD(eff_groups_per_tile_init * nt_eff_init * (sizeof(_Float16)) * 2);  // <seg_size(32b)>
    } else {
      DMA_LOAD(scale_tmem_0, scale_dram, 1); // <Tmem_base_addr(24b), dram_base_address(36b), 1(opcode, 4bit)>
      DMA_LOAD(0, 0, 1);  // <tmem_stride0(16b), dram_stride0(16b), bound0(16b)>
      DMA_LOAD(eff_groups_per_tile_init * kt_eff_init * (sizeof(_Float16)) * 2);  // <seg_size(32b)>
    }

    // Load input and weight into shared memory
    // dbg_printf3("MT_NUM:%d NT_NUM:%d KT_NUM:%d\n", mt_dim, nt_dim, kt_dim);
    for (int nt = 0; nt < nt_dim; nt++) {

        int nt_eff = (nt == nt_dim - 1) ? n_last : NT;
        int nt_pad = (nt == nt_dim - 1) ? n_padding : 0;

        for (int mt = 0; mt < mt_dim; mt++){

            const int mt_eff = (mt == mt_dim - 1) ? m_last : MT;

            for (int kt = 0; kt < kt_dim; kt++) {
                // dbg_printf3("mt:%d nt:%d kt:%d\n", mt, nt, kt);

                const int kt_eff = (kt == kt_dim - 1) ? k_last : KT;

                // calculate next tile index
                int nkt = (kt + 1 == kt_dim) ? 0 : kt + 1; 
                int nmt = (kt + 1 == kt_dim) ? ((mt + 1 == mt_dim) ? 0 : mt + 1) : mt;
                int nnt = (kt + 1 == kt_dim) ? ((mt + 1 == mt_dim) ? nt + 1 : nt) : nt;

                // preload next tile if not the last tile  // 다음 (M, N, K) 타일을 DMA로 미리 가져온다 (더블 버퍼링)
                if(nnt != nt_dim){
                    const int mt_eff_next = (nmt == mt_dim - 1) ? m_last : MT;
                    const int nt_eff_next = (nnt == nt_dim - 1) ? n_last : NT;
                    const int nt_pad_next = (nnt == nt_dim - 1) ? n_padding : 0;
                    const int kt_eff_next = (nkt == kt_dim - 1) ? k_last : KT;
                    const int eff_groups_per_tile_next = kt_eff_next / quant_blk_size;
                    
                    // Load activation
                    uint64_t input_tile_dram_next = input_dram + (nkt + nmt*CEIL(K,KT)) * (MT*KT*sizeof(_Float16));
                    DMA_LOAD(input_tmem_1, input_tile_dram_next, 1); // <Tmem_base_addr(24b), dram_base_address(36b), 1(opcode, 4bit)>
                    DMA_LOAD(MT * MXU_KT * sizeof(_Float16), mt_eff_next * MXU_KT * sizeof(_Float16), kt_eff_next/MXU_KT);  // <tmem_stride0(16b), dram_stride0(16b), bound0(16b)>
                    DMA_LOAD(mt_eff_next * MXU_KT * sizeof(_Float16));  // <seg_size(32b)>

                    // Load weight
                    uint32_t weight_tile_idx;
                    if(weight_transposed) {
                      weight_tile_idx = (nkt + nnt*CEIL(K,KT));
                    } else {
                      weight_tile_idx = (nnt + nkt*CEIL(N,NT));
                    }
                    uint64_t weight_tile_dram_next = weight_dram + weight_tile_idx * (KT * NT * sizeof(int8_t))/2;
                    DMA_LOAD(weight_tmem_1, weight_tile_dram_next, 1); // <Tmem_base_addr(24b), dram_base_address(36b), 1(opcode, 4bit)>
                    DMA_LOAD(0, 0, 1);  // <tmem_stride0(16b), dram_stride0(16b), bound0(16b)>
                    DMA_LOAD(kt_eff_next * nt_eff_next * (sizeof(int8_t)/2));  // <seg_size(32b)>

                    // Load scale and zero point all at once
                    uint32_t sz_tile_idx;
                    if(quant_direction == QDIR_COL){
                      sz_tile_idx = (nnt + nkt * CEIL(N,NT));
                    } else { // QDIR_ROW
                      sz_tile_idx = (nkt + nnt * CEIL(K,KT));
                      //sz_tile_idx = nkt; 
                    }
                    uint64_t scale_tile_dram_next = scale_dram;
                    if(quant_direction == QDIR_COL) {
                      scale_tile_dram_next += sz_tile_idx * (CEIL(KT,quant_blk_size) * NT * sizeof(_Float16) * 2); // nnt * KT / quant_blk_size = curr_group
                    } else { // QDIR_ROW
                      scale_tile_dram_next += sz_tile_idx * (CEIL(NT,quant_blk_size) * KT * sizeof(_Float16) * 2); // nkt * NT / quant_blk_size = curr_group
                    }

                    if (quant_direction == QDIR_COL) {
                      DMA_LOAD(scale_tmem_1, scale_tile_dram_next, 1); // <Tmem_base_addr(24b), dram_base_address(36b), 1(opcode, 4bit)>
                      DMA_LOAD(0, 0, 1);  // <tmem_stride0(16b), dram_stride0(16b), bound0(16b)>
                      DMA_LOAD(eff_groups_per_tile_next * nt_eff_next * (sizeof(_Float16)) * 2);  // <seg_size(32b)>
                    } else {
                      DMA_LOAD(scale_tmem_1, scale_tile_dram_next, 1); // <Tmem_base_addr(24b), dram_base_address(36b), 1(opcode, 4bit)>
                      DMA_LOAD(0, 0, 1);  // <tmem_stride0(16b), dram_stride0(16b), bound0(16b)>
                      DMA_LOAD(eff_groups_per_tile_next * kt_eff_next * (sizeof(_Float16)) * 2);  // <seg_size(32b)>
                    }
                }
                
                // GEMM DMA tile 
                const int nt_mxu_dim  = CEIL(nt_eff, (MXU_NT));
                const int kt_mxu_dim  = kt_eff / MXU_KT;  //KT안에 MXU_KT가 몇 개 들어있는지
                const int mxu_ld_strd = 0;
                const int mxu_ld_bnd  = 1;

                bool buf_idx = 0;
                int mxu_tile_per_quant_blk;
                if(quant_direction == QDIR_COL){
                    mxu_tile_per_quant_blk = quant_blk_size / MXU_KT;  //KT가 아니라 quant_blk_size 기준, 보통 quant_blk_size가 MXU_KT랑 같아서 1
                } else { // QDIR_ROW
                    mxu_tile_per_quant_blk = quant_blk_size / MXU_NT;
                } 

                uint32_t sz_group_num_in_tile;
                if(quant_direction == QDIR_COL){
                    sz_group_num_in_tile = CEIL(KT, quant_blk_size);
                } else {
                    sz_group_num_in_tile = CEIL(NT, quant_blk_size);
                }
                uint32_t sz_group_num_in_mxu_tile;  //MXU_KT 길이가 quant_blk_size 길이짜리 group 몇 개를 덮느냐
                if(quant_direction == QDIR_COL){
                    sz_group_num_in_mxu_tile = CEIL(MXU_KT, quant_blk_size);  //quant_blk_size 가 MXU_KT 보다 크거나 같음, 따라서 항상 1
                } else {
                    sz_group_num_in_mxu_tile = CEIL(MXU_NT, quant_blk_size);
                }

                // initial load for double buffering in MXU tile level
                MXU_LOAD_WEIGHT(weight_transposed, buf_idx, 0, 0, weight_tmem_0, 5);  //<wtrans(1b), reg_idx(1b), bound(17b), stride(17b), tmem_base_address(24b), 5(opcode, 4bit)>
                //segsize는 MXU_KT x MXU_NT/2

                if(quant_direction == QDIR_COL) {
                  MXU_LOAD_QPARAM(buf_idx, scale_tmem_0, 6);  //<reg_idx(1b), tmem_base_addr(20b), 6(opcode, 4bit)>
                  MXU_LOAD_QPARAM(kt_eff/quant_blk_size * NT, 2*MXU_NT*sizeof(_Float16), 2);  //<tmem_stride0(16b), mxu_stride0(16b), bound0(16b)>
                  //segsize는 hardware 적으로 고정됨. (1 * MXU_NT) 이거 2번
                }
                else { //여기!!
                  MXU_LOAD_QPARAM(buf_idx, scale_tmem_0, 6);  //<reg_idx(1b), tmem_base_addr(20b), 6(opcode, 4bit)>
                  MXU_LOAD_QPARAM(nt_eff/quant_blk_size * KT, 2*MXU_KT*sizeof(_Float16), 2);  //<tmem_stride0(16b), mxu_stride0(16b), bound0(16b)>
                  //segsize는 hardware 적으로 고정됨. (1 * MXU_NT) 이거 2번
                }                

                for(int kt_mxu = 0; kt_mxu < kt_mxu_dim; kt_mxu++){
                    int kt_mxu_sz_id = kt_mxu / mxu_tile_per_quant_blk;  // 이거 안 씀
                    int global_k = kt * KT + kt_mxu * MXU_KT;
                    for(int nt_mxu = 0; nt_mxu < nt_mxu_dim; nt_mxu++){

                        int nnt_mxu = (nt_mxu + 1 == nt_mxu_dim) ? 0 : nt_mxu + 1;
                        int nkt_mxu = (nt_mxu + 1 == nt_mxu_dim) ? kt_mxu + 1 : kt_mxu;  // next
                        
                        if(nkt_mxu != kt_mxu_dim){
                            // Preload next MXU tile if not the last tile  // 더블 버퍼용
                            int nbuf_idx = buf_idx ^ 1; //다음 로드는 반대편 버퍼로
                            uint32_t weight_mxu_tile_idx;  //다음 weight mxu 타일의 인덱스
                            if(weight_transposed) {
                              weight_mxu_tile_idx = (nkt_mxu + nnt_mxu * CEIL(KT,MXU_KT));
                            } else {
                              weight_mxu_tile_idx = (nnt_mxu + nkt_mxu * CEIL(NT,MXU_NT));
                            }
                            uint64_t weight_mxu_tile_tmem_next = weight_tmem_0 + weight_mxu_tile_idx * (MXU_KT*(MXU_NT/2)*sizeof(int8_t));

                            int nkt_mxu_sz_id = nkt_mxu / mxu_tile_per_quant_blk;  // 이거 안 씀  
                            uint32_t sz_mxu_tile_idx;
                            if(quant_direction == QDIR_COL){
                              sz_mxu_tile_idx = (nnt_mxu + nkt_mxu * CEIL(NT,MXU_NT));
                            } else { // QDIR_ROW                      
                              sz_mxu_tile_idx = (nkt_mxu + nnt_mxu * CEIL(KT,MXU_KT));
                            }
                            uint64_t scale_mxu_tile_tmem_next = scale_tmem_0;
                            uint64_t zp_mxu_tile_tmem_next    = zp_tmem_0; 
                            scale_mxu_tile_tmem_next += (quant_direction == QDIR_COL) ? sz_mxu_tile_idx * (sz_group_num_in_mxu_tile*MXU_NT*sizeof(float))
                                                                                        : sz_mxu_tile_idx * (sz_group_num_in_mxu_tile*MXU_KT*sizeof(float));
                            zp_mxu_tile_tmem_next    += (quant_direction == QDIR_COL) ? sz_mxu_tile_idx * (sz_group_num_in_mxu_tile*MXU_NT*sizeof(int16_t))
                                                                                        : sz_mxu_tile_idx * (sz_group_num_in_mxu_tile*MXU_KT*sizeof(int16_t));

                            MXU_LOAD_WEIGHT(weight_transposed, nbuf_idx, 0, 0, weight_mxu_tile_tmem_next, 5);  //<wtrans(1b), reg_idx(1b), bound(17b), stride(17b), tmem_base_address(24b), 5(opcode, 4bit)>
                            //segsize는 MXU_KT x MXU_NT/2
                            
                            if(quant_direction == QDIR_COL) {
                              MXU_LOAD_QPARAM(nbuf_idx, scale_mxu_tile_tmem_next, 6);  //<reg_idx(1b), tmem_base_addr(20b), 6(opcode, 4bit)>
                              MXU_LOAD_QPARAM(kt_eff/quant_blk_size * NT, 2*MXU_NT*sizeof(_Float16), 2);  //<tmem_stride0(16b), mxu_stride0(16b), bound0(16b)>
                              //segsize는 hardware 적으로 고정됨. (1 * MXU_NT) 이거 2번
                            }
                            else { //여기!!
                              MXU_LOAD_QPARAM(nbuf_idx, scale_mxu_tile_tmem_next, 6);  //<reg_idx(1b), tmem_base_addr(20b), 6(opcode, 4bit)>
                              MXU_LOAD_QPARAM(nt_eff/quant_blk_size * KT, 2*MXU_KT*sizeof(_Float16), 2);  //<tmem_stride0(16b), mxu_stride0(16b), bound0(16b)>
                              //segsize는 hardware 적으로 고정됨. (1 * MXU_KT) 이거 2번
                            } 
                        }

                        uint64_t input_mxu_tile_tmem = input_tmem_0 + (kt_mxu * (mt_eff*MXU_KT) * sizeof(_Float16));
                        uint64_t accum_mxu_tile_shared = accum_base + (nt_mxu * (mt_eff*MXU_NT) * sizeof(float));
                        uint64_t output_mxu_tile_tmem = output_tmem_0 + (nt_mxu * (mt_eff*MXU_NT) * sizeof(_Float16));

                        // Because MXU_KT == quant_blk_size, we always have to scale after gemm
                        bool is_accum = (global_k != 0);
                        bool is_last = (global_k + MXU_KT >= K); 
                        int idx_set = (buf_idx << 2) | (buf_idx << 1) | buf_idx;  //3비트 모두를 buf_idx로 설정                         
                        
                        MXU_LOAD_INPUT(is_accum, is_last, idx_set, quant_direction, input_mxu_tile_tmem, accum_mxu_tile_shared, 7);  //<is_accum(1b), is_last(1b), wreg_idx(1b), sreg_idx(1b), zreg_idx(1b), qdir(1b), tmem_base_addr(20b), acc_mem_base_addr(20b), 7(opcode, 4bit)>
                        MXU_LOAD_INPUT(0, 1);  //<stride(20b), bound(20b)>

                        // Conversion to fp16 은 accum_mem -> tmem 일 때 바로 됨
                        if(is_last){
                          MXU_STORE_OUTPUT(output_mxu_tile_tmem, accum_mxu_tile_shared, 8);  //<tmem_base_addr(20b), acc_mem_base_addr(20b), 8(opcode, 4bit)>
                          MXU_STORE_OUTPUT(0, 1);  //<stride(20b), bound(20b)>
                        }

                        // swap buffers
                        buf_idx ^= 1;
                    }
                }

                // Swap shared memory buffers for the next DMA tile preload.
                uint64_t temp = input_tmem_0;
                input_tmem_0 = input_tmem_1;
                input_tmem_1 = temp;

                temp = weight_tmem_0;
                weight_tmem_0 = weight_tmem_1;
                weight_tmem_1 = temp;

                temp = scale_tmem_0;
                scale_tmem_0 = scale_tmem_1;
                scale_tmem_1 = temp;

                temp = zp_tmem_0;
                zp_tmem_0 = zp_tmem_1;
                zp_tmem_1 = temp;
            }
            // Store output
            if((nt==(nt_dim-1)) && (mt==(mt_dim-1))) SET_SYNC(1);

            uint64_t output_tile_dram = output_dram + (mt*nt_dim + nt) * MT*NT*sizeof(_Float16);

            DMA_STORE(output_tmem_0, output_tile_dram, 2);  //<Tmem_base_addr(24b), dram_base_address(36b), 2(opcode, 4bit)>
            DMA_STORE(MT * MXU_NT * sizeof(_Float16), mt_eff * MXU_NT * sizeof(_Float16), nt_eff/MXU_NT);  // <tmem_stride0(16b), dram_stride0(16b), bound0(16b)>
            DMA_STORE(mt_eff * nt_eff * (sizeof(_Float16)));  // <seg_size(32b)>

            // Output buffers ping-pong per output tile.
            uint64_t output_tmem_temp = output_tmem_0;
            output_tmem_0 = output_tmem_1;
            output_tmem_1 = output_tmem_temp;
        }
    }
    WAIT_SYNC(1);
}


// Wrapper function for the GEMM kernel
void fi_fpint_gemm_fp16_tile_layout_general(
  _Float16 *input, int8_t *weight, _Float16 *output, _Float16 *scale, int8_t *zp, _Float16 *bias, 
  int is_bias, int M, int N, int K, int quant_blk_size,
  uint8_t quant_direction, uint8_t weight_transposed) {

    if(KT % MXU_KT != 0 || NT % MXU_NT != 0){
        printf("Error: KT %d or NT %d is not divisible by MXU_KT %d or MXU_NT %d\n", KT, NT, MXU_KT, MXU_NT);
        return;
    }

    if(N % 2 != 0){
        printf("Error: N %d is not divisible by 2\n", N);
        return;
    }

    if(quant_blk_size % MXU_KT != 0){
        printf("Error: quant_blk_size %d is not divisible by MXU_KT %d\n", quant_blk_size, MXU_KT);
        return;
    }

    if(quant_direction == QDIR_COL) {
      if(K % quant_blk_size != 0){
          printf("Error: K %d is not divisible by quant_blk_size %d\n", K, quant_blk_size);
          return;
      }
      if(quant_blk_size > KT){
          printf("Error: quant_blk_size %d is greater than KT %d\n", quant_blk_size, KT);
          return;
      }
      if(KT % quant_blk_size != 0){
          printf("Error: KT %d is not divisible by quant_blk_size %d\n", KT, quant_blk_size);
          return;
      }
    } else {
      if(quant_blk_size != N) {
          printf("Error: For quant_direction ROW, quant_blk_size %d must be equal to N %d\n", quant_blk_size, N);
          return;
      }
    }

    if(MT*KT*sizeof(_Float16) > GMEM_SIZE) {
        printf("Error: MT x KT x sizeof(_Float16) = %d exceeds GMEM_SIZE %d\n", MT*KT*sizeof(_Float16), GMEM_SIZE);
        return;
    }
    if((KT*NT)/2*sizeof(int8_t) > GMEM_SIZE) {
        printf("Error: KT x NT / 2 x sizeof(int8_t) = %d exceeds GMEM_SIZE %d\n", (KT*NT)/2*sizeof(int8_t), GMEM_SIZE);
        return;
    }
    if(MT*NT*sizeof(_Float16) > GMEM_SIZE) {
        printf("Error: MT x NT x sizeof(_Float16) = %d exceeds GMEM_SIZE %d\n", MT*NT*sizeof(_Float16), GMEM_SIZE);
        return;
    }
    if(( (KT/quant_blk_size)*NT*sizeof(_Float16) + (KT/quant_blk_size)*NT*sizeof(int8_t) ) > GMEM_SIZE) {
        printf("Error: (KT / quant_blk_size) x NT x (sizeof(_Float16) + sizeof(int8_t)) = %d exceeds GMEM_SIZE %d\n", ( (KT/quant_blk_size)*NT*sizeof(_Float16) + (KT/quant_blk_size)*NT*sizeof(int8_t) ), GMEM_SIZE);
        return;
    }

    fi_fpint_gemm_tile_layout_general(input, weight, output, scale, zp, bias, is_bias, M, N, K, quant_blk_size, quant_direction, weight_transposed);
}
