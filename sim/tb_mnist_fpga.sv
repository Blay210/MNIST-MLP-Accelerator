`timescale 1ns/1ps

module tb_mnist_fpga;

    import mnist_pkg::*;

    // ============================================================
    // Parameters
    // ============================================================

    localparam int CLK_PERIOD = 10;

    localparam int K1 = 784;
    localparam int N1 = 128;

    localparam int K2 = 128;
    localparam int N2 = 10;

    localparam int W1_SIZE = K1 * N1;
    localparam int W2_SIZE = K2 * N2;

    localparam int WORD_BYTES = 4;

    localparam int W1_WORDS_PER_ROW =
        (N1 + WORD_BYTES - 1) / WORD_BYTES;

    localparam int W2_WORDS_PER_ROW =
        (N2 + WORD_BYTES - 1) / WORD_BYTES;

    localparam int WEIGHT_DEPTH =
        K1 * W1_WORDS_PER_ROW;

    localparam int ACTIVATION_DEPTH =
        (K1 + WORD_BYTES - 1) / WORD_BYTES;


    // ============================================================
    // Layer configuration
    // ============================================================

    localparam logic [6:0] L1_K_IDX_MAX = 7'd97;
    localparam logic [3:0] L1_N_IDX_MAX = 4'd15;
    localparam logic [9:0] L1_K_TOTAL   = 10'd784;
    localparam logic [7:0] L1_N_TOTAL   = 8'd128;
    localparam logic [4:0] L1_SHIFT     = 5'd11;
    localparam logic       L1_RELU      = 1'b1;

    localparam logic [6:0] L2_K_IDX_MAX = 7'd15;
    localparam logic [3:0] L2_N_IDX_MAX = 4'd1;
    localparam logic [9:0] L2_K_TOTAL   = 10'd128;
    localparam logic [7:0] L2_N_TOTAL   = 8'd10;
    localparam logic [4:0] L2_SHIFT     = 5'd7;
    localparam logic       L2_RELU      = 1'b0;


    // ============================================================
    // DUT signals
    // ============================================================

    logic clk;
    logic rst_n;

    logic start;
    logic done;

    logic [6:0] k_idx_max;
    logic [3:0] n_idx_max;
    logic [9:0] k_total;
    logic [7:0] n_total;

    logic       relu_en;
    logic [4:0] shift_amount;


    // ============================================================
    // Accelerator <-> Weight BRAM
    // ============================================================

    logic        w_en;
    logic [31:0] w_addr;
    word_t       w_rdata;


    // ============================================================
    // Host <-> Weight BRAM
    // ============================================================

    logic        w_host_en;
    logic [3:0]  w_host_we;
    logic [31:0] w_host_addr;
    word_t       w_host_wdata;
    word_t       w_host_rdata;


    // ============================================================
    // Accelerator <-> Activation BRAM
    // ============================================================

    logic        m_en;
    logic [3:0]  m_wea;
    logic [31:0] m_addr;
    word_t       m_wdata;
    word_t       m_rdata;


    // ============================================================
    // Host <-> Activation BRAM
    // ============================================================

    logic        m_host_en;
    logic [3:0]  m_host_we;
    logic [31:0] m_host_addr;
    word_t       m_host_wdata;
    word_t       m_host_rdata;


    // ============================================================
    // Source byte arrays
    // ============================================================

    data_t input_image   [0:K1-1];

    data_t layer1_weight [0:W1_SIZE-1];
    data_t layer2_weight [0:W2_SIZE-1];

    data_t final_result  [0:N2-1];


    // ============================================================
    // Expected results
    // ============================================================

    integer expected_hidden [0:15];
    integer expected_final  [0:9];


    // ============================================================
    // Clock
    // ============================================================

    initial begin
        clk = 1'b0;

        forever #(CLK_PERIOD/2)
            clk = ~clk;
    end


    // ============================================================
    // DUT
    // ============================================================

    mnist_accelerator dut (
        .clk          (clk),
        .rst_n        (rst_n),

        .start        (start),

        .relu_en      (relu_en),
        .k_idx_max    (k_idx_max),
        .n_idx_max    (n_idx_max),
        .n_total      (n_total),
        .k_total      (k_total),
        .shift_amount (shift_amount),

        .done         (done),

        // Weight BRAM
        .w_en         (w_en),
        .w_addr       (w_addr),
        .w_rdata      (w_rdata),

        // Activation BRAM
        .m_en         (m_en),
        .m_wea        (m_wea),
        .m_addr       (m_addr),
        .m_wdata      (m_wdata),
        .m_rdata      (m_rdata)
    );


    // ============================================================
    // Weight BRAM
    // ============================================================

    weight_bram_model #(
        .DEPTH(WEIGHT_DEPTH)
    ) u_weight_bram (
        .clk     (clk),

        .a_en    (w_en),
        .a_addr  (w_addr),
        .a_rdata (w_rdata),

        .b_en    (w_host_en),
        .b_we    (w_host_we),
        .b_addr  (w_host_addr),
        .b_wdata (w_host_wdata),
        .b_rdata (w_host_rdata)
    );


    // ============================================================
    // Activation BRAM
    // ============================================================

    activation_bram_model #(
        .DEPTH(ACTIVATION_DEPTH)
    ) u_activation_bram (
        .clk     (clk),

        .a_en    (m_en),
        .a_we    (m_wea),
        .a_addr  (m_addr),
        .a_wdata (m_wdata),
        .a_rdata (m_rdata),

        .b_en    (m_host_en),
        .b_we    (m_host_we),
        .b_addr  (m_host_addr),
        .b_wdata (m_host_wdata),
        .b_rdata (m_host_rdata)
    );


    // ============================================================
    // Pack 4 int8 values -> one 32-bit word
    // ============================================================

    function automatic word_t pack4(
        input data_t b0,
        input data_t b1,
        input data_t b2,
        input data_t b3
    );

        word_t temp;

        begin
            temp = '0;

            temp[7:0]   = b0;
            temp[15:8]  = b1;
            temp[23:16] = b2;
            temp[31:24] = b3;

            return temp;
        end

    endfunction


    // ============================================================
    // Host Weight BRAM word write
    // addr = BYTE ADDRESS
    // ============================================================

    task automatic write_weight_word(
        input int    byte_addr,
        input word_t value
    );

        begin

            @(negedge clk);

            w_host_en    = 1'b1;
            w_host_we    = 4'b1111;
            w_host_addr  = byte_addr;
            w_host_wdata = value;

            @(negedge clk);

            w_host_en    = 1'b0;
            w_host_we    = 4'b0000;
            w_host_addr  = '0;
            w_host_wdata = '0;

        end

    endtask


    // ============================================================
    // Host Activation BRAM word write
    // ============================================================

    task automatic write_activation_word(
        input int    byte_addr,
        input word_t value
    );

        begin

            @(negedge clk);

            m_host_en    = 1'b1;
            m_host_we    = 4'b1111;
            m_host_addr  = byte_addr;
            m_host_wdata = value;

            @(negedge clk);

            m_host_en    = 1'b0;
            m_host_we    = 4'b0000;
            m_host_addr  = '0;
            m_host_wdata = '0;

        end

    endtask


    // ============================================================
    // Host Activation BRAM word read
    // ============================================================

    task automatic read_activation_word(
        input  int    byte_addr,
        output word_t value
    );

        begin

            @(negedge clk);

            m_host_en   = 1'b1;
            m_host_we   = 4'b0000;
            m_host_addr = byte_addr;

            @(posedge clk);
            #1;

            value = m_host_rdata;

            @(negedge clk);

            m_host_en   = 1'b0;
            m_host_addr = '0;

        end

    endtask


    // ============================================================
    // Read one activation BYTE
    // ============================================================

    task automatic read_activation_byte(
        input  int    byte_index,
        output data_t value
    );

        word_t temp;
        int word_index;
        int byte_lane;

        begin

            word_index = byte_index / WORD_BYTES;
            byte_lane  = byte_index % WORD_BYTES;

            read_activation_word(
                word_index * WORD_BYTES,
                temp
            );

            value = temp[byte_lane*8 +: 8];

        end

    endtask


    // ============================================================
    // Load input image
    // ============================================================

    task automatic load_input_image;

        word_t temp;

        begin

            $display("[TB] Loading input image...");

            for (int i = 0; i < K1; i += WORD_BYTES) begin

                temp = pack4(
                    input_image[i+0],
                    input_image[i+1],
                    input_image[i+2],
                    input_image[i+3]
                );

                write_activation_word(
                    i,
                    temp
                );

            end

            $display("[TB] Input image loaded.");

        end

    endtask


    // ============================================================
    // Load Layer 1 weight
    //
    // N1=128 -> exactly 32 words per row
    // ============================================================

    task automatic load_layer1_weights;

        word_t temp;
        int src_idx;
        int word_idx;

        begin

            $display("[TB] Loading Layer 1 weights...");

            for (int k = 0; k < K1; k++) begin

                for (int w = 0; w < W1_WORDS_PER_ROW; w++) begin

                    src_idx =
                        k * N1
                        + w * WORD_BYTES;

                    temp = pack4(
                        layer1_weight[src_idx+0],
                        layer1_weight[src_idx+1],
                        layer1_weight[src_idx+2],
                        layer1_weight[src_idx+3]
                    );

                    word_idx =
                        k * W1_WORDS_PER_ROW
                        + w;

                    write_weight_word(
                        word_idx * WORD_BYTES,
                        temp
                    );

                end
            end

            $display("[TB] Layer 1 weights loaded.");

        end

    endtask


    // ============================================================
    // Load Layer 2 weight
    //
    // N2 = 10
    //
    // row:
    //
    // word0 = W0 W1 W2 W3
    // word1 = W4 W5 W6 W7
    // word2 = W8 W9 00 00
    //
    // ============================================================

    task automatic load_layer2_weights;

        word_t temp;
        int src_idx;
        int word_idx;
        data_t b0, b1, b2, b3;

        begin

            $display("[TB] Loading Layer 2 weights...");

            for (int k = 0; k < K2; k++) begin

                for (int w = 0; w < W2_WORDS_PER_ROW; w++) begin

                    b0 = '0;
                    b1 = '0;
                    b2 = '0;
                    b3 = '0;

                    src_idx =
                        k * N2
                        + w * WORD_BYTES;

                    if (w*4 + 0 < N2)
                        b0 = layer2_weight[src_idx + 0];

                    if (w*4 + 1 < N2)
                        b1 = layer2_weight[src_idx + 1];

                    if (w*4 + 2 < N2)
                        b2 = layer2_weight[src_idx + 2];

                    if (w*4 + 3 < N2)
                        b3 = layer2_weight[src_idx + 3];

                    temp = pack4(
                        b0,
                        b1,
                        b2,
                        b3
                    );

                    word_idx =
                        k * W2_WORDS_PER_ROW
                        + w;

                    write_weight_word(
                        word_idx * WORD_BYTES,
                        temp
                    );

                end
            end

            $display("[TB] Layer 2 weights loaded.");

        end

    endtask


    // ============================================================
    // Run GEMM
    // ============================================================

    task automatic run_gemm(
        input logic [6:0] k_max,
        input logic [3:0] n_max,
        input logic [9:0] k_size,
        input logic [7:0] n_size,
        input logic       use_relu,
        input logic [4:0] shift
    );

        begin

            @(negedge clk);

            k_idx_max    = k_max;
            n_idx_max    = n_max;
            k_total      = k_size;
            n_total      = n_size;

            relu_en      = use_relu;
            shift_amount = shift;

            start = 1'b1;

            @(negedge clk);

            start = 1'b0;

            wait(done === 1'b1);

            $display(
                "[TB] GEMM done: K=%0d N=%0d",
                k_size,
                n_size
            );

            @(posedge clk);

        end

    endtask


    // ============================================================
    // Check Layer 1 first 16 outputs
    // ============================================================

    task automatic check_layer1;

        data_t value;
        int error_count;

        begin

            error_count = 0;

            $display("");
            $display("==============================");
            $display(" Layer 1 Check");
            $display("==============================");

            for (int i = 0; i < 16; i++) begin

                read_activation_byte(i, value);

                $display(
                    "hidden[%0d] = %0d (expected %0d)",
                    i,
                    $signed(value),
                    expected_hidden[i]
                );

                if ($signed(value) != expected_hidden[i]) begin
                    $error(
                        "[L1 FAIL] index=%0d got=%0d expected=%0d",
                        i,
                        $signed(value),
                        expected_hidden[i]
                    );

                    error_count++;
                end

            end

            if (error_count == 0)
                $display("[TB] Layer 1 first 16 : PASS");

        end

    endtask


    // ============================================================
    // Final result check
    // ============================================================

    task automatic check_final;

        int error_count;

        begin

            error_count = 0;

            $display("");
            $display("==============================");
            $display(" Final Output");
            $display("==============================");

            for (int i = 0; i < N2; i++) begin

                read_activation_byte(
                    i,
                    final_result[i]
                );

                $display(
                    "class[%0d] = %0d (expected %0d)",
                    i,
                    $signed(final_result[i]),
                    expected_final[i]
                );

                if ($signed(final_result[i]) !=
                    expected_final[i]) begin

                    $error(
                        "[FINAL FAIL] class=%0d got=%0d expected=%0d",
                        i,
                        $signed(final_result[i]),
                        expected_final[i]
                    );

                    error_count++;

                end

            end

            if (error_count == 0)
                $display("[TB] Final output : PASS");

        end

    endtask


    // ============================================================
    // Prediction
    // ============================================================

    task automatic print_prediction;

        integer max_idx;
        integer max_value;
        integer value;

        begin

            max_idx   = 0;
            max_value = $signed(final_result[0]);

            for (int i = 1; i < N2; i++) begin

                value = $signed(final_result[i]);

                if (value > max_value) begin
                    max_value = value;
                    max_idx   = i;
                end

            end

            $display("");
            $display("==============================");
            $display(" Prediction = %0d", max_idx);
            $display(" Score      = %0d", max_value);
            $display("==============================");

            if (max_idx != 7)
                $error("[TB] Prediction FAIL");

            else
                $display("[TB] Prediction PASS");

        end

    endtask


    // ============================================================
    // Main
    // ============================================================

    initial begin

        // --------------------------------------------------------
        // Expected values
        // --------------------------------------------------------

        expected_hidden[0]  = 6;
        expected_hidden[1]  = 0;
        expected_hidden[2]  = 0;
        expected_hidden[3]  = 13;
        expected_hidden[4]  = 2;
        expected_hidden[5]  = 12;
        expected_hidden[6]  = 0;
        expected_hidden[7]  = 22;
        expected_hidden[8]  = 0;
        expected_hidden[9]  = 12;
        expected_hidden[10] = 6;
        expected_hidden[11] = 10;
        expected_hidden[12] = 13;
        expected_hidden[13] = 34;
        expected_hidden[14] = 5;
        expected_hidden[15] = 21;

        expected_final[0] = -62;
        expected_final[1] = -108;
        expected_final[2] = 6;
        expected_final[3] = 25;
        expected_final[4] = -105;
        expected_final[5] = -56;
        expected_final[6] = -128;
        expected_final[7] = 89;
        expected_final[8] = -28;
        expected_final[9] = -28;


        // --------------------------------------------------------
        // Initial values
        // --------------------------------------------------------

        rst_n        = 1'b0;

        start        = 1'b0;

        k_idx_max    = '0;
        n_idx_max    = '0;
        k_total      = '0;
        n_total      = '0;

        relu_en      = 1'b0;
        shift_amount = '0;


        w_host_en    = 1'b0;
        w_host_we    = '0;
        w_host_addr  = '0;
        w_host_wdata = '0;


        m_host_en    = 1'b0;
        m_host_we    = '0;
        m_host_addr  = '0;
        m_host_wdata = '0;


        // --------------------------------------------------------
        // Load byte-form source memories
        // --------------------------------------------------------

        $readmemh(
            "./rtl/memory/reference_input.mem",
            input_image
        );

        $readmemh(
            "./rtl/memory/layer1_weight.mem",
            layer1_weight
        );

        $readmemh(
            "./rtl/memory/layer2_weight.mem",
            layer2_weight
        );


        // --------------------------------------------------------
        // Reset
        // --------------------------------------------------------

        repeat (5)
            @(posedge clk);

        @(negedge clk);
        rst_n = 1'b1;

        repeat (2)
            @(posedge clk);


        // ========================================================
        // Load input + layer1 weights
        // ========================================================

        load_input_image();
        load_layer1_weights();


        // ========================================================
        // Layer 1
        // ========================================================

        $display("");
        $display("====================================");
        $display(" Starting Layer 1 : 784 -> 128");
        $display("====================================");

        run_gemm(
            L1_K_IDX_MAX,
            L1_N_IDX_MAX,
            L1_K_TOTAL,
            L1_N_TOTAL,
            L1_RELU,
            L1_SHIFT
        );

        check_layer1();


        // ========================================================
        // Replace weight BRAM with Layer 2 weights
        // ========================================================

        load_layer2_weights();


        // ========================================================
        // Layer 2
        // ========================================================

        $display("");
        $display("====================================");
        $display(" Starting Layer 2 : 128 -> 10");
        $display("====================================");

        run_gemm(
            L2_K_IDX_MAX,
            L2_N_IDX_MAX,
            L2_K_TOTAL,
            L2_N_TOTAL,
            L2_RELU,
            L2_SHIFT
        );


        // ========================================================
        // Result
        // ========================================================

        check_final();

        print_prediction();


        repeat (10)
            @(posedge clk);

        $finish;

    end


    // ============================================================
    // Timeout
    // ============================================================

    initial begin

        #50_000_000;

        $error("[TB] TIMEOUT");
        $finish;

    end

endmodule
