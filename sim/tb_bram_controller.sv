`timescale 1ns / 1ps

module tb_bram_controller;

    import mnist_pkg::*;

    localparam int CLK_PERIOD = 10;
    localparam int TIMEOUT_CYCLES = 300;

    /*
     * 테스트할 tile
     *
     * K tile 1:
     * global K index = 8 ~ 15
     *
     * N tile 2:
     * global N index = 16 ~ 23
     */
    localparam int TEST_KT      = 1;
    localparam int TEST_NT      = 2;
    localparam int TEST_N_TOTAL = 16;

    logic clk;
    logic rst_n;

    logic weight_req;
    logic data_req;

    logic [6:0] kt;
    logic [3:0] nt;
    logic [7:0] n_total;

    logic      valid;
    data_vec_t out;

    /*
     * Reference data
     */
    data_t expected_weight [0:PE_DIM-1][0:PE_DIM-1];
    data_t expected_data   [0:PE_DIM-1];

    int error_count;


    /*
     * DUT
     */
    bram_controller dut (
        .clk        (clk),
        .rst_n      (rst_n),

        .weight_req (weight_req),
        .data_req   (data_req),

        .kt         (kt),
        .nt         (nt),
        .n_total    (n_total),

        .valid      (valid),
        .out        (out)
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
        $dumpvars(0, tb_bram_controller);
    end


    /*
     * Reset
     *
     * 입력은 negedge에서 변경하고,
     * DUT는 다음 posedge에서 샘플링한다.
     */
    task automatic reset_dut;
        begin
            rst_n      = 1'b0;

            weight_req = 1'b0;
            data_req   = 1'b0;

            kt         = '0;
            nt         = '0;
            n_total    = '0;

            repeat (3) @(posedge clk);

            @(negedge clk);
            rst_n = 1'b1;

            @(posedge clk);
            #1;
        end
    endtask


    /*
     * DUT 내부 simulation memory 초기화
     *
     * $readmemh 파일에 의존하지 않고 TB에서 직접 값을 넣는다.
     */
    task automatic initialize_memories;
        int address;

        begin
            /*
             * 전체 memory 초기화
             */
            foreach (dut.w_mem[i]) begin
                dut.w_mem[i] = '0;
            end

            foreach (dut.m_mem[i]) begin
                dut.m_mem[i] = '0;
            end

            foreach (expected_weight[row, col]) begin
                expected_weight[row][col] = '0;
            end

            foreach (expected_data[i]) begin
                expected_data[i] = '0;
            end


            /*
             * Weight tile 값:
             *
             * row 0:  1  2  3  4  5  6  7  8
             * row 1:  9 10 11 12 13 14 15 16
             * ...
             * row 7: 57 58 59 60 61 62 63 64
             */
            for (int row = 0; row < PE_DIM; row++) begin
                for (int col = 0; col < PE_DIM; col++) begin
                    expected_weight[row][col]
                        = data_t'(row * PE_DIM + col + 1);

                    address =
                        ((row + TEST_KT * PE_DIM)
                        * TEST_N_TOTAL)
                        + TEST_NT * PE_DIM
                        + col;

                    dut.w_mem[address]
                        = expected_weight[row][col];
                end
            end


            /*
             * Activation tile:
             *
             * [11 12 13 14 15 16 17 18]
             */
            for (int i = 0; i < PE_DIM; i++) begin
                expected_data[i] = data_t'(11 + i);

                address = TEST_KT * PE_DIM + i;

                dut.m_mem[address] = expected_data[i];
            end
        end
    endtask


    /*
     * Weight request
     *
     * 정확한 타이밍:
     *
     * negedge N0:
     *     weight_req = 1
     *     kt/nt/n_total 유효
     *
     * posedge P0:
     *     DUT가 요청과 index를 저장
     *
     * negedge N1:
     *     weight_req = 0
     *
     * 즉 pulse 길이는 정확히 한 clock이다.
     */
    task automatic issue_weight_request;
        begin
            @(negedge clk);

            kt         = TEST_KT;
            nt         = TEST_NT;
            n_total    = TEST_N_TOTAL;

            weight_req = 1'b1;
            data_req   = 1'b0;


            /*
             * 요청을 정확히 한 클럭 유지
             */
            @(negedge clk);

            weight_req = 1'b0;


            /*
             * DUT가 입력 index를 제대로 latch했는지 확인하기 위해
             * 요청 종료 직후 외부 입력을 의도적으로 변경한다.
             *
             * 이후 출력이 정상이라면 kt_reg/nt_reg/n_total_reg를
             * 사용하고 있다는 뜻이다.
             */
            kt      = 7'd7;
            nt      = 4'd7;
            n_total = 8'd64;
        end
    endtask


    /*
     * Data request
     */
    task automatic issue_data_request;
        begin
            @(negedge clk);

            kt         = TEST_KT;
            nt         = TEST_NT;
            n_total    = TEST_N_TOTAL;

            weight_req = 1'b0;
            data_req   = 1'b1;


            /*
             * 정확히 한 클럭 pulse
             */
            @(negedge clk);

            data_req = 1'b0;


            /*
             * 요청 당시 값을 latch했는지 확인하기 위한 poison 값
             */
            kt      = 7'd7;
            nt      = 4'd7;
            n_total = 8'd64;
        end
    endtask


    /*
     * valid 시작 대기
     *
     * posedge 직후 #1에서 검사하여 NBA update 이후 값을 본다.
     */
    task automatic wait_for_valid;
        int timeout;

        begin
            timeout = 0;

            while (valid !== 1'b1 &&
                   timeout < TIMEOUT_CYCLES) begin
                @(posedge clk);
                #1;

                timeout++;
            end

            if (timeout >= TIMEOUT_CYCLES) begin
                $fatal(
                    1,
                    "[TIMEOUT] valid was not asserted"
                );
            end
        end
    endtask


    /*
     * Weight output 검증
     *
     * data_reg에 역순으로 저장했으므로 출력 순서는:
     *
     * beat 0 -> original col7
     * beat 1 -> original col6
     * ...
     * beat 7 -> original col0
     *
     * valid은 정확히 8클럭이어야 한다.
     */
    task automatic check_weight_output;
        int valid_count;
        int expected_col;
        int timeout;

        begin
            valid_count = 0;
            timeout     = 0;

            wait_for_valid();

            /*
             * wait_for_valid가 반환된 시점의 valid/out이
             * 첫 번째 출력 beat이다.
             */
            while (valid === 1'b1 &&
                   timeout < TIMEOUT_CYCLES) begin

                expected_col = PE_DIM - 1 - valid_count;

                $display("");
                $display(
                    "[WEIGHT BEAT %0d] expected original column %0d",
                    valid_count,
                    expected_col
                );

                /*
                 * 8개 row 병렬 비교
                 *
                 * valid_count가 8 이상이면 extra beat이므로,
                 * 배열 index를 사용하지 않고 별도로 오류 처리한다.
                 */
                if (valid_count < PE_DIM) begin
                    for (int row = 0; row < PE_DIM; row++) begin
                        if (
                            $signed(out[row]) !==
                            $signed(
                                expected_weight[row][expected_col]
                            )
                        ) begin
                            $error(
                                "[WEIGHT FAIL] beat=%0d row=%0d actual=%0d expected=%0d",
                                valid_count,
                                row,
                                $signed(out[row]),
                                $signed(
                                    expected_weight[row][expected_col]
                                )
                            );

                            error_count++;
                        end
                        else begin
                            $display(
                                "[WEIGHT PASS] beat=%0d row=%0d value=%0d",
                                valid_count,
                                row,
                                $signed(out[row])
                            );
                        end
                    end
                end
                else begin
                    $error(
                        "[WEIGHT TIMING FAIL] extra valid beat detected: beat=%0d",
                        valid_count
                    );

                    error_count++;
                end

                valid_count++;
                timeout++;

                @(posedge clk);
                #1;
            end


            /*
             * valid pulse 길이 검사
             */
            if (valid_count != PE_DIM) begin
                $error(
                    "[WEIGHT VALID FAIL] valid length=%0d clocks, expected=%0d clocks",
                    valid_count,
                    PE_DIM
                );

                error_count++;
            end
            else begin
                $display("");
                $display(
                    "[WEIGHT VALID PASS] valid length = %0d clocks",
                    valid_count
                );
            end


            if (timeout >= TIMEOUT_CYCLES) begin
                $fatal(
                    1,
                    "[TIMEOUT] weight valid did not deassert"
                );
            end
        end
    endtask

    task automatic setup_expected_values;
        begin
            foreach (expected_weight[row, col]) begin
                expected_weight[row][col]
                    = data_t'(row * PE_DIM + col + 1);
            end

            foreach (expected_data[i]) begin
                expected_data[i] = data_t'(11 + i);
            end
        end
    endtask

    /*
     * Activation output 검증
     *
     * activation은 valid 1클럭 동안 8개 lane이
     * 한 번에 출력되어야 한다.
     */
    task automatic check_data_output;
        int valid_count;
        int timeout;

        begin
            valid_count = 0;
            timeout     = 0;

            wait_for_valid();

            while (valid === 1'b1 &&
                   timeout < TIMEOUT_CYCLES) begin

                $display("");
                $display(
                    "[DATA BEAT %0d]",
                    valid_count
                );

                if (valid_count == 0) begin
                    for (int i = 0; i < PE_DIM; i++) begin
                        if (
                            $signed(out[i]) !==
                            $signed(expected_data[i])
                        ) begin
                            $error(
                                "[DATA FAIL] lane=%0d actual=%0d expected=%0d",
                                i,
                                $signed(out[i]),
                                $signed(expected_data[i])
                            );

                            error_count++;
                        end
                        else begin
                            $display(
                                "[DATA PASS] lane=%0d value=%0d",
                                i,
                                $signed(out[i])
                            );
                        end
                    end
                end
                else begin
                    $error(
                        "[DATA TIMING FAIL] extra valid beat detected: beat=%0d",
                        valid_count
                    );

                    error_count++;
                end

                valid_count++;
                timeout++;

                @(posedge clk);
                #1;
            end


            /*
             * Data valid은 정확히 한 클럭이어야 함
             */
            if (valid_count != 1) begin
                $error(
                    "[DATA VALID FAIL] valid length=%0d clocks, expected=1 clock",
                    valid_count
                );

                error_count++;
            end
            else begin
                $display("");
                $display(
                    "[DATA VALID PASS] valid length = 1 clock"
                );
            end


            if (timeout >= TIMEOUT_CYCLES) begin
                $fatal(
                    1,
                    "[TIMEOUT] data valid did not deassert"
                );
            end
        end
    endtask


    /*
     * Request pulse width assertion
     *
     * posedge에서 request가 1이면 다음 posedge에서는
     * 반드시 0이어야 한다.
     */
    property p_weight_req_one_cycle;
        @(posedge clk)
        disable iff (!rst_n)

        weight_req |=> !weight_req;
    endproperty

    assert property (p_weight_req_one_cycle)
    else begin
        $fatal(
            1,
            "[REQUEST TIMING FAIL] weight_req is longer than one clock"
        );
    end


    property p_data_req_one_cycle;
        @(posedge clk)
        disable iff (!rst_n)

        data_req |=> !data_req;
    endproperty

    assert property (p_data_req_one_cycle)
    else begin
        $fatal(
            1,
            "[REQUEST TIMING FAIL] data_req is longer than one clock"
        );
    end


    /*
     * 동시에 두 요청을 보내면 안 됨
     */
    property p_requests_mutually_exclusive;
        @(posedge clk)
        disable iff (!rst_n)

        !(weight_req && data_req);
    endproperty

    assert property (p_requests_mutually_exclusive)
    else begin
        $fatal(
            1,
            "[REQUEST FAIL] weight_req and data_req asserted together"
        );
    end


    /*
     * Main test
     */
    initial begin
        error_count = 0;

        /*
         * DUT 내부 initial $readmemh와 충돌하지 않도록
         * time 0 이후 TB 값으로 덮어쓴다.
         */
        #1;
        reset_dut();
        setup_expected_values();


        /*
         * ----------------------------------------
         * Test 1: Weight read
         * ----------------------------------------
         */
        $display("");
        $display("========================================");
        $display("Test 1: BRAM weight transaction");
        $display("========================================");

        issue_weight_request();
        check_weight_output();


        /*
         * BRAM_IDLE 복귀 여유
         */
        repeat (2) @(posedge clk);
        #1;


        /*
         * ----------------------------------------
         * Test 2: Activation read
         * ----------------------------------------
         */
        $display("");
        $display("========================================");
        $display("Test 2: BRAM activation transaction");
        $display("========================================");

        issue_data_request();
        check_data_output();


        /*
         * ----------------------------------------
         * Final result
         * ----------------------------------------
         */
        $display("");

        if (error_count == 0) begin
            $display("========================================");
            $display("[TEST PASS] BRAM controller passed");
            $display("========================================");
        end
        else begin
            $fatal(
                1,
                "[TEST FAIL] BRAM controller: %0d errors",
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
        repeat (1000) @(posedge clk);

        $fatal(
            1,
            "[GLOBAL TIMEOUT] simulation did not finish"
        );
    end

endmodule