`timescale 1ns/1ps

module tb_systolic_array;

    import mnist_pkg::*;

    localparam int CLK_PERIOD = 10;

    logic clk;
    logic rst_n;

    logic load_weight;
    logic start_calc;

    data_vec_t data_in;
    acc_vec_t  data_out;

    logic done;

    data_t weight_matrix [0:PE_DIM-1][0:PE_DIM-1];
    data_t activation    [0:PE_DIM-1];
    acc_t  expected      [0:PE_DIM-1];

    systolic_array dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .load_weight (load_weight),
        .start_calc  (start_calc),
        .data_in     (data_in),
        .data_out    (data_out),
        .done        (done)
    );

    /*
     * Clock generation
     */
    initial begin
        clk = 1'b0;

        forever #(CLK_PERIOD / 2)
            clk = ~clk;
    end

    /*
     * Reset task
     */
    task automatic reset_dut;
        begin
            rst_n       = 1'b0;
            load_weight = 1'b0;
            start_calc  = 1'b0;
            data_in     = '{default:'0};

            repeat (3) @(posedge clk);

            rst_n = 1'b1;

            @(posedge clk);
        end
    endtask

    /*
     * Weight 입력
     *
     * BRAM controller와 동일하게:
     * column 7 -> column 6 -> ... -> column 0
     * 순서로 전달한다.
     */
    task automatic load_weight_tile;
        begin
            // 1. LOAD 상태 진입 요청
            @(negedge clk);
            load_weight = 1'b1;
            data_in     = '{default:'0};

            @(posedge clk);
            @(negedge clk);

            load_weight = 1'b0;

            // 이 시점부터 DUT는 SYS_LOAD 상태
            // 2. col7 → col0 순서로 정확히 8 cycle 공급
            for (int col = PE_DIM-1; col >= 0; col--) begin
                for (int row = 0; row < PE_DIM; row++) begin
                    data_in[row] = weight_matrix[row][col];
                end

                @(posedge clk);
                @(negedge clk);
            end

            data_in = '{default:'0};
        end
    endtask

    /*
     * Activation 전달 및 계산 시작
     *
     * 현재 구조에서는 systolic array가 SYS_CALC 진입 후
     * activation을 내부 buffer에 저장하므로, activation 값을
     * 최소한 CALC 진입 이후 첫 clock까지 유지한다.
     */
    task automatic start_calculation;
        begin
            // CALC 상태 진입 요청
            @(negedge clk);
            start_calc = 1'b1;
            data_in     = '{default:'0};

            @(posedge clk);
            @(negedge clk);

            start_calc = 1'b0;

            // 이제 SYS_CALC 상태에서 activation 제공
            for (int i = 0; i < PE_DIM; i++) begin
                data_in[i] = activation[i];
            end

            // input_control_unit가 cnt==0일 때 저장
            @(posedge clk);
            @(negedge clk);

            data_in = '{default:'0};
        end
    endtask

    /*
     * Software reference 계산
     *
     * expected[j] =
     *     sum_i activation[i] * weight_matrix[i][j]
     */
    task automatic calculate_expected;
        acc_t sum;

        begin
            for (int col = 0; col < PE_DIM; col++) begin
                sum = '0;

                for (int row = 0; row < PE_DIM; row++) begin
                    sum += activation[row]
                         * weight_matrix[row][col];
                end

                expected[col] = sum;
            end
        end
    endtask

    /*
     * done 대기
     */
    task automatic wait_for_done;
        int timeout;

        begin
            timeout = 0;

            while (!done && timeout < 100) begin
                @(posedge clk);
                timeout++;
            end

            if (timeout >= 100) begin
                $fatal(1, "[TIMEOUT] done was not asserted");
            end

            /*
             * done과 data_out 갱신의 NBA timing을 고려해
             * 한 clock 뒤 비교
             */
            @(posedge clk);
            #1;
        end
    endtask

    /*
     * 결과 비교
     */
    task automatic check_result(
        input string test_name
    );
        int error_count;

        begin
            error_count = 0;

            $display("");
            $display("========================================");
            $display("Test: %s", test_name);
            $display("========================================");

            for (int i = 0; i < PE_DIM; i++) begin
                if ($signed(data_out[i]) !==
                    $signed(expected[i])) begin

                    $error(
                        "[FAIL] output[%0d] = %0d, expected = %0d",
                        i,
                        $signed(data_out[i]),
                        $signed(expected[i])
                    );

                    error_count++;
                end
                else begin
                    $display(
                        "[PASS] output[%0d] = %0d",
                        i,
                        $signed(data_out[i])
                    );
                end
            end

            if (error_count == 0) begin
                $display("[TEST PASS] %s", test_name);
            end
            else begin
                $fatal(
                    1,
                    "[TEST FAIL] %s: %0d mismatches",
                    test_name,
                    error_count
                );
            end
        end
    endtask

    /*
     * Identity matrix test 설정
     */
    task automatic setup_identity_test;
        begin
            weight_matrix = '{default: '{default: '0}};;
            activation    = '{default:'0};
            expected      = '{default:'0};

            for (int i = 0; i < PE_DIM; i++) begin
                weight_matrix[i][i] = data_t'(1);
                activation[i]       = data_t'(i + 1);
            end

            calculate_expected();
        end
    endtask

    /*
     * Waveform 및 test sequence
     */
    initial begin
        $dumpfile("wave.fst");
        $dumpvars(0, tb_systolic_array);

        reset_dut();

        /*
         * Test 1
         *
         * Activation:
         * [1 2 3 4 5 6 7 8]
         *
         * Weight:
         * Identity matrix
         *
         * Expected:
         * [1 2 3 4 5 6 7 8]
         */
        setup_identity_test();

        load_weight_tile();
        start_calculation();
        wait_for_done();
        check_result("8x8 identity matrix");

        $display("");
        $display("All tests completed successfully.");

        repeat (3) @(posedge clk);
        $finish;
    end

    /*
     * Global timeout
     */
    initial begin
        repeat (300) @(posedge clk);

        $fatal(1, "[GLOBAL TIMEOUT] Simulation did not finish");
    end

endmodule