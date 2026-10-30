// Resident integration scenarios; included after reference arrays and helpers.
logic [31:0] fusion_ref_fp32[fpint_emul::MAX_M*fpint_emul::MAX_N];
int unified_dma_to_tmem, unified_dma_from_tmem;

// Count accepted commands, independently of the software copy accounting.
always @(posedge clk) begin
    if (reset) begin
        unified_dma_to_tmem <= 0;
        unified_dma_from_tmem <= 0;
    end else if (u_dut.fusion_cmd_valid && u_dut.fusion_cmd_ready) begin
        if (u_dut.fusion_cmd_direction)
            unified_dma_to_tmem <= unified_dma_to_tmem + 1;
        else
            unified_dma_from_tmem <= unified_dma_from_tmem + 1;
    end
end

// Exact dyadic inputs keep this arithmetic oracle independent of FP16 export
// and reduction order. Every row and each 8-column half has a distinct pattern.
task automatic fusion_build_fp32_vectors(input int rows, input int columns,
    input int depth, input int qblk, input int wtrans, input int qdir,
    input int iteration);
    int groups;
    shortreal input_value, scale_value, product, accumulator;
    build_test_vectors(rows,columns,depth,qblk,wtrans,qdir,0,0,0,3);
    for (int row = 0; row < rows; ++row)
        for (int kk = 0; kk < depth; ++kk) begin
            input_mat[row*depth+kk] = fp32_to_fp16_rne(
                shortreal'(512 + row*16 + (kk%4)*2 + iteration*32));
            ref_input[row*depth+kk] = input_mat[row*depth+kk];
        end
    for (int kk = 0; kk < depth; ++kk)
        for (int col = 0; col < columns; ++col) begin
            int weight_value;
            weight_value = (1 + col%7) * ((col/16)%2 == 0 ? 1 : -1);
            weight_mat[kk*columns+col] = 4'(weight_value);
            ref_weight[kk*columns+col] = $signed(4'(weight_value));
        end
    groups = qdir ? columns/qblk : depth/qblk;
    for (int q = 0; q < (qdir ? depth*groups : groups*columns); ++q) begin
        int column_group;
        column_group = qdir ? q%groups : (q%columns)/8;
        ref_scale[q] = fp32_to_fp16_rne(shortreal'(1.0 + 0.125*column_group));
        ref_zero[q] = 0;
    end
    for (int row = 0; row < rows; ++row)
        for (int col = 0; col < columns; ++col) begin
            accumulator = 0;
            for (int kk = 0; kk < depth; ++kk) begin
                int qindex;
                qindex = qdir ? kk*groups + col/qblk : (kk/qblk)*columns + col;
                input_value = cf_math_util_pkg::fp16_bit_to_fp16_val(ref_input[row*depth+kk]);
                scale_value = cf_math_util_pkg::fp16_bit_to_fp16_val(ref_scale[qindex]);
                if (qdir)
                    input_value = cf_math_util_pkg::fp16_bit_to_fp16_val(
                        fp32_to_fp16_rne(input_value * scale_value));
                product = input_value * shortreal'($signed(ref_weight[kk*columns+col]));
                if (!qdir) product = product * scale_value;
                accumulator += product;
            end
            fusion_ref_fp32[row*columns+col] = $shortrealtobits(accumulator);
        end
endtask

task automatic fusion_check_fp32(input int rows, input int physical_rows,
                                 input int columns);
    int offset, above_half_range;
    logic [31:0] actual, expected;
    shortreal actual_value;
    above_half_range = 0;
    for (int row = 0; row < physical_rows; ++row)
        for (int col = 0; col < columns; ++col) begin
            offset = 4*((col/DMA_MXU_NT)*physical_rows*DMA_MXU_NT
                       + row*DMA_MXU_NT + col%DMA_MXU_NT);
            actual = {fusion_lmem[offset+3], fusion_lmem[offset+2],
                      fusion_lmem[offset+1], fusion_lmem[offset]};
            expected = row < rows ? fusion_ref_fp32[row*columns+col] : 0;
            assert (!$isunknown(actual) && actual[30:23] != 8'hff && actual == expected)
                else $fatal(1,"FP32 output mismatch row=%0d col=%0d actual=%h expected=%h",
                            row,col,actual,expected);
            actual_value = $bitstoshortreal(actual);
            if (actual_value > 65504.0) ++above_half_range;
        end
    assert (above_half_range != 0)
        else $fatal(1,"FP32 vectors did not cover a finite value beyond FP16 range");
    $display("FP32_ARITHMETIC_CHECK PASSED positive_values_above_65504=%0d",above_half_range);
endtask

task automatic fusion_check_output(input int logical_m, input int physical_m,
                                    input int columns, input int local_offset);
    int offset;
    logic [15:0] actual, expected;
    for (int row = 0; row < physical_m; ++row) begin
        for (int col = 0; col < columns; ++col) begin
            offset = local_offset + 2*((col / DMA_MXU_NT)*physical_m*DMA_MXU_NT
                     + row*DMA_MXU_NT + col % DMA_MXU_NT);
            actual = {fusion_lmem[offset+1], fusion_lmem[offset]};
            if (row < logical_m) begin
                expected = ref_output[row*columns+col];
                assert (!$isunknown(actual)
                        && actual[14:10] != 5'h1f
                        && compare_fp16(actual, expected, FP16_TOL))
                    else $fatal(1, "Resident output mismatch row=%0d col=%0d actual=%h expected=%h",
                                row, col, actual, expected);
            end else begin
                assert (actual == 0)
                    else $fatal(1, "Resident inactive row padding modified row=%0d col=%0d", row, col);
            end
        end
    end
endtask


// Observe ordinary descriptor completion, including the final physical LMEM
// commit. Error status must survive completion until descriptor reallocation.
task automatic unified_wait(input int eid, input int expected_error);
    logic [31:0] ctrl, error, progress;
    int polls;
    polls = 0;
    do begin
        job_read_reg32(eid, REG_CONTROL, ctrl);
        if (++polls > 100000) $fatal(1,"Unified GEMM timeout entry=%0d",eid);
    end while (ctrl[`JOB_MMIO_CTRL_VALID_BIT]);
    job_read_reg32(eid,45,error);
    assert (error == 32'(expected_error))
        else $fatal(1,"Unified error=%0d expected=%0d",error,expected_error);
    job_read_reg32(eid,REG_OUTPUT_PROGRESS,progress);
    assert (progress == 0) else $fatal(1,"SRAM job incremented HBM progress");
    assert (!fusion_mem_pending && !fusion_lmem_commit)
        else $fatal(1,"Descriptor completed before physical LMEM commit");
endtask

task automatic unified_copy(input bit to_tmem, input logic [63:0] tmem,
                            input int offset, input int bytes);
    int unsigned eid, generation;
    int reads_before, writes_before, to_tmem_before, from_tmem_before;
    reads_before = fusion_count(0);
    writes_before = fusion_count(1);
    to_tmem_before = unified_dma_to_tmem;
    from_tmem_before = unified_dma_from_tmem;
    job_alloc(eid,generation);
    job_write_reg64(eid,to_tmem ? REG_INPUT_BASE_LO : REG_OUTPUT_BASE_LO,
                    64'(`LMEM_BASE_ADDR)+64'(offset));
    job_write_reg64(eid,to_tmem ? REG_LMEM_IBUF0_LO : REG_LMEM_OBUF_LO,tmem);
    job_write_reg32(eid,REG_M_ORIG,32'(bytes));
    job_write_reg32(eid,44,to_tmem ? 32'h20 : 32'h40);
    job_write_reg32(eid,REG_CONTROL,1);
    unified_wait(eid,0);
    assert (fusion_count(0) == reads_before && fusion_count(1) == writes_before)
        else $fatal(1,"Copy-only descriptor issued HBM traffic");
    assert (unified_dma_to_tmem == to_tmem_before + int'(to_tmem)
         && unified_dma_from_tmem == from_tmem_before + int'(!to_tmem))
        else $fatal(1,"Copy-only descriptor issued unexpected DMA commands");
endtask

task automatic unified_check_publish();
    logic [31:0] value;
    bit completed;
    completed = 0;
    fusion_lmem_published = 0;
    fork
        begin
            mmio_read32_word(GEMM_BASE+64'h3f0,0,value);
            completed = 1;
        end
        begin
            repeat (80) @(negedge clk);
            assert (!completed) else $fatal(1,"Publication completed before LMEM stores");
            fusion_lmem_published = 1;
        end
    join
    assert (value == 1) else $fatal(1,"Publication result=%h",value);
endtask

task automatic run_sram_unified(input int logical_m, input int n, input int k,
                               input int qblk, input int wtrans, input int qdir);
    int physical_m, input_bytes, output_bytes, writes_before, reads_before;
    int input_before, commits_before, to_tmem_before, from_tmem_before;
    int unsigned eid, generation;
    logic [31:0] value, flags;
    logic [63:0] di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out,source;
    bit fp32_test, fp32_iteration;
    physical_m = align8_int(logical_m);
    fp32_test = $test$plusargs("SRAM_FP32");
    assert (logical_m > 0 && physical_m <= 128 && n == 128 && k == 128)
        else $fatal(1,"SRAM_UNIFIED requires M=1..128,N=K=128");
    if (fp32_test) fusion_acc_check_stall();
    compute_auto_layout(physical_m,n,k,qblk,wtrans,qdir,
        di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out);
    input_bytes = physical_m*k*2;
    run_config_gemm_tiled("LEGACY_BEFORE_UNIFIED",physical_m,n,k,qblk,wtrans,qdir,
        di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out);
    writes_before = fusion_count(1);
    fusion_watch_input = di;
    fusion_watch_output = dout;
    fusion_watch_input_bytes = input_bytes;
    fusion_watch_output_bytes = physical_m*n*4;
    mmio_read32_word(GEMM_BASE+64'h3f8,0,value);
    assert (value == 32'h53465203) else $fatal(1,"Unified capability=%h",value);
    unified_check_publish();

    // Copy-only opcodes exercise the same descriptor bus and final commit.
    for (int b=0;b<1024;++b) fusion_lmem[65536+b] = 8'(b ^ (b >> 3));
    unified_copy(1,i0,65536,1024);
    unified_copy(0,i0,69632,1024);
    for (int b=0;b<1024;++b)
        assert (fusion_lmem[69632+b] == 8'(b ^ (b >> 3)))
            else $fatal(1,"Unified copy roundtrip mismatch byte=%0d",b);

    // HBM input, implicit LMEM input copy, TMEM reuse, then FP16 after FP32.
    for (int iteration=0;iteration<(fp32_test ? 4 : 3);++iteration) begin
        fp32_iteration = fp32_test && iteration < 3;
        if (iteration != 2) begin
            if (fp32_iteration)
                fusion_build_fp32_vectors(physical_m,n,k,qblk,wtrans,qdir,iteration);
            else
                build_test_vectors(physical_m,n,k,qblk,wtrans,qdir,1,3,3,3);
            write_dram_tiled_input(physical_m,k,di);
            write_dram_tiled_weight(n,k,wtrans,dw);
            write_dram_tiled_scale(n,k,qblk,qdir,ds);
            write_dram_tiled_zp(n,k,qblk,qdir,dz);
        end
        output_bytes = physical_m*n*(fp32_iteration ? 4 : 2);
        // Initialize OBUF once for three consecutive jobs, including padding.
        // A format switch changes the physical padding offsets, so explicitly
        // initialize the new FP16 layout before that separate mode-switch test.
        if (iteration == 0 || (fp32_test && iteration == 3)) begin
            for (int b=0;b<output_bytes;++b) fusion_lmem[b] = 0;
            unified_copy(1,out,0,output_bytes);
        end
        // Old LMEM output is not an input. An accidental output prefill would
        // copy these nonzero bytes into the otherwise initialized TMEM padding.
        for (int b=0;b<output_bytes;++b) fusion_lmem[b] = 8'('ha5 + iteration);
        if (iteration == 1) begin
            for (int b=0;b<input_bytes;++b) begin
                fusion_lmem[65536+b] = dram[di+b];
                dram[di+b] = 0;
            end
        end
        flags = 32'h8 | (fp32_iteration ? 32'h10 : 0)
              | (iteration == 1 ? 2 : (iteration == 2 ? 1 : 0));
        source = iteration == 1 ? 64'(`LMEM_BASE_ADDR)+64'd65536 : di;
        input_before = fusion_count(2);
        to_tmem_before = unified_dma_to_tmem;
        from_tmem_before = unified_dma_from_tmem;
        job_alloc(eid,generation);
        job_write_reg32(eid,44,flags);
        program_job_regs(eid,physical_m,n,k,qblk,wtrans,qdir,logical_m,n,0,0,
            source,dw,64'(`LMEM_BASE_ADDR),ds,dz,i0,i1,w0,w1,s0,s1,z0,z1,out);
        unified_wait(eid,0);
        assert (unified_dma_to_tmem == to_tmem_before + (iteration == 1 ? 1 : 0)
             && unified_dma_from_tmem == from_tmem_before + 1)
            else $fatal(1,"Unexpected GEMM DMA commands iteration=%0d to_tmem=%0d from_tmem=%0d",
                iteration,unified_dma_to_tmem-to_tmem_before,
                unified_dma_from_tmem-from_tmem_before);
        assert (fusion_count(1) == writes_before && fusion_count(3) == 0)
            else $fatal(1,"Unified SRAM GEMM emitted HBM output traffic");
        if (iteration == 1 || iteration == 2)
            assert (fusion_count(2) == input_before)
                else $fatal(1,"LMEM/TMEM input was reloaded from HBM");
        else
            assert (fusion_count(2) > input_before)
                else $fatal(1,"HBM input load not observed");
        if (fp32_iteration) fusion_check_fp32(logical_m,physical_m,n);
        else fusion_check_output(logical_m,physical_m,n,0);
        $display("UNIFIED_OUTPUT_CHECK PASSED iteration=%0d M=%0d fp32=%0d",iteration,logical_m,fp32_iteration);
        $display("UNIFIED_NO_OUTPUT_PREFILL PASSED iteration=%0d to_tmem=%0d from_tmem=%0d",
            iteration,unified_dma_to_tmem-to_tmem_before,
            unified_dma_from_tmem-from_tmem_before);
    end
    for (int reject_case=0;reject_case<3;++reject_case) begin
        reads_before = fusion_count(0);
        commits_before = fusion_mem_commits;
        to_tmem_before = unified_dma_to_tmem;
        from_tmem_before = unified_dma_from_tmem;
        job_alloc(eid,generation);
        job_write_reg32(eid,44,reject_case == 1 ? 32'h88 : 32'h8);
        program_job_regs(eid,reject_case == 0 ? 256 : physical_m,n,k,qblk,wtrans,qdir,
            logical_m,n,0,0,di,dw,64'(`LMEM_BASE_ADDR)+(reject_case == 2 ? 1 : 0),
            ds,dz,i0,i1,w0,w1,s0,s1,z0,z1,out);
        unified_wait(eid,reject_case+1);
        assert (fusion_count(0) == reads_before && fusion_count(1) == writes_before
                && fusion_mem_commits == commits_before
                && unified_dma_to_tmem == to_tmem_before
                && unified_dma_from_tmem == from_tmem_before)
            else $fatal(1,"Invalid descriptor issued memory traffic");
    end
    run_config_gemm_tiled("LEGACY_AFTER_UNIFIED",physical_m,n,k,qblk,wtrans,qdir,
        di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out);
    $display("UNIFIED_NO_HBM_INTERMEDIATES PASSED delayed_lmem_commits=%0d",fusion_mem_commits);
endtask
