`timescale 1ns / 1ps

module tb_gemm_controller;

    import mnist_pkg::*;

    localparam int CLK_PERIOD     = 10;
    localparam int TIMEOUT_CYCLES = 10000;

    /*
     * (1×32) × (32×16)
     *
     * K tile: 4개 → 마지막 index 3
     * N tile: 2개 → 마지막 index 1
     */
    localparam logic [6:0] TEST_K_IDX_MAX = 7'd3;
    localparam logic [3:0] TEST_N_IDX_MAX = 4'd1;
    localparam logic [7:0] TEST_N_TOTAL   = 8'd16;

    logic clk;
    logic rst_n;
    logic start;

    logic [6:0] k_idx_max;
    logic [3:0] n_idx_max;
    logic [7:0] n_total;

    logic       relu_en;
    logic [4:0] shift_amount;

    logic done;

    data_vec_t expected_tile0;
    data_vec_t expected_tile1;

    int error_count;

    int weight_req_count;
    int data_req_count;
    int write_req_count;
    int write_done_count;
    int commit_req_count;
    int commit_done_count;

    int load_weight_count;
    int start_calc_count;

    int acc_en_count;
    int acc_save_count;
    int acc_add_count;

    int done_count;


    gemm_controller dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),

        .k_idx_max    (k_idx_max),
        .n_idx_max    (n_idx_max),
        .n_total      (n_total),

        .relu_en      (relu_en),
        .shift_amount (shift_amount),

        .done         (done)
    );


    /*
     * Clock
     */
    initial begin
        clk = 1'b0;

        forever #(CLK_PERIOD / 2)
            clk = ~clk;
    end


    /*
     * Waveform
     */
    initial begin
        $dumpfile("wave.fst");
        $dumpvars(0, tb_gemm_controller);
    end


    /*
     * Test memory 설정
     *
     * Input:
     * m_mem[k] = k+1, k=0~31
     *
     * Weight:
     * W[k][n] = 1 when k=n or k=n+16
     *
     * 따라서:
     * output[n] = input[n] + input[n+16]
     *           = (n+1) + (n+17)
     *           = 2n + 18
     */
    task automatic initialize_test_memory;
        int address;

        begin
            /*
             * 전체 memory 초기화
             */
            foreach (dut.u_bram_controller.w_mem[i]) begin
                dut.u_bram_controller.w_mem[i] = data_t'(0);
            end

            foreach (dut.u_bram_controller.m_mem[i]) begin
                dut.u_bram_controller.m_mem[i] = data_t'(0);
            end

            foreach (dut.u_bram_controller.result_buffer[i]) begin
                dut.u_bram_controller.result_buffer[i]
                    = data_t'(0);
            end


            /*
             * Input activation = [1,2,...,32]
             */
            for (int k = 0; k < 32; k++) begin
                dut.u_bram_controller.m_mem[k]
                    = data_t'(k + 1);
            end


            /*
             * Weight matrix: 32×16, row-major
             *
             * address = k * 16 + n
             */
            for (int k = 0; k < 32; k++) begin
                for (int n = 0; n < 16; n++) begin
                    address = k * TEST_N_TOTAL + n;

                    if ((k == n) || (k == n + 16)) begin
                        dut.u_bram_controller.w_mem[address]
                            = data_t'(1);
                    end
                    else begin
                        dut.u_bram_controller.w_mem[address]
                            = data_t'(0);
                    end
                end
            end


            /*
             * Expected:
             *
             * output[n] = 2n + 18
             */
            for (int i = 0; i < PE_DIM; i++) begin
                expected_tile0[i] = data_t'(18 + 2*i);
                expected_tile1[i] = data_t'(34 + 2*i);
            end
        end
    endtask


    task automatic reset_dut;
        begin
            rst_n        = 1'b0;
            start        = 1'b0;

            k_idx_max    = '0;
            n_idx_max    = '0;
            n_total      = '0;

            relu_en      = 1'b0;
            shift_amount = '0;

            repeat (3) @(posedge clk);

            @(negedge clk);
            rst_n = 1'b1;

            @(posedge clk);
            #1;
        end
    endtask


    task automatic issue_start;
        begin
            @(negedge clk);

            start        = 1'b1;

            k_idx_max    = TEST_K_IDX_MAX;
            n_idx_max    = TEST_N_IDX_MAX;
            n_total      = TEST_N_TOTAL;

            relu_en      = 1'b0;
            shift_amount = 5'd0;


            /*
             * 정확히 한 클럭 pulse
             */
            @(negedge clk);

            start = 1'b0;


            /*
             * 내부 설정 latch 검증용 poison
             */
            k_idx_max    = 7'd97;
            n_idx_max    = 4'd15;
            n_total      = 8'd128;

            relu_en      = 1'b1;
            shift_amount = 5'd8;
        end
    endtask


    /*
     * 원본 activation이 아직 m_mem에 유지되는지 검사
     */
    task automatic check_input_memory_preserved(
        input string check_name
    );
        int before_error;

        begin
            before_error = error_count;

            $display("");
            $display("========================================");
            $display("%s", check_name);
            $display("========================================");

            for (int i = 0; i < 32; i++) begin
                if (
                    $signed(dut.u_bram_controller.m_mem[i])
                    !== (i + 1)
                ) begin
                    $display(
                        "[INPUT FAIL] address=%0d actual=%0d expected=%0d",
                        i,
                        $signed(
                            dut.u_bram_controller.m_mem[i]
                        ),
                        i + 1
                    );

                    error_count++;
                end
            end

            if (error_count == before_error) begin
                $display(
                    "[INPUT PASS] original activation is preserved"
                );
            end
        end
    endtask


    /*
     * 첫 N tile 결과 확인
     */
    task automatic check_result_buffer_tile0;
        int before_error;

        begin
            before_error = error_count;

            $display("");
            $display("========================================");
            $display("Checking result_buffer tile 0");
            $display("========================================");

            for (int i = 0; i < PE_DIM; i++) begin
                if (
                    $signed(
                        dut.u_bram_controller.result_buffer[i]
                    )
                    !==
                    $signed(expected_tile0[i])
                ) begin
                    $display(
                        "[BUFFER0 FAIL] lane=%0d actual=%0d expected=%0d",
                        i,
                        $signed(
                            dut.u_bram_controller.result_buffer[i]
                        ),
                        $signed(expected_tile0[i])
                    );

                    error_count++;
                end
                else begin
                    $display(
                        "[BUFFER0 PASS] lane=%0d value=%0d",
                        i,
                        $signed(
                            dut.u_bram_controller.result_buffer[i]
                        )
                    );
                end
            end

            if (error_count == before_error) begin
                $display(
                    "[BUFFER0 PASS] first output tile stored"
                );
            end
        end
    endtask


    /*
     * 두 번째 N tile까지 모두 buffer에 저장됐는지 확인
     */
    task automatic check_result_buffer_complete;
        begin
            $display("");
            $display("========================================");
            $display("Checking complete result_buffer");
            $display("========================================");

            for (int i = 0; i < PE_DIM; i++) begin
                if (
                    $signed(
                        dut.u_bram_controller.result_buffer[i]
                    )
                    !==
                    $signed(expected_tile0[i])
                ) begin
                    $display(
                        "[BUFFER FAIL] index=%0d actual=%0d expected=%0d",
                        i,
                        $signed(
                            dut.u_bram_controller.result_buffer[i]
                        ),
                        $signed(expected_tile0[i])
                    );

                    error_count++;
                end
                else begin
                    $display(
                        "[BUFFER PASS] index=%0d value=%0d",
                        i,
                        $signed(
                            dut.u_bram_controller.result_buffer[i]
                        )
                    );
                end
            end

            for (int i = 0; i < PE_DIM; i++) begin
                if (
                    $signed(
                        dut.u_bram_controller.result_buffer[
                            PE_DIM + i
                        ]
                    )
                    !==
                    $signed(expected_tile1[i])
                ) begin
                    $display(
                        "[BUFFER FAIL] index=%0d actual=%0d expected=%0d",
                        PE_DIM + i,
                        $signed(
                            dut.u_bram_controller.result_buffer[
                                PE_DIM + i
                            ]
                        ),
                        $signed(expected_tile1[i])
                    );

                    error_count++;
                end
                else begin
                    $display(
                        "[BUFFER PASS] index=%0d value=%0d",
                        PE_DIM + i,
                        $signed(
                            dut.u_bram_controller.result_buffer[
                                PE_DIM + i
                            ]
                        )
                    );
                end
            end
        end
    endtask


    /*
     * Commit 완료 후 m_mem 결과 확인
     */
    task automatic check_committed_memory;
        begin
            $display("");
            $display("========================================");
            $display("Checking committed m_mem result");
            $display("========================================");

            for (int i = 0; i < PE_DIM; i++) begin
                if (
                    $signed(
                        dut.u_bram_controller.m_mem[i]
                    )
                    !==
                    $signed(expected_tile0[i])
                ) begin
                    $display(
                        "[COMMIT FAIL] index=%0d actual=%0d expected=%0d",
                        i,
                        $signed(
                            dut.u_bram_controller.m_mem[i]
                        ),
                        $signed(expected_tile0[i])
                    );

                    error_count++;
                end
                else begin
                    $display(
                        "[COMMIT PASS] index=%0d value=%0d",
                        i,
                        $signed(
                            dut.u_bram_controller.m_mem[i]
                        )
                    );
                end
            end

            for (int i = 0; i < PE_DIM; i++) begin
                if (
                    $signed(
                        dut.u_bram_controller.m_mem[
                            PE_DIM + i
                        ]
                    )
                    !==
                    $signed(expected_tile1[i])
                ) begin
                    $display(
                        "[COMMIT FAIL] index=%0d actual=%0d expected=%0d",
                        PE_DIM + i,
                        $signed(
                            dut.u_bram_controller.m_mem[
                                PE_DIM + i
                            ]
                        ),
                        $signed(expected_tile1[i])
                    );

                    error_count++;
                end
                else begin
                    $display(
                        "[COMMIT PASS] index=%0d value=%0d",
                        PE_DIM + i,
                        $signed(
                            dut.u_bram_controller.m_mem[
                                PE_DIM + i
                            ]
                        )
                    );
                end
            end
        end
    endtask


    /*
     * Commit 후 result_buffer 초기화 확인
     */
    task automatic check_result_buffer_cleared;
        int before_error;

        begin
            before_error = error_count;

            $display("");
            $display("========================================");
            $display("Checking result_buffer clear");
            $display("========================================");

            for (int i = 0; i < 16; i++) begin
                if (
                    $signed(
                        dut.u_bram_controller.result_buffer[i]
                    )
                    !== 0
                ) begin
                    $display(
                        "[CLEAR FAIL] index=%0d value=%0d expected=0",
                        i,
                        $signed(
                            dut.u_bram_controller.result_buffer[i]
                        )
                    );

                    error_count++;
                end
            end

            if (error_count == before_error) begin
                $display(
                    "[CLEAR PASS] result_buffer[0:15] cleared"
                );
            end
        end
    endtask


    /*
     * 완료 대기
     */
    task automatic wait_for_done;
        int timeout;

        begin
            timeout = 0;

            while (
                (done !== 1'b1) &&
                (timeout < TIMEOUT_CYCLES)
            ) begin
                @(posedge clk);
                #1;

                timeout++;
            end

            if (timeout >= TIMEOUT_CYCLES) begin
                $fatal(
                    1,
                    "[TIMEOUT] GEMM done was not asserted"
                );
            end

            $display("");
            $display(
                "[GEMM DONE] detected at time %0t",
                $time
            );

            /*
             * Monitor race 방지
             */
            @(negedge clk);
        end
    endtask


    /*
     * Event monitor
     */
    always @(posedge clk) begin
        #1;

        if (rst_n) begin
            if (dut.weight_req)
                weight_req_count++;

            if (dut.data_req)
                data_req_count++;

            if (dut.write_req)
                write_req_count++;

            if (dut.write_done)
                write_done_count++;

            if (dut.commit_req)
                commit_req_count++;

            if (dut.commit_done)
                commit_done_count++;

            if (dut.load_weight)
                load_weight_count++;

            if (dut.start_calc)
                start_calc_count++;

            if (dut.acc_en) begin
                acc_en_count++;

                if (dut.acc_save)
                    acc_save_count++;
                else
                    acc_add_count++;
            end

            if (done)
                done_count++;
        end
    end


    /*
     * 첫 번째 tile write 완료 시점 검사
     */
    initial begin : first_write_checker
        wait (rst_n === 1'b1);

        wait (write_done_count == 1);

        /*
         * write_done monitor와 RTL NBA 완료 보장
         */
        @(negedge clk);

        check_result_buffer_tile0();

        check_input_memory_preserved(
            "Checking m_mem after first output tile"
        );
    end


    /*
     * 두 번째 tile 저장 후, commit 전 검사
     */
    initial begin : second_write_checker
        wait (rst_n === 1'b1);

        wait (write_done_count == 2);

        /*
         * 아직 COMMIT state에 들어가기 전 시점에서 검사
         */
        @(negedge clk);

        if (commit_done_count == 0) begin
            check_result_buffer_complete();

            check_input_memory_preserved(
                "Checking m_mem before commit"
            );
        end
    end


    /*
     * Event count 확인
     *
     * K tile 4 × N tile 2:
     * 총 GEMM tile = 8
     */
    task automatic check_event_counts;
        begin
            $display("");
            $display("========================================");
            $display("Checking controller event counts");
            $display("========================================");

            if (weight_req_count != 8) begin
                $display(
                    "[COUNT FAIL] weight_req=%0d expected=8",
                    weight_req_count
                );
                error_count++;
            end
            else
                $display("[COUNT PASS] weight_req = 8");


            if (data_req_count != 8) begin
                $display(
                    "[COUNT FAIL] data_req=%0d expected=8",
                    data_req_count
                );
                error_count++;
            end
            else
                $display("[COUNT PASS] data_req = 8");


            if (load_weight_count != 8) begin
                $display(
                    "[COUNT FAIL] load_weight=%0d expected=8",
                    load_weight_count
                );
                error_count++;
            end
            else
                $display("[COUNT PASS] load_weight = 8");


            if (start_calc_count != 8) begin
                $display(
                    "[COUNT FAIL] start_calc=%0d expected=8",
                    start_calc_count
                );
                error_count++;
            end
            else
                $display("[COUNT PASS] start_calc = 8");


            if (acc_en_count != 8) begin
                $display(
                    "[COUNT FAIL] acc_en=%0d expected=8",
                    acc_en_count
                );
                error_count++;
            end
            else
                $display("[COUNT PASS] acc_en = 8");


            if (acc_save_count != 2) begin
                $display(
                    "[COUNT FAIL] acc_save=%0d expected=2",
                    acc_save_count
                );
                error_count++;
            end
            else
                $display("[COUNT PASS] acc_save = 2");


            if (acc_add_count != 6) begin
                $display(
                    "[COUNT FAIL] acc_add=%0d expected=6",
                    acc_add_count
                );
                error_count++;
            end
            else
                $display("[COUNT PASS] acc_add = 6");


            if (write_req_count != 2) begin
                $display(
                    "[COUNT FAIL] write_req=%0d expected=2",
                    write_req_count
                );
                error_count++;
            end
            else
                $display("[COUNT PASS] write_req = 2");


            if (write_done_count != 2) begin
                $display(
                    "[COUNT FAIL] write_done=%0d expected=2",
                    write_done_count
                );
                error_count++;
            end
            else
                $display("[COUNT PASS] write_done = 2");


            if (commit_req_count != 1) begin
                $display(
                    "[COUNT FAIL] commit_req=%0d expected=1",
                    commit_req_count
                );
                error_count++;
            end
            else
                $display("[COUNT PASS] commit_req = 1");


            if (commit_done_count != 1) begin
                $display(
                    "[COUNT FAIL] commit_done=%0d expected=1",
                    commit_done_count
                );
                error_count++;
            end
            else
                $display("[COUNT PASS] commit_done = 1");


            if (done_count != 1) begin
                $display(
                    "[COUNT FAIL] done=%0d expected=1",
                    done_count
                );
                error_count++;
            end
            else
                $display("[COUNT PASS] done = 1");
        end
    endtask


    /*
     * Pulse-width assertions
     */
    property p_start_one_cycle;
        @(posedge clk)
        disable iff (!rst_n)

        start |=> !start;
    endproperty


    property p_weight_req_one_cycle;
        @(posedge clk)
        disable iff (!rst_n)

        dut.weight_req |=> !dut.weight_req;
    endproperty


    property p_data_req_one_cycle;
        @(posedge clk)
        disable iff (!rst_n)

        dut.data_req |=> !dut.data_req;
    endproperty


    property p_write_req_one_cycle;
        @(posedge clk)
        disable iff (!rst_n)

        dut.write_req |=> !dut.write_req;
    endproperty


    property p_commit_req_one_cycle;
        @(posedge clk)
        disable iff (!rst_n)

        dut.commit_req |=> !dut.commit_req;
    endproperty


    property p_load_weight_one_cycle;
        @(posedge clk)
        disable iff (!rst_n)

        dut.load_weight |=> !dut.load_weight;
    endproperty


    property p_start_calc_one_cycle;
        @(posedge clk)
        disable iff (!rst_n)

        dut.start_calc |=> !dut.start_calc;
    endproperty


    property p_done_one_cycle;
        @(posedge clk)
        disable iff (!rst_n)

        done |=> !done;
    endproperty


    assert property (p_start_one_cycle)
    else
        $fatal(
            1,
            "[TIMING FAIL] start longer than one clock"
        );


    assert property (p_weight_req_one_cycle)
    else
        $fatal(
            1,
            "[TIMING FAIL] weight_req longer than one clock"
        );


    assert property (p_data_req_one_cycle)
    else
        $fatal(
            1,
            "[TIMING FAIL] data_req longer than one clock"
        );


    assert property (p_write_req_one_cycle)
    else
        $fatal(
            1,
            "[TIMING FAIL] write_req longer than one clock"
        );


    assert property (p_commit_req_one_cycle)
    else
        $fatal(
            1,
            "[TIMING FAIL] commit_req longer than one clock"
        );


    assert property (p_load_weight_one_cycle)
    else
        $fatal(
            1,
            "[TIMING FAIL] load_weight longer than one clock"
        );


    assert property (p_start_calc_one_cycle)
    else
        $fatal(
            1,
            "[TIMING FAIL] start_calc longer than one clock"
        );


    assert property (p_done_one_cycle)
    else
        $fatal(
            1,
            "[TIMING FAIL] done longer than one clock"
        );


    /*
     * Main test
     */
    initial begin
        error_count = 0;

        weight_req_count  = 0;
        data_req_count    = 0;

        write_req_count   = 0;
        write_done_count  = 0;

        commit_req_count  = 0;
        commit_done_count = 0;

        load_weight_count = 0;
        start_calc_count  = 0;

        acc_en_count      = 0;
        acc_save_count    = 0;
        acc_add_count     = 0;

        done_count        = 0;

        expected_tile0 = '{default:'0};
        expected_tile1 = '{default:'0};


        /*
         * DUT 내부 $readmemh 이후 테스트 값으로 덮어씀
         */
        #1;

        initialize_test_memory();

        reset_dut();


        $display("");
        $display("========================================");
        $display("GEMM result-buffer integration test");
        $display("(1x32) * (32x16)");
        $display("========================================");


        issue_start();

        wait_for_done();


        /*
         * commit 이후 결과 확인
         */
        check_committed_memory();
        check_result_buffer_cleared();
        check_event_counts();


        $display("");

        if (error_count == 0) begin
            $display("========================================");
            $display("[TEST PASS] GEMM result-buffer test passed");
            $display("========================================");
        end
        else begin
            $fatal(
                1,
                "[TEST FAIL] GEMM result-buffer test: %0d errors",
                error_count
            );
        end

        repeat (3) @(posedge clk);

        $finish;
    end


    /*
     * Global timeout
     */
    initial begin
        repeat (TIMEOUT_CYCLES + 100)
            @(posedge clk);

        $fatal(
            1,
            "[GLOBAL TIMEOUT] simulation did not finish"
        );
    end

endmodule