// Resident integration scenarios; included after reference arrays and helpers.
logic [31:0] fusion_ref_fp32[fpint_emul::MAX_M*fpint_emul::MAX_N];

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

task automatic fusion_mmio(input bit write, input int offset,
                            input logic [31:0] value,
                            output logic [31:0] result);
    int timeout, word_index;
    logic [63:0] address;
    address = 64'(`DMA_REG_BASE_ADDR) + offset;
    word_index = int'((address >> 2) & 1);
    @(negedge clk);
    fusion_mmio_if[0].req_data = '0;
    fusion_mmio_if[0].req_data.rw = write;
    fusion_mmio_if[0].req_data.mask[0] = 1;
    fusion_mmio_if[0].req_data.addr[0] = address >> $clog2(LSU_WORD_SIZE);
    fusion_mmio_if[0].req_data.data[0][word_index*32 +: 32] = value;
    fusion_mmio_if[0].req_data.byteen[0][word_index*4 +: 4] = 4'hf;
    fusion_mmio_if[0].req_data.tag = fusion_mmio_tag;
    fusion_mmio_tag++;
    fusion_mmio_if[0].req_valid = 1;
    timeout = 0;
    do begin
        @(posedge clk);
        if (++timeout > 10000) $fatal(1, "Fusion MMIO request timed out");
    end while (!fusion_mmio_if[0].req_ready);
    @(negedge clk);
    fusion_mmio_if[0].req_valid = 0;
    result = 0;
    if (!write) begin
        timeout = 0;
        while (!fusion_mmio_if[0].rsp_valid) begin
            @(negedge clk);
            if (++timeout > 10000) $fatal(1, "Fusion MMIO read timed out");
        end
        result = fusion_mmio_if[0].rsp_data.data[0][word_index*32 +: 32];
        @(negedge clk);
    end
endtask

task automatic fusion_write(input int offset, input logic [31:0] value);
    logic [31:0] ignored;
    fusion_mmio(1, offset, value, ignored);
endtask

task automatic fusion_read(input int offset, output logic [31:0] result);
    fusion_mmio(0, offset, 0, result);
endtask

