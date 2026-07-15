`timescale 1ns / 1ps

module tb_systolic_array;

    localparam int PE_DIM = 8;
    localparam int DATA_LENGTH = 8;
    localparam int OUTPUT_LENGTH = 32;
    localparam int CLK_PERIOD = 10;

    logic clk;
    logic rst_n;
    logic load_w;
    logic load_en;
    logic signed [DATA_LENGTH-1:0] data_in [0:PE_DIM-1];
    logic signed [OUTPUT_LENGTH-1:0] acc_out [0:PE_DIM-1];
    logic done;

    systolic_array #(
        .DATA_LENGTH(DATA_LENGTH),
        .OUTPUT_LENGTH(OUTPUT_LENGTH),
        .PE_DIM(PE_DIM)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .load_w(load_w),
        .load_en(load_en),
        .data_in(data_in),
        .acc_out(acc_out),
        .done(done)
    );

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        $dumpfile("wave.fst");
        $dumpvars(0, tb_systolic_array);
    end

    // 스모크 테스트: 정확성 검증용 아님. 툴체인이 제대로 도는지,
    // 파형에서 IDLE->LOAD->CALC->DONE 상태 전이가 보이는지만 확인하는 용도.
    // 실제 가중치 시퀀스(2*COL_ID 타이밍 맞춘 것)와 numpy 대조 검증은 다음 단계에서 직접 채워야 함.
    initial begin
        rst_n   = 0;
        load_w  = 0;
        load_en = 0;
        for (int i = 0; i < PE_DIM; i++) data_in[i] = '0;

        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        load_w = 1;
        for (int t = 0; t < 15; t++) begin
            for (int i = 0; i < PE_DIM; i++) data_in[i] = i + 1;
            @(posedge clk);
        end

        load_w  = 0;
        load_en = 1;

        for (int t = 0; t < 16; t++) begin
            for (int i = 0; i < PE_DIM; i++) data_in[i] = (t == i) ? (i + 1) : 0;
            @(posedge clk);
            if (done) $display("[TB] cycle %0t: done=1, acc_out[0]=%0d", $time, acc_out[0]);
        end
        load_en = 0;

        repeat (3) @(posedge clk);
        $display("[TB] 스모크 테스트 종료 -- 파형에서 상태 전이가 IDLE->LOAD->CALC->DONE 순서로 보이는지 확인해봐");
        $finish;
    end

endmodule