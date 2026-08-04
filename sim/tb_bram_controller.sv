`timescale 1ns / 1ps

module tb_bram_controller;

    import mnist_pkg::*;

    localparam int CLK_PERIOD     = 10;
    localparam int TIMEOUT_CYCLES = 300;

    /*
     * 기존 read test 설정
     */
    localparam int TEST_KT      = 1;
    localparam int TEST_NT      = 2;
    localparam int TEST_N_TOTAL = 16;

    /*
     * Write/read-back test 설정
     *
     * write_nt=3이면:
     * m_mem[24:31]에 저장
     *
     * data read 시 kt=3으로 요청하면:
     * m_mem[24:31]을 읽음
     */
    localparam int WRITE_TILE = 3;

    logic clk;
    logic rst_n;

    logic weight_req;
    logic data_req;
    logic write_req;

    logic [3:0] write_nt;
    data_vec_t write_data;

    logic [6:0] kt;
    logic [3:0] nt;
    logic [7:0] n_total;

    logic      valid;
    logic      write_done;
    data_vec_t out;

    /*
     * Expected values
     */
    data_t expected_weight [0:PE_DIM-1][0:PE_DIM-1];
    data_t expected_data   [0:PE_DIM-1];
    data_t expected_write  [0:PE_DIM-1];

    int error_count;


    /*
     * DUT
     */
    bram_controller dut (
        .clk        (clk),
        .rst_n      (rst_n),

        .weight_req (weight_req),
        .data_req   (data_req),
        .write_req  (write_req),

        .write_nt   (write_nt),
        .write_data (write_data),

        .kt         (kt),
        .nt         (nt),
        .n_total    (n_total),

        .valid      (valid),
        .write_done (write_done),
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
     * reset 해제도 negedge에서 수행한다.
     */
    task automatic reset_dut;
        begin
            rst_n      = 1'b0;

            weight_req = 1'b0;
            data_req   = 1'b0;
            write_req  = 1'b0;

            write_nt   = '0;
            write_data = '{default:'0};

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
     * Expected value 설정
     *
     * w_data.mem과 m_data.mem의 test pattern에 맞춘다.
     */
    task automatic setup_expected_values;
        begin
            /*
             * Weight:
             *
             * row 0:  1  2  3  4  5  6  7  8
             * row 1:  9 10 11 12 13 14 15 16
             * ...
             * row 7: 57 58 59 60 61 62 63 64
             */
            foreach (expected_weight[row, col]) begin
                expected_weight[row][col]
                    = data_t'(row * PE_DIM + col + 1);
            end

            /*
             * 초기 activation:
             * [11,12,13,14,15,16,17,18]
             */
            foreach (expected_data[i]) begin
                expected_data[i] = data_t'(11 + i);
            end

            /*
             * Write test data:
             *
             * signed 값도 포함해 write/read-back 검증
             * [21, -22, 23, -24, 25, -26, 27, -28]
             */
            expected_write[0] = data_t'( 21);
            expected_write[1] = data_t'(-22);
            expected_write[2] = data_t'( 23);
            expected_write[3] = data_t'(-24);
            expected_write[4] = data_t'( 25);
            expected_write[5] = data_t'(-26);
            expected_write[6] = data_t'( 27);
            expected_write[7] = data_t'(-28);
        end
    endtask


    /*
     * Weight request
     *
     * negedge N0:
     *   request 및 주소 설정
     *
     * posedge P0:
     *   DUT가 request와 주소를 latch
     *
     * negedge N1:
     *   request 해제
     *   외부 주소를 poison 값으로 변경
     */
    task automatic issue_weight_request;
        begin
            @(negedge clk);

            weight_req = 1'b1;
            data_req   = 1'b0;
            write_req  = 1'b0;

            kt      = TEST_KT;
            nt      = TEST_NT;
            n_total = TEST_N_TOTAL;

            /*
             * 정확히 한 클럭 유지
             */
            @(negedge clk);

            weight_req = 1'b0;

            /*
             * 내부 latch 검증용 poison
             */
            kt      = 7'd7;
            nt      = 4'd7;
            n_total = 8'd64;
        end
    endtask


    /*
     * Data request
     */
    task automatic issue_data_request(
        input logic [6:0] requested_kt
    );
        begin
            @(negedge clk);

            weight_req = 1'b0;
            data_req   = 1'b1;
            write_req  = 1'b0;

            kt      = requested_kt;
            nt      = TEST_NT;
            n_total = TEST_N_TOTAL;

            /*
             * 정확히 한 클럭 유지
             */
            @(negedge clk);

            data_req = 1'b0;

            /*
             * 요청 이후 외부 입력 변경
             */
            kt      = 7'd7;
            nt      = 4'd7;
            n_total = 8'd64;
        end
    endtask


    /*
     * Write request
     *
     * negedge N0:
     *   write_req=1
     *   write_nt 및 write_data 유효
     *
     * posedge P0:
     *   DUT가 write 정보 latch
     *
     * negedge N1:
     *   write_req=0
     *   외부 write 데이터 poison 처리
     *
     * posedge P1:
     *   BRAM_WRITE 상태에서 실제 m_mem write
     *
     * posedge P2:
     *   write_done=1
     */
    task automatic issue_write_request;
        begin
            @(negedge clk);

            weight_req = 1'b0;
            data_req   = 1'b0;
            write_req  = 1'b1;

            write_nt = WRITE_TILE;

            for (int i = 0; i < PE_DIM; i++) begin
                write_data[i] = expected_write[i];
            end

            /*
             * 요청을 정확히 한 클럭 유지
             */
            @(negedge clk);

            write_req = 1'b0;

            /*
             * DUT가 요청 순간 데이터를 latch했는지 확인하기 위해
             * 즉시 외부 입력을 poison 값으로 변경한다.
             */
            write_nt   = 4'd15;
            write_data = '{default:data_t'(8'h55)};
        end
    endtask


    /*
     * valid 시작 대기
     *
     * posedge 후 #1에서 NBA 반영 이후 값을 확인한다.
     */
    task automatic wait_for_valid;
        int timeout;

        begin
            timeout = 0;

            while ((valid !== 1'b1) &&
                   (timeout < TIMEOUT_CYCLES)) begin
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
     * write_done 대기
     *
     * 동시에 read-valid이 잘못 올라오지 않는지도 검사한다.
     */
    task automatic wait_for_write_done;
        int timeout;

        begin
            timeout = 0;

            while ((write_done !== 1'b1) &&
                   (timeout < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                #1;

                if (valid === 1'b1) begin
                    $error(
                        "[WRITE TIMING FAIL] valid asserted during write transaction"
                    );

                    error_count++;
                end

                timeout++;
            end

            if (timeout >= TIMEOUT_CYCLES) begin
                $fatal(
                    1,
                    "[TIMEOUT] write_done was not asserted"
                );
            end

            /*
             * write_done이 올라온 동일 cycle에서도
             * valid은 반드시 0이어야 한다.
             */
            if (valid !== 1'b0) begin
                $error(
                    "[WRITE TIMING FAIL] valid must be 0 when write_done is asserted"
                );

                error_count++;
            end
            else begin
                $display(
                    "[WRITE TIMING PASS] valid remained 0 during write"
                );
            end
        end
    endtask


    /*
     * write_done pulse 길이 확인
     *
     * wait_for_write_done 반환 시점에는 write_done=1이다.
     * 다음 posedge 이후에는 반드시 0이어야 한다.
     */
    task automatic check_write_done_width;
        begin
            @(posedge clk);
            #1;

            if (write_done !== 1'b0) begin
                $error(
                    "[WRITE DONE FAIL] write_done is longer than one clock"
                );

                error_count++;
            end
            else begin
                $display(
                    "[WRITE DONE PASS] write_done length = 1 clock"
                );
            end
        end
    endtask


    /*
     * Weight 출력 검증
     *
     * 출력 순서:
     * beat 0 = original col7
     * ...
     * beat 7 = original col0
     */
    task automatic check_weight_output;
        int valid_count;
        int expected_col;
        int timeout;

        begin
            valid_count = 0;
            timeout     = 0;

            wait_for_valid();

            while ((valid === 1'b1) &&
                   (timeout < TIMEOUT_CYCLES)) begin

                expected_col = PE_DIM - 1 - valid_count;

                $display("");
                $display(
                    "[WEIGHT BEAT %0d] expected original column %0d",
                    valid_count,
                    expected_col
                );

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
                        "[WEIGHT TIMING FAIL] extra valid beat=%0d",
                        valid_count
                    );

                    error_count++;
                end

                valid_count++;
                timeout++;

                @(posedge clk);
                #1;
            end

            if (valid_count != PE_DIM) begin
                $error(
                    "[WEIGHT VALID FAIL] valid length=%0d, expected=%0d",
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


    /*
     * Data 출력 검증
     *
     * expected_vector를 인자로 받아 초기 data와
     * write-read-back 결과에 공통으로 사용한다.
     */
    task automatic check_data_output(
        input string     test_name,
        input data_vec_t expected_vector
    );
        int valid_count;
        int timeout;

        begin
            valid_count = 0;
            timeout     = 0;

            wait_for_valid();

            while ((valid === 1'b1) &&
                   (timeout < TIMEOUT_CYCLES)) begin

                $display("");
                $display(
                    "[%s BEAT %0d]",
                    test_name,
                    valid_count
                );

                if (valid_count == 0) begin
                    for (int i = 0; i < PE_DIM; i++) begin
                        if (
                            $signed(out[i]) !==
                            $signed(expected_vector[i])
                        ) begin
                            $error(
                                "[%s FAIL] lane=%0d actual=%0d expected=%0d",
                                test_name,
                                i,
                                $signed(out[i]),
                                $signed(expected_vector[i])
                            );

                            error_count++;
                        end
                        else begin
                            $display(
                                "[%s PASS] lane=%0d value=%0d",
                                test_name,
                                i,
                                $signed(out[i])
                            );
                        end
                    end
                end
                else begin
                    $error(
                        "[%s TIMING FAIL] extra valid beat=%0d",
                        test_name,
                        valid_count
                    );

                    error_count++;
                end

                valid_count++;
                timeout++;

                @(posedge clk);
                #1;
            end

            if (valid_count != 1) begin
                $error(
                    "[%s VALID FAIL] valid length=%0d, expected=1",
                    test_name,
                    valid_count
                );

                error_count++;
            end
            else begin
                $display("");
                $display(
                    "[%s VALID PASS] valid length = 1 clock",
                    test_name
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
     * Request pulse assertions
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
            "[REQUEST FAIL] weight_req is longer than one clock"
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
            "[REQUEST FAIL] data_req is longer than one clock"
        );
    end


    property p_write_req_one_cycle;
        @(posedge clk)
        disable iff (!rst_n)

        write_req |=> !write_req;
    endproperty

    assert property (p_write_req_one_cycle)
    else begin
        $fatal(
            1,
            "[REQUEST FAIL] write_req is longer than one clock"
        );
    end


    /*
     * 세 요청은 동시에 올라가면 안 됨
     */
    property p_requests_mutually_exclusive;
        @(posedge clk)
        disable iff (!rst_n)

        !(
            (weight_req && data_req)  ||
            (weight_req && write_req) ||
            (data_req   && write_req)
        );
    endproperty

    assert property (p_requests_mutually_exclusive)
    else begin
        $fatal(
            1,
            "[REQUEST FAIL] multiple requests asserted together"
        );
    end


    /*
     * Main test
     */
    initial begin
        data_vec_t expected_data_vector;
        data_vec_t expected_write_vector;

        error_count = 0;

        setup_expected_values();

        for (int i = 0; i < PE_DIM; i++) begin
            expected_data_vector[i]  = expected_data[i];
            expected_write_vector[i] = expected_write[i];
        end

        reset_dut();


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

        repeat (2) @(posedge clk);
        #1;


        /*
         * ----------------------------------------
         * Test 2: Initial activation read
         * ----------------------------------------
         */
        $display("");
        $display("========================================");
        $display("Test 2: BRAM activation transaction");
        $display("========================================");

        issue_data_request(TEST_KT);
        check_data_output(
            "DATA",
            expected_data_vector
        );

        repeat (2) @(posedge clk);
        #1;


        /*
         * ----------------------------------------
         * Test 3: Write transaction
         * ----------------------------------------
         */
        $display("");
        $display("========================================");
        $display("Test 3: BRAM write transaction");
        $display("========================================");

        issue_write_request();
        wait_for_write_done();
        check_write_done_width();

        repeat (1) @(posedge clk);
        #1;


        /*
         * ----------------------------------------
         * Test 4: Write-read-back
         *
         * write_nt=3으로 썼으므로
         * data read에서는 kt=3으로 읽는다.
         * ----------------------------------------
         */
        $display("");
        $display("========================================");
        $display("Test 4: BRAM write-read-back");
        $display("========================================");

        issue_data_request(WRITE_TILE);
        check_data_output(
            "READBACK",
            expected_write_vector
        );


        /*
         * ----------------------------------------
         * Final result
         * ----------------------------------------
         */
        $display("");

        if (error_count == 0) begin
            $display("========================================");
            $display("[TEST PASS] BRAM read/write controller passed");
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
        repeat (1500) @(posedge clk);

        $fatal(
            1,
            "[GLOBAL TIMEOUT] simulation did not finish"
        );
    end

endmodule