task automatic fusion_arm(input int eid, input int generation, input int flags);
    logic [31:0] status, read_generation;
    fusion_write(32'h104 + 16*eid, 32'(generation));
    fusion_write(32'h100 + 16*eid, 32'(flags));
    // Drain the independent posted sidecar route before the GEMM doorbell.
    fusion_read(32'h108 + 16*eid, status);
    fusion_read(32'h104 + 16*eid, read_generation);
    assert (status[0] == (flags != 0) && read_generation == 32'(generation))
        else $fatal(1, "Resident arm readback failed: status=%h generation=%h", status, read_generation);
endtask

task automatic fusion_check_publish;
    logic [31:0] published;
    bit read_finished;
    read_finished = 0;
    @(negedge clk);
    fusion_lmem_published = 0;
    fork
        begin
            fusion_read('h2c, published);
            read_finished = 1;
        end
        begin
            repeat (30) @(negedge clk);
            assert (!read_finished)
                else $fatal(1, "LMEM publish read completed before prior stores drained");
            fusion_lmem_published = 1;
        end
    join
    assert (published == 1) else $fatal(1, "LMEM publish read returned %h", published);
endtask

task automatic fusion_wait_job(input int eid, input int generation,
                                input int expected_error);
    logic [31:0] status, completed, progress;
    int timeout;
    timeout = 0;
    do begin
        fusion_read(32'h108 + 16*eid, status);
        fusion_read(32'h10c + 16*eid, completed);
        if (++timeout > 100000) $fatal(1, "Resident job completion timed out");
    end while (!(status[2] && completed == 32'(generation)));
    assert (status[3] == (expected_error != 0)
            && status[31:16] == 16'(expected_error))
        else $fatal(1, "Resident status=%h expected error=%0d", status, expected_error);
    job_read_reg32(eid, REG_OUTPUT_PROGRESS, progress);
    assert (progress == 0) else $fatal(1, "Resident job changed HBM output progress");
endtask

task automatic fusion_copy(input bit to_tmem, input logic [63:0] tmem_address,
                            input int local_offset, input int bytes);
    logic [63:0] local_address;
    logic [31:0] status, done_sequence, error;
    int timeout, reads_before, writes_before;
    reads_before = fusion_count(0);
    writes_before = fusion_count(1);
    local_address = 64'(`LMEM_BASE_ADDR) + local_offset;
    ++fusion_sequence;
    fusion_write('h10, tmem_address[31:0]);
    fusion_write('h14, tmem_address[63:32]);
    fusion_write('h18, local_address[31:0]);
    fusion_write('h1c, local_address[63:32]);
    fusion_write('h20, 32'(bytes));
    fusion_write('h0c, fusion_sequence);
    fusion_write('h08, to_tmem ? 3 : 1);
    timeout = 0;
    do begin
        fusion_read('h28, error);
        assert (error == 0) else $fatal(1, "Fusion copy error=%0d", error);
        fusion_read('h04, status);
        fusion_read('h24, done_sequence);
        if (++timeout > 100000) $fatal(1, "Fusion copy timed out");
    end while ((status & 3) != 2 || done_sequence != fusion_sequence);
    assert (!fusion_mem_pending && !fusion_lmem_commit)
        else $fatal(1, "Fusion copy completed before LMEM drain");
    assert (fusion_count(0) == reads_before && fusion_count(1) == writes_before)
        else $fatal(1, "SRAM DMA generated HBM traffic");
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

task automatic run_sram_resident(input int logical_m, input int n, input int k,
                                  input int qblk, input int wtrans, input int qdir);
    int physical_m, input_bytes, output_bytes, ar_before, input_before;
    int legacy_writes;
    bit fp32_test, fp32_iteration;
    int unsigned eid, generation;
    logic [31:0] value;
    logic [63:0] di, dw, ds, dz, dout, i0, i1, w0, w1, s0, s1, z0, z1, out;
    physical_m = align8_int(logical_m);
    fp32_test = $test$plusargs("SRAM_FP32");
    assert (logical_m > 0 && physical_m <= 128 && n == 128 && k == 128)
        else $fatal(1, "SRAM_RESIDENT requires M=1..128,N=K=128");
    if (fp32_test) fusion_acc_check_stall();
    compute_auto_layout(physical_m,n,k,qblk,wtrans,qdir,
        di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out);
    input_bytes = physical_m*k*2;
    output_bytes = physical_m*n*(fp32_test ? 4 : 2);
    run_config_gemm_tiled("LEGACY_BEFORE_RESIDENT",physical_m,n,k,qblk,wtrans,qdir,
        di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out);
    legacy_writes = fusion_count(1);
    for (int entry = 0; entry < 4; ++entry) begin
        fusion_read('h108 + 16*entry, value);
        assert (value[2:0] == 0)
            else $fatal(1, "Disarmed legacy descriptor changed sidecar status=%h", value);
    end
    fusion_watch_input = di;
    fusion_watch_output = dout;
    fusion_watch_input_bytes = input_bytes;
    fusion_watch_output_bytes = output_bytes;
    fusion_read('h00, value);
    assert (value == 32'h53465202) else $fatal(1, "Wrong SRAM fusion capability=%h", value);
    fusion_check_publish();

    // Initialize complete owned output, including inactive physical rows.
    for (int b = 0; b < output_bytes; ++b) fusion_lmem[b] = 0;
    fusion_copy(1, out, 0, output_bytes);
    for (int iteration = 0; iteration < (fp32_test ? 3 : 2); ++iteration) begin
        fp32_iteration = fp32_test && iteration < 2;
        if (fp32_iteration)
            fusion_build_fp32_vectors(physical_m,n,k,qblk,wtrans,qdir,iteration);
        else
            build_test_vectors(physical_m,n,k,qblk,wtrans,qdir,
                               iteration == 0 ? 3 : 1, 3, 3, 3);
        if (fp32_test && iteration == 2) begin
            output_bytes = physical_m*n*2;
            for (int b = 0; b < output_bytes; ++b) fusion_lmem[b] = 0;
            fusion_copy(1,out,0,output_bytes);
        end
        write_dram_tiled_input(physical_m,k,di);
        write_dram_tiled_weight(n,k,wtrans,dw);
        write_dram_tiled_scale(n,k,qblk,qdir,ds);
        write_dram_tiled_zp(n,k,qblk,qdir,dz);
        if (iteration == 1) begin
            for (int b = 0; b < input_bytes; ++b) begin
                fusion_lmem[65536+b] = dram[di+b];
                dram[di+b] = 0; // An accidental HBM reload produces the wrong answer.
            end
            fusion_copy(1, i0, 65536, input_bytes);
        end
        input_before = fusion_count(2);
        job_alloc(eid,generation);
        fusion_arm(eid,generation,0);
        fusion_read('h108 + 16*eid,value);
        assert (!value[0]) else $fatal(1, "Writing zero flags did not disarm sidecar");
        if (fp32_test && iteration < 2) begin
            ar_before = fusion_count(0);
            fusion_write('h100 + 16*eid,32'(4+iteration));
            fusion_read('h108 + 16*eid,value);
            assert (!value[0] && value[31:16] == 5)
                else $fatal(1,"Invalid FP32 flags were not rejected status=%h",value);
            fusion_read('h100 + 16*eid,value);
            assert (value == 0 && fusion_count(0) == ar_before
                    && fusion_count(1) == legacy_writes)
                else $fatal(1,"Invalid FP32 flags changed mode or emitted HBM traffic");
        end
        fusion_arm(eid,generation,(iteration == 1 ? 3 : 2) | (fp32_iteration ? 4 : 0));
        program_job_regs(eid,physical_m,n,k,qblk,wtrans,qdir,
            logical_m,n,0,0,di,dw,dout,ds,dz,i0,i1,w0,w1,s0,s1,z0,z1,out);
        fusion_wait_job(eid,generation,0);
        assert (fusion_count(1) == legacy_writes && fusion_count(3) == 0)
            else $fatal(1, "Resident GEMM emitted HBM output store/preservation read");
        if (iteration == 1)
            assert (fusion_count(2) == input_before)
                else $fatal(1, "Resident A was reloaded from HBM");
        else
            assert (fusion_count(2) > input_before)
                else $fatal(1, "Initial HBM A load was not observed");
        fusion_copy(0, out, 0, output_bytes);
        if (fp32_iteration) fusion_check_fp32(logical_m,physical_m,n);
        else fusion_check_output(logical_m,physical_m,n,0);
        $display("RESIDENT_OUTPUT_CHECK PASSED iteration=%0d M=%0d physical_M=%0d fp32=%0d", iteration,logical_m,physical_m,fp32_iteration);
    end

    // Bad shape and stale metadata both retire without touching HBM.
    for (int reject_case = 0; reject_case < 2; ++reject_case) begin
        ar_before = fusion_count(0);
        job_alloc(eid,generation);
        fusion_arm(eid,generation + (reject_case == 1 ? 1 : 0),2);
        program_job_regs(eid,reject_case == 0 ? 256 : physical_m,n,k,qblk,wtrans,qdir,
            reject_case == 0 ? 256 : logical_m,n,0,0,
            di,dw,dout,ds,dz,i0,i1,w0,w1,s0,s1,z0,z1,out);
        fusion_wait_job(eid,generation,reject_case == 0 ? 1 : 2);
        assert (fusion_count(0) == ar_before && fusion_count(1) == legacy_writes)
            else $fatal(1, "Rejected resident job generated HBM traffic");
    end
    $display("RESIDENT_NO_HBM_INTERMEDIATES PASSED stores=0 output_reads=0 delayed_lmem_commits=%0d", fusion_mem_commits);
    if (fp32_test) begin
        run_config_gemm_tiled("LEGACY_AFTER_FP32_FP16",physical_m,n,k,qblk,wtrans,qdir,
            di,dw,ds,dz,dout,i0,i1,w0,w1,s0,s1,z0,z1,out);
        $display("FP32_FP16_LEGACY_NO_RESET PASSED");
    end
endtask
