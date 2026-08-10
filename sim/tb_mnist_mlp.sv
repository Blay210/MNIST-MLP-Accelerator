`timescale 1ns / 1ps

module tb_mnist_mlp;

    import mnist_pkg::*;

    localparam int CLK_PERIOD = 10;

    /*
     * Layer 1은 총 98 × 16 = 1568 tile이다.
     * 충분히 넉넉하게 설정한다.
     */
    localparam int TIMEOUT_CYCLES = 500_000;

    localparam int INPUT_SIZE  = 784;
    localparam int HIDDEN_SIZE = 128;
    localparam int OUTPUT_SIZE = 10;

    /*
     * Layer 1:
     * 784 / 8 = 98 K tiles → 마지막 index 97
     * 128 / 8 = 16 N tiles → 마지막 index 15
     */
    localparam logic [6:0] L1_K_IDX_MAX = 7'd97;
    localparam logic [3:0] L1_N_IDX_MAX = 4'd15;
    localparam logic [7:0] L1_N_TOTAL   = 8'd128;
    localparam logic [4:0] L1_SHIFT     = 5'd11;

    /*
     * Layer 2:
     * 128 / 8 = 16 K tiles → 마지막 index 15
     * ceil(10 / 8) = 2 N tiles → 마지막 index 1
     */
    localparam logic [6:0] L2_K_IDX_MAX = 7'd15;
    localparam logic [3:0] L2_N_IDX_MAX = 4'd1;
    localparam logic [7:0] L2_N_TOTAL   = 8'd10;
    localparam logic [4:0] L2_SHIFT     = 5'd7;

    logic clk;
    logic rst_n;
    logic start;

    logic [6:0] k_idx_max;
    logic [3:0] n_idx_max;
    logic [7:0] n_total;

    logic       relu_en;
    logic [4:0] shift_amount;

    logic done;

    /*
     * Reference data
     */
    data_t reference_input         [0:INPUT_SIZE-1];
    data_t reference_layer1_output [0:HIDDEN_SIZE-1];
    data_t reference_final_output  [0:OUTPUT_SIZE-1];

    int error_count;
    int layer1_done_count;
    int layer2_done_count;


    mnist_accelerator dut (
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
        $dumpvars(0, tb_mnist_mlp);
    end


    /*
     * Reference 파일 로드
     */
    task automatic load_reference_files;
        begin
            $readmemh(
                "./rtl/memory/reference_input.mem",
                reference_input
            );

            $readmemh(
                "./rtl/memory/reference_layer1_output.mem",
                reference_layer1_output
            );

            $readmemh(
                "./rtl/memory/reference_final_output.mem",
                reference_final_output
            );

            $display(
                "[LOAD] Reference files loaded"
            );
        end
    endtask


    /*
     * DUT reset
     */
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


    /*
     * 첫 번째 MNIST 입력을 activation memory에 로드
     */
    task automatic load_input_memory;
        begin
            for (int i = 0; i < INPUT_SIZE; i++) begin
                dut.u_bram_controller.m_mem[i]
                    = reference_input[i];
            end

            $display(
                "[LOAD] MNIST input loaded into m_mem"
            );
        end
    endtask


    /*
     * Layer 1 weight 로드
     */
    task automatic load_layer1_weights;
        begin
            $readmemh(
                "./rtl/memory/layer1_weight.mem",
                dut.u_bram_controller.w_mem
            );

            $display(
                "[LOAD] Layer 1 weights loaded"
            );
        end
    endtask


    /*
     * Layer 2 weight 로드
     *
     * Layer 1이 완전히 끝나고 accelerator가 IDLE인 상태에서
     * weight memory를 교체한다.
     */
    task automatic load_layer2_weights;
        begin
            $readmemh(
                "./rtl/memory/layer2_weight.mem",
                dut.u_bram_controller.w_mem
            );

            $display(
                "[LOAD] Layer 2 weights loaded"
            );
        end
    endtask


    /*
     * GEMM 시작
     */
    task automatic start_gemm(
        input logic [6:0] task_k_idx_max,
        input logic [3:0] task_n_idx_max,
        input logic [7:0] task_n_total,
        input logic       task_relu_en,
        input logic [4:0] task_shift
    );
        begin
            /*
             * TB 입력은 negedge에서 변경한다.
             */
            @(negedge clk);

            k_idx_max    = task_k_idx_max;
            n_idx_max    = task_n_idx_max;
            n_total      = task_n_total;
            relu_en      = task_relu_en;
            shift_amount = task_shift;

            start = 1'b1;

            /*
             * 정확히 한 클럭 pulse
             */
            @(negedge clk);

            start = 1'b0;

            /*
             * 설정값이 내부에 latch됐는지 검증하기 위해
             * 외부 값을 poison한다.
             */
            k_idx_max    = '1;
            n_idx_max    = '1;
            n_total      = '1;
            relu_en      = ~task_relu_en;
            shift_amount = '0;
        end
    endtask


    /*
     * done 대기
     */
    task automatic wait_for_done(
        input string layer_name
    );
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
                    "[TIMEOUT] %s did not finish",
                    layer_name
                );
            end

            $display(
                "[DONE] %s finished at time %0t, cycles=%0d",
                layer_name,
                $time,
                timeout
            );

            /*
             * done monitor 및 NBA와의 race 방지
             */
            @(negedge clk);
        end
    endtask


    /*
     * Layer 1 결과 확인
     *
     * commit 후 m_mem[0:127]에 hidden activation이 들어 있다.
     */
    task automatic check_layer1_output;
        int before_error;

        begin
            before_error = error_count;

            $display("");
            $display("========================================");
            $display("Checking Layer 1 output");
            $display("========================================");

            for (int i = 0; i < HIDDEN_SIZE; i++) begin
                if (
                    $signed(
                        dut.u_bram_controller.m_mem[i]
                    )
                    !==
                    $signed(
                        reference_layer1_output[i]
                    )
                ) begin
                    $display(
                        "[L1 FAIL] index=%0d actual=%0d expected=%0d",
                        i,
                        $signed(
                            dut.u_bram_controller.m_mem[i]
                        ),
                        $signed(
                            reference_layer1_output[i]
                        )
                    );

                    error_count++;
                end
            end

            if (error_count == before_error) begin
                $display(
                    "[L1 PASS] all 128 hidden activations matched"
                );
            end
            else begin
                $display(
                    "[L1 FAIL] mismatch count=%0d",
                    error_count - before_error
                );
            end
        end
    endtask


    /*
     * Layer 2 최종 출력 확인
     */
    task automatic check_final_output;
        int before_error;

        begin
            before_error = error_count;

            $display("");
            $display("========================================");
            $display("Checking final output");
            $display("========================================");

            for (int i = 0; i < OUTPUT_SIZE; i++) begin
                if (
                    $signed(
                        dut.u_bram_controller.m_mem[i]
                    )
                    !==
                    $signed(
                        reference_final_output[i]
                    )
                ) begin
                    $display(
                        "[FINAL FAIL] class=%0d actual=%0d expected=%0d",
                        i,
                        $signed(
                            dut.u_bram_controller.m_mem[i]
                        ),
                        $signed(
                            reference_final_output[i]
                        )
                    );

                    error_count++;
                end
                else begin
                    $display(
                        "[FINAL PASS] class=%0d value=%0d",
                        i,
                        $signed(
                            dut.u_bram_controller.m_mem[i]
                        )
                    );
                end
            end

            if (error_count == before_error) begin
                $display(
                    "[FINAL PASS] all 10 logits matched"
                );
            end
        end
    endtask


    /*
     * Signed int8 argmax
     */
    task automatic check_prediction;
        int predicted_class;
        int signed max_value;
        int signed current_value;

        begin
            predicted_class = 0;
            max_value = $signed(
                dut.u_bram_controller.m_mem[0]
            );

            for (int i = 1; i < OUTPUT_SIZE; i++) begin
                current_value = $signed(
                    dut.u_bram_controller.m_mem[i]
                );

                if (current_value > max_value) begin
                    max_value = current_value;
                    predicted_class = i;
                end
            end

            $display("");
            $display("========================================");
            $display("Checking prediction");
            $display("========================================");

            $display(
                "Predicted class = %0d, max logit = %0d",
                predicted_class,
                max_value
            );

            if (predicted_class !== 7) begin
                $display(
                    "[PREDICTION FAIL] actual=%0d expected=7",
                    predicted_class
                );

                error_count++;
            end
            else begin
                $display(
                    "[PREDICTION PASS] predicted class = 7"
                );
            end
        end
    endtask


    /*
     * result_buffer가 commit 후 초기화됐는지 확인
     */
    task automatic check_result_buffer_cleared(
        input int valid_size,
        input string layer_name
    );
        int before_error;

        begin
            before_error = error_count;

            for (int i = 0; i < valid_size; i++) begin
                if (
                    $signed(
                        dut.u_bram_controller.result_buffer[i]
                    )
                    !== 0
                ) begin
                    $display(
                        "[BUFFER CLEAR FAIL] %s index=%0d value=%0d",
                        layer_name,
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
                    "[BUFFER CLEAR PASS] %s buffer cleared",
                    layer_name
                );
            end
        end
    endtask


    /*
     * start와 done pulse 확인
     */
    property p_start_one_cycle;
        @(posedge clk)
        disable iff (!rst_n)

        start |=> !start;
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
        error_count      = 0;
        layer1_done_count = 0;
        layer2_done_count = 0;

        /*
         * bram_controller 내부 initial $readmemh가 time 0에
         * 실행된 이후 테스트 데이터를 다시 로드한다.
         */
        #1;

        load_reference_files();

        reset_dut();

        /*
         * Reset은 memory array를 지우지 않지만,
         * 순서를 명확하게 하기 위해 reset 이후 로드한다.
         */
        load_input_memory();
        load_layer1_weights();


        $display("");
        $display("========================================");
        $display("MNIST MLP RTL integration test");
        $display("784 -> 128 -> 10");
        $display("Reference label: 7");
        $display("========================================");


        /*
         * Layer 1
         */
        $display("");
        $display("----------------------------------------");
        $display("Starting Layer 1: 784 x 128");
        $display("----------------------------------------");

        start_gemm(
            L1_K_IDX_MAX,
            L1_N_IDX_MAX,
            L1_N_TOTAL,
            1'b1,
            L1_SHIFT
        );

        wait_for_done("Layer 1");

        layer1_done_count++;

        check_layer1_output();
        check_result_buffer_cleared(
            HIDDEN_SIZE,
            "Layer 1"
        );


        /*
         * Layer 2 weight 교체
         */
        load_layer2_weights();

        /*
         * $readmemh 이후 delta-cycle 여유
         */
        #1;


        /*
         * Layer 2
         */
        $display("");
        $display("----------------------------------------");
        $display("Starting Layer 2: 128 x 10");
        $display("----------------------------------------");

        start_gemm(
            L2_K_IDX_MAX,
            L2_N_IDX_MAX,
            L2_N_TOTAL,
            1'b0,
            L2_SHIFT
        );

        wait_for_done("Layer 2");

        layer2_done_count++;

        check_final_output();
        check_prediction();

        check_result_buffer_cleared(
            OUTPUT_SIZE,
            "Layer 2"
        );


        $display("");

        if (error_count == 0) begin
            $display("========================================");
            $display("[TEST PASS] MNIST MLP RTL test passed");
            $display("Layer 1 done count = %0d", layer1_done_count);
            $display("Layer 2 done count = %0d", layer2_done_count);
            $display("Prediction         = 7");
            $display("========================================");
        end
        else begin
            $fatal(
                1,
                "[TEST FAIL] MNIST MLP test: %0d errors",
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
        repeat (TIMEOUT_CYCLES * 2 + 1000)
            @(posedge clk);

        $fatal(
            1,
            "[GLOBAL TIMEOUT] simulation did not finish"
        );
    end

endmodule