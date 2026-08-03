`timescale 1ns/1ps

module tb_systolic_array;

    import mnist_pkg::*;

    localparam int CLK_PERIOD = 10;

    logic clk;
    logic rst_n;

    /*
     * Systolic array control
     */
    logic load_weight;
    logic start_calc;
    logic systolic_done;

    data_vec_t data_in;
    acc_vec_t  partial_result;

    /*
     * Accumulator control
     */
    logic save;
    logic acc_en;

    acc_vec_t accumulated_result;

    /*
     * Test data
     */
    data_t weight_matrix [0:PE_DIM-1][0:PE_DIM-1];
    data_t activation    [0:PE_DIM-1];

    acc_t expected_partial [0:PE_DIM-1];
    acc_t expected_acc     [0:PE_DIM-1];


    /*
     * DUT: systolic array
     */
    systolic_array u_systolic_array (
        .clk         (clk),
        .rst_n       (rst_n),

        .load_weight (load_weight),
        .start_calc  (start_calc),

        .data_in     (data_in),
        .data_out    (partial_result),

        .done        (systolic_done)
    );


    /*
     * DUT: accumulator
     */
    accumulator u_accumulator (
        .clk     (clk),
        .rst_n   (rst_n),

        .save    (save),
        .acc_en  (acc_en),

        .acc_in  (partial_result),
        .acc_out (accumulated_result)
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

            save        = 1'b0;
            acc_en      = 1'b0;

            data_in     = '{default:'0};

            repeat (3) @(posedge clk);

            rst_n = 1'b1;

            @(posedge clk);
        end
    endtask


    /*
     * Weight 입력
     *
     * 기존 systolic-array testbench와 동일한 timing.
     *
     * negedge:
     *   load_weight = 1
     *
     * 다음 negedge:
     *   load_weight = 0
     *   첫 번째 weight column 입력
     *
     * 이후 각 weight column을 1 cycle씩 유지.
     */
    task automatic load_weight_tile;
        begin
            /*
             * LOAD 상태 진입 요청
             */
            @(negedge clk);

            load_weight = 1'b1;
            data_in     = '{default:'0};


            /*
             * pulse를 정확히 1 clock 유지
             */
            @(posedge clk);
            @(negedge clk);

            load_weight = 1'b0;


            /*
             * col7 → col0 순서로 정확히 8 cycle 공급
             */
            for (
                int col = PE_DIM - 1;
                col >= 0;
                col--
            ) begin

                for (
                    int row = 0;
                    row < PE_DIM;
                    row++
                ) begin
                    data_in[row] =
                        weight_matrix[row][col];
                end

                /*
                 * 현재 weight column을 다음 posedge에서 샘플링.
                 * 이후 negedge까지 그대로 유지.
                 */
                @(posedge clk);
                @(negedge clk);
            end


            /*
             * 마지막 weight가 샘플링된 뒤 입력 제거
             */
            data_in = '{default:'0};
        end
    endtask


    /*
     * Activation 전달 및 계산 시작
     *
     * 기존 systolic-array testbench와 동일한 timing.
     */
    task automatic start_calculation;
        begin
            /*
             * CALC 상태 진입 요청
             */
            @(negedge clk);

            start_calc = 1'b1;
            data_in    = '{default:'0};


            /*
             * start_calc를 정확히 1 clock 유지
             */
            @(posedge clk);
            @(negedge clk);

            start_calc = 1'b0;


            /*
             * SYS_CALC 상태에서 activation 공급
             */
            for (int i = 0; i < PE_DIM; i++) begin
                data_in[i] = activation[i];
            end


            /*
             * input_control_unit가 CALC 첫 posedge에서 저장
             */
            @(posedge clk);
            @(negedge clk);


            /*
             * activation 입력 제거
             */
            data_in = '{default:'0};
        end
    endtask


    /*
     * Software reference:
     *
     * expected_partial[col]
     *     = sum(row)
     *       activation[row] * weight_matrix[row][col]
     */
    task automatic calculate_expected_partial;
        acc_t sum;

        begin
            for (int col = 0; col < PE_DIM; col++) begin
                sum = '0;

                for (int row = 0; row < PE_DIM; row++) begin
                    sum += activation[row]
                         * weight_matrix[row][col];
                end

                expected_partial[col] = sum;
            end
        end
    endtask


    /*
     * Systolic done 대기
     */
    task automatic wait_for_systolic_done;
        int timeout;

        begin
            timeout = 0;

            while (
                !systolic_done &&
                timeout < 100
            ) begin
                @(posedge clk);
                timeout++;
            end

            if (timeout >= 100) begin
                $fatal(
                    1,
                    "[TIMEOUT] systolic_done was not asserted"
                );
            end


            /*
             * systolic output update의 NBA timing 고려
             */
            @(posedge clk);
            #1;
        end
    endtask


    /*
     * Systolic partial result 확인
     */
    task automatic check_partial_result(
        input string test_name
    );
        int error_count;

        begin
            error_count = 0;

            $display("");
            $display("========================================");
            $display("Partial test: %s", test_name);
            $display("========================================");

            for (int i = 0; i < PE_DIM; i++) begin
                if (
                    $signed(partial_result[i]) !==
                    $signed(expected_partial[i])
                ) begin
                    $error(
                        "[PARTIAL FAIL] output[%0d] = %0d, expected = %0d",
                        i,
                        $signed(partial_result[i]),
                        $signed(expected_partial[i])
                    );

                    error_count++;
                end
                else begin
                    $display(
                        "[PARTIAL PASS] output[%0d] = %0d",
                        i,
                        $signed(partial_result[i])
                    );
                end
            end

            if (error_count == 0) begin
                $display(
                    "[PARTIAL TEST PASS] %s",
                    test_name
                );
            end
            else begin
                $fatal(
                    1,
                    "[PARTIAL TEST FAIL] %s: %0d mismatches",
                    test_name,
                    error_count
                );
            end
        end
    endtask


    /*
     * Accumulator 저장/누적
     *
     * 모든 제어 신호는 negedge에서 변경.
     *
     * first_tile = 1:
     *   save = 1
     *   acc_en = 1
     *   첫 partial을 accumulator에 저장
     *
     * first_tile = 0:
     *   save = 0
     *   acc_en = 1
     *   기존 값에 partial을 누적
     */
    task automatic accumulate_partial(
        input logic first_tile
    );
        begin
            /*
             * accumulator 입력은 이미 partial_result에 안정되어 있음.
             *
             * negedge에서 control 설정
             */
            @(negedge clk);

            save   = first_tile;
            acc_en = 1'b1;


            /*
             * 다음 posedge에서 accumulator가 partial_result 수신
             */
            @(posedge clk);
            #1;


            /*
             * 다음 negedge에서 control 제거
             */
            @(negedge clk);

            save   = 1'b0;
            acc_en = 1'b0;
        end
    endtask


    /*
     * Accumulator 결과 확인
     */
    task automatic check_accumulated_result(
        input string test_name
    );
        int error_count;

        begin
            error_count = 0;

            /*
             * 직전 posedge의 NBA update 안정화
             */
            #1;

            $display("");
            $display("========================================");
            $display("Accumulator test: %s", test_name);
            $display("========================================");

            for (int i = 0; i < PE_DIM; i++) begin
                if (
                    $signed(accumulated_result[i]) !==
                    $signed(expected_acc[i])
                ) begin
                    $error(
                        "[ACC FAIL] output[%0d] = %0d, expected = %0d",
                        i,
                        $signed(accumulated_result[i]),
                        $signed(expected_acc[i])
                    );

                    error_count++;
                end
                else begin
                    $display(
                        "[ACC PASS] output[%0d] = %0d",
                        i,
                        $signed(accumulated_result[i])
                    );
                end
            end

            if (error_count == 0) begin
                $display(
                    "[ACC TEST PASS] %s",
                    test_name
                );
            end
            else begin
                $fatal(
                    1,
                    "[ACC TEST FAIL] %s: %0d mismatches",
                    test_name,
                    error_count
                );
            end
        end
    endtask


    /*
     * Identity matrix 설정
     */
    task automatic setup_identity_weight;
        begin
            weight_matrix =
                '{default:'{default:'0}};

            for (int i = 0; i < PE_DIM; i++) begin
                weight_matrix[i][i] = data_t'(1);
            end
        end
    endtask


    /*
     * Tile 0 설정
     *
     * activation:
     * [1 2 3 4 5 6 7 8]
     *
     * weight:
     * identity
     *
     * partial:
     * [1 2 3 4 5 6 7 8]
     */
    task automatic setup_tile_0;
        begin
            setup_identity_weight();

            activation      = '{default:'0};
            expected_partial = '{default:'0};

            for (int i = 0; i < PE_DIM; i++) begin
                activation[i] =
                    data_t'(i + 1);
            end

            calculate_expected_partial();

            /*
             * 첫 tile이므로 accumulator expected 값은
             * partial result와 동일
             */
            for (int i = 0; i < PE_DIM; i++) begin
                expected_acc[i] =
                    expected_partial[i];
            end
        end
    endtask


    /*
     * Tile 1 설정
     *
     * activation:
     * [2 4 6 8 10 12 14 16]
     *
     * weight:
     * identity
     *
     * partial:
     * [2 4 6 8 10 12 14 16]
     *
     * 누적 결과:
     * [3 6 9 12 15 18 21 24]
     */
    task automatic setup_tile_1;
        begin
            setup_identity_weight();

            activation       = '{default:'0};
            expected_partial = '{default:'0};

            for (int i = 0; i < PE_DIM; i++) begin
                activation[i] =
                    data_t'(2 * (i + 1));
            end

            calculate_expected_partial();

            /*
             * 기존 expected accumulator에 두 번째 partial 추가
             */
            for (int i = 0; i < PE_DIM; i++) begin
                expected_acc[i] +=
                    expected_partial[i];
            end
        end
    endtask


    /*
     * 한 tile 실행
     */
    task automatic run_tile(
        input string tile_name,
        input logic  first_tile
    );
        begin
            load_weight_tile();

            start_calculation();

            wait_for_systolic_done();

            check_partial_result(tile_name);

            accumulate_partial(first_tile);
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
         * ----------------------------------------
         * Test 1: K-tile 0
         * ----------------------------------------
         */
        setup_tile_0();

        run_tile(
            "K-tile 0",
            1'b1
        );

        check_accumulated_result(
            "after K-tile 0"
        );


        /*
         * Systolic array가 SYS_IDLE로 돌아갈 시간을 확보
         */
        repeat (2) @(posedge clk);


        /*
         * ----------------------------------------
         * Test 2: K-tile 1
         * ----------------------------------------
         */
        setup_tile_1();

        run_tile(
            "K-tile 1",
            1'b0
        );

        check_accumulated_result(
            "after K-tile 1"
        );


        /*
         * 최종 결과
         */
        $display("");
        $display("========================================");
        $display("All systolic + accumulator tests passed");
        $display("========================================");

        repeat (3) @(posedge clk);
        $finish;
    end


    /*
     * Global timeout
     */
    initial begin
        repeat (600) @(posedge clk);

        $fatal(
            1,
            "[GLOBAL TIMEOUT] Simulation did not finish"
        );
    end

endmodule