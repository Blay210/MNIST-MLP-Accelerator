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

    // 기존 검증 TB에서 사용한 값으로 바꿀 것
    localparam logic [6:0] L1_K_IDX_MAX = 7'd97;
    localparam logic [3:0] L1_N_IDX_MAX = 4'd15;
    localparam logic [7:0] L1_N_TOTAL   = 8'd128;
    localparam logic [4:0] L1_SHIFT     = 5'd11;
    localparam logic       L1_RELU      = 1'b1;

    localparam logic [6:0] L2_K_IDX_MAX = 7'd15;
    localparam logic [3:0] L2_N_IDX_MAX = 4'd1;
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
    logic [7:0] n_total;

    logic       relu_en;
    logic [4:0] shift_amount;


    // ============================================================
    // Accelerator <-> Weight BRAM
    // ============================================================

    logic        w_en;
    logic [16:0] w_addr;
    data_t       w_rdata;


    // ============================================================
    // Host <-> Weight BRAM
    // ============================================================

    logic        w_host_en;
    logic        w_host_we;
    logic [16:0] w_host_addr;
    data_t       w_host_wdata;
    data_t       w_host_rdata;


    // ============================================================
    // Accelerator <-> Activation BRAM
    // ============================================================

    logic        m_en;
    logic        m_we;
    logic [9:0]  m_addr;
    data_t       m_wdata;
    data_t       m_rdata;


    // ============================================================
    // Host <-> Activation BRAM
    // ============================================================

    logic        m_host_en;
    logic        m_host_we;
    logic [9:0]  m_host_addr;
    data_t       m_host_wdata;
    data_t       m_host_rdata;


    // ============================================================
    // Simulation-side temporary memories
    //
    // $readmemh는 DUT memory가 아니라
    // TB의 임시 배열에만 사용한다.
    // 이후 실제 BRAM Port B를 통해 write한다.
    // ============================================================

    data_t input_image [0:K1-1];

    data_t layer1_weight [0:W1_SIZE-1];
    data_t layer2_weight [0:W2_SIZE-1];

    data_t final_result [0:N2-1];


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

        .k_idx_max    (k_idx_max),
        .n_idx_max    (n_idx_max),
        .n_total      (n_total),

        .relu_en      (relu_en),
        .shift_amount (shift_amount),

        .done         (done),

        // Weight BRAM
        .w_en         (w_en),
        .w_addr       (w_addr),
        .w_rdata      (w_rdata),

        // Activation BRAM
        .m_en         (m_en),
        .m_we         (m_we),
        .m_addr       (m_addr),
        .m_wdata      (m_wdata),
        .m_rdata      (m_rdata)
    );


    // ============================================================
    // Weight BRAM model
    // ============================================================

    weight_bram_model #(
        .DEPTH  (K1 * N1),
        .ADDR_W (17)
    ) u_weight_bram (
        .clk     (clk),

        // Accelerator Port A
        .a_en    (w_en),
        .a_addr  (w_addr),
        .a_rdata (w_rdata),

        // Host Port B
        .b_en    (w_host_en),
        .b_we    (w_host_we),
        .b_addr  (w_host_addr),
        .b_wdata (w_host_wdata),
        .b_rdata (w_host_rdata)
    );


    // ============================================================
    // Activation BRAM model
    // ============================================================

    activation_bram_model #(
        .DEPTH  (K1),
        .ADDR_W (10)
    ) u_activation_bram (
        .clk     (clk),

        // Accelerator Port A
        .a_en    (m_en),
        .a_we    (m_we),
        .a_addr  (m_addr),
        .a_wdata (m_wdata),
        .a_rdata (m_rdata),

        // Host Port B
        .b_en    (m_host_en),
        .b_we    (m_host_we),
        .b_addr  (m_host_addr),
        .b_wdata (m_host_wdata),
        .b_rdata (m_host_rdata)
    );


    // ============================================================
    // Host-side Weight BRAM write
    // ============================================================

    task automatic write_weight(
        input int    addr,
        input data_t value
    );
    begin

        @(negedge clk);

        w_host_en    = 1'b1;
        w_host_we    = 1'b1;
        w_host_addr  = addr[16:0];
        w_host_wdata = value;

        @(negedge clk);

        w_host_en    = 1'b0;
        w_host_we    = 1'b0;

    end
    endtask


    // ============================================================
    // Host-side Activation BRAM write
    // ============================================================

    task automatic write_activation(
        input int    addr,
        input data_t value
    );
    begin

        @(negedge clk);

        m_host_en    = 1'b1;
        m_host_we    = 1'b1;
        m_host_addr  = addr[9:0];
        m_host_wdata = value;

        @(negedge clk);

        m_host_en    = 1'b0;
        m_host_we    = 1'b0;

    end
    endtask


    // ============================================================
    // Host-side Activation BRAM read
    // ============================================================

    task automatic read_activation(
        input  int    addr,
        output data_t value
    );
    begin

        @(negedge clk);

        m_host_en   = 1'b1;
        m_host_we   = 1'b0;
        m_host_addr = addr[9:0];

        //
        // synchronous BRAM read
        //
        @(posedge clk);
        #1;

        value = m_host_rdata;

        @(negedge clk);

        m_host_en = 1'b0;

    end
    endtask


    // ============================================================
    // Load Layer 1 weights
    // ============================================================

    task automatic load_layer1_weights;
    begin

        $display("[TB] Loading Layer 1 weights...");

        for (int i = 0; i < W1_SIZE; i++) begin
            write_weight(i, layer1_weight[i]);
        end

        $display("[TB] Layer 1 weights loaded.");

    end
    endtask


    // ============================================================
    // Load Layer 2 weights
    // ============================================================

    task automatic load_layer2_weights;
    begin

        $display("[TB] Loading Layer 2 weights...");

        //
        // Layer2부터는 weight BRAM의 앞부분을 덮어쓴다.
        //
        for (int i = 0; i < W2_SIZE; i++) begin
            write_weight(i, layer2_weight[i]);
        end

        $display("[TB] Layer 2 weights loaded.");

    end
    endtask


    // ============================================================
    // Load MNIST image
    // ============================================================

    task automatic load_input_image;
    begin

        $display("[TB] Loading MNIST input image...");

        for (int i = 0; i < K1; i++) begin
            write_activation(i, input_image[i]);
        end

        $display("[TB] Input image loaded.");

    end
    endtask


    // ============================================================
    // Start GEMM
    // ============================================================

    task automatic run_gemm(
        input logic [6:0] k_max,
        input logic [3:0] n_max,
        input logic [7:0] n_size,
        input logic       use_relu,
        input logic [4:0] shift
    );
    begin

        @(negedge clk);

        k_idx_max    = k_max;
        n_idx_max    = n_max;
        n_total      = n_size;

        relu_en      = use_relu;
        shift_amount = shift;

        start = 1'b1;

        @(negedge clk);

        start = 1'b0;


        //
        // Accelerator completion
        //
        wait(done === 1'b1);

        $display(
            "[TB] GEMM done: k_idx_max=%0d n_idx_max=%0d n_total=%0d",
            k_max,
            n_max,
            n_size
        );

        //
        // done은 GEMM_DONE state 동안 1이므로
        // IDLE 복귀까지 기다린다.
        //
        @(posedge clk);

    end
    endtask


    // ============================================================
    // Read final 10 outputs
    // ============================================================

    task automatic read_final_result;
    begin

        $display("");
        $display("==============================");
        $display(" Final Layer Output");
        $display("==============================");

        for (int i = 0; i < N2; i++) begin

            read_activation(i, final_result[i]);

            $display(
                "class[%0d] = %0d",
                i,
                $signed(final_result[i])
            );

        end

        $display("==============================");

    end
    endtask


    // ============================================================
    // Find argmax
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
        $display("");

    end
    endtask


    // ============================================================
    // Main test
    // ============================================================

    initial begin

        // --------------------------------------------------------
        // Initial values
        // --------------------------------------------------------

        rst_n        = 1'b0;

        start        = 1'b0;

        k_idx_max    = '0;
        n_idx_max    = '0;
        n_total      = '0;

        relu_en      = 1'b0;
        shift_amount = '0;


        w_host_en    = 1'b0;
        w_host_we    = 1'b0;
        w_host_addr  = '0;
        w_host_wdata = '0;


        m_host_en    = 1'b0;
        m_host_we    = 1'b0;
        m_host_addr  = '0;
        m_host_wdata = '0;


        // --------------------------------------------------------
        // Load simulation source files
        //
        // 파일명은 현재 Python에서 생성하는 실제 파일명으로
        // 수정하면 된다.
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
        // Initial memory load
        // ========================================================

        load_input_image();

        load_layer1_weights();


        // ========================================================
        // Layer 1
        //
        // (1 x 784) * (784 x 128)
        //
        // K tiles = 98
        // last K index = 97
        //
        // N tiles = 16
        // last N index = 15
        // ========================================================

        $display("");
        $display("====================================");
        $display(" Starting Layer 1 : 784 -> 128");
        $display("====================================");

        run_gemm(
            L1_K_IDX_MAX,
            L1_N_IDX_MAX,
            L1_N_TOTAL,
            L1_RELU,
            L1_SHIFT
        );

        $display("");
        $display("====================================");
        $display(" Layer 1 committed activation");
        $display("====================================");

        for (int i = 0; i < 16; i++) begin
            data_t temp;

            read_activation(i, temp);

            $display(
                "hidden[%0d] = %0d",
                i,
                $signed(temp)
            );
        end



        // ========================================================
        // Layer 1의 commit 결과는 activation BRAM [0:127]에
        // 이미 저장되어 있다.
        //
        // 이제 weight만 Layer 2 것으로 교체한다.
        // ========================================================

        load_layer2_weights();


        // ========================================================
        // Layer 2
        //
        // (1 x 128) * (128 x 10)
        //
        // K tiles = 16
        // last K index = 15
        //
        // N tiles = ceil(10 / 8) = 2
        // last N index = 1
        // ========================================================

        $display("");
        $display("====================================");
        $display(" Starting Layer 2 : 128 -> 10");
        $display("====================================");

        
        run_gemm(
            L2_K_IDX_MAX,
            L2_N_IDX_MAX,
            L2_N_TOTAL,
            L2_RELU,
            L2_SHIFT
        );


        // ========================================================
        // Result
        // ========================================================

        read_final_result();

        print_prediction();


        repeat (10)
            @(posedge clk);

        $finish;

    end


    // ============================================================
    // Timeout
    // ============================================================

    initial begin

        #20_000_000;

        $error("[TB] TIMEOUT");
        $finish;

    end


endmodule