`timescale 1ns / 1ps

module tb_requantizer;

    import mnist_pkg::*;

    localparam int CLK_PERIOD = 10;
    localparam int ACC_WIDTH  = 32;

    logic clk;

    acc_vec_t  acc_in;
    logic [$clog2(ACC_WIDTH)-1:0] shift_amount;
    logic relu_en;

    data_vec_t data_out;

    data_vec_t expected;

    int error_count;


    requantizer dut (
        .acc_in       (acc_in),
        .shift_amount (shift_amount),
        .relu_en      (relu_en),
        .data_out     (data_out)
    );


    /*
     * Clock
     *
     * requantizer 자체는 조합회로지만,
     * TB 입력/검사 타이밍을 기존 스타일과 맞추기 위해 사용한다.
     */
    initial begin
        clk = 1'b0;

        forever #(CLK_PERIOD / 2)
            clk = ~clk;
    end


    initial begin
        $dumpfile("wave.fst");
        $dumpvars(0, tb_requantizer);
    end


    /*
     * 한 테스트 벡터 적용 및 확인
     *
     * negedge:
     *   입력 적용
     *
     * 다음 posedge + #1:
     *   조합 출력 검사
     */
    task automatic run_test(
        input string test_name,
        input logic [$clog2(ACC_WIDTH)-1:0] test_shift,
        input logic test_relu
    );
        begin
            @(negedge clk);

            shift_amount = test_shift;
            relu_en      = test_relu;

            @(posedge clk);
            #1;

            $display("");
            $display("========================================");
            $display("%s", test_name);
            $display("shift_amount = %0d, relu_en = %0d",
                     shift_amount, relu_en);
            $display("========================================");

            for (int i = 0; i < PE_DIM; i++) begin
                if ($signed(data_out[i]) !==
                    $signed(expected[i])) begin

                    $error(
                        "[FAIL] lane=%0d acc_in=%0d actual=%0d expected=%0d",
                        i,
                        $signed(acc_in[i]),
                        $signed(data_out[i]),
                        $signed(expected[i])
                    );

                    error_count++;
                end
                else begin
                    $display(
                        "[PASS] lane=%0d acc_in=%0d output=%0d",
                        i,
                        $signed(acc_in[i]),
                        $signed(data_out[i])
                    );
                end
            end
        end
    endtask


    initial begin
        error_count = 0;

        acc_in       = '{default:'0};
        expected     = '{default:'0};
        shift_amount = '0;
        relu_en      = 1'b0;

        repeat (2) @(posedge clk);


        /*
         * Test 1
         * shift=0, ReLU off
         *
         * 정상 범위와 saturation 확인
         */
        @(negedge clk);

        acc_in[0] = acc_t'(0);
        acc_in[1] = acc_t'(50);
        acc_in[2] = acc_t'(-50);
        acc_in[3] = acc_t'(127);
        acc_in[4] = acc_t'(-128);
        acc_in[5] = acc_t'(128);
        acc_in[6] = acc_t'(-129);
        acc_in[7] = acc_t'(1000);

        expected[0] = data_t'(0);
        expected[1] = data_t'(50);
        expected[2] = data_t'(-50);
        expected[3] = data_t'(127);
        expected[4] = data_t'(-128);
        expected[5] = data_t'(127);
        expected[6] = data_t'(-128);
        expected[7] = data_t'(127);

        run_test(
            "Test 1: shift=0, ReLU off, saturation",
            0,
            1'b0
        );


        /*
         * Test 2
         * shift=8, ReLU off
         *
         * arithmetic right shift 확인
         */
        @(negedge clk);

        acc_in[0] = acc_t'(2560);     // 10
        acc_in[1] = acc_t'(-2560);    // -10
        acc_in[2] = acc_t'(32512);    // 127
        acc_in[3] = acc_t'(32768);    // 128 -> 127 saturation
        acc_in[4] = acc_t'(-32768);   // -128
        acc_in[5] = acc_t'(-33024);   // -129 -> -128 saturation
        acc_in[6] = acc_t'(383);      // 1
        acc_in[7] = acc_t'(-383);     // -2, arithmetic shift

        expected[0] = data_t'(10);
        expected[1] = data_t'(-10);
        expected[2] = data_t'(127);
        expected[3] = data_t'(127);
        expected[4] = data_t'(-128);
        expected[5] = data_t'(-128);
        expected[6] = data_t'(1);
        expected[7] = data_t'(-2);

        run_test(
            "Test 2: shift=8, ReLU off",
            8,
            1'b0
        );


        /*
         * Test 3
         * shift=8, ReLU on
         *
         * 음수 결과가 모두 0이 되는지 확인
         */
        @(negedge clk);

        acc_in[0] = acc_t'(2560);     // 10
        acc_in[1] = acc_t'(-2560);    // -10 -> 0
        acc_in[2] = acc_t'(32768);    // 128 -> 127
        acc_in[3] = acc_t'(-32768);   // -128 -> 0
        acc_in[4] = acc_t'(0);        // 0
        acc_in[5] = acc_t'(100000);   // 390 -> 127
        acc_in[6] = acc_t'(-1);       // -1 >>> 8 = -1 -> 0
        acc_in[7] = acc_t'(255);      // 0

        expected[0] = data_t'(10);
        expected[1] = data_t'(0);
        expected[2] = data_t'(127);
        expected[3] = data_t'(0);
        expected[4] = data_t'(0);
        expected[5] = data_t'(127);
        expected[6] = data_t'(0);
        expected[7] = data_t'(0);

        run_test(
            "Test 3: shift=8, ReLU on",
            8,
            1'b1
        );


        /*
         * Test 4
         * shift=4
         *
         * 다른 shift 값에서도 정상 동작 확인
         */
        @(negedge clk);

        acc_in[0] = acc_t'(160);      // 10
        acc_in[1] = acc_t'(-160);     // -10
        acc_in[2] = acc_t'(2032);     // 127
        acc_in[3] = acc_t'(2048);     // 128 -> 127
        acc_in[4] = acc_t'(-2048);    // -128
        acc_in[5] = acc_t'(-2064);    // -129 -> -128
        acc_in[6] = acc_t'(31);       // 1
        acc_in[7] = acc_t'(-31);      // -2

        expected[0] = data_t'(10);
        expected[1] = data_t'(-10);
        expected[2] = data_t'(127);
        expected[3] = data_t'(127);
        expected[4] = data_t'(-128);
        expected[5] = data_t'(-128);
        expected[6] = data_t'(1);
        expected[7] = data_t'(-2);

        run_test(
            "Test 4: shift=4, ReLU off",
            4,
            1'b0
        );


        $display("");

        if (error_count == 0) begin
            $display("========================================");
            $display("[TEST PASS] Requantizer passed");
            $display("========================================");
        end
        else begin
            $fatal(
                1,
                "[TEST FAIL] Requantizer: %0d errors",
                error_count
            );
        end

        repeat (2) @(posedge clk);
        $finish;
    end


    initial begin
        repeat (100) @(posedge clk);

        $fatal(
            1,
            "[GLOBAL TIMEOUT] simulation did not finish"
        );
    end

endmodule