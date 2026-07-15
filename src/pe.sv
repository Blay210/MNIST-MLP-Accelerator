`timescale 1ns / 1ps


module pe #(
    parameter int COL_ID = 0,
    parameter int DATA_LENGTH = 8,
    parameter int OUTPUT_LENGTH = 32
)(
    input  logic clk,
    input  logic rst_n,
    input  logic load_w,
    input  logic load_en,
    input  logic signed [OUTPUT_LENGTH-1:0] acc_in,         // 누적 연산 입력
    input  logic signed [DATA_LENGTH-1  :0] data_in,        // input data

    output logic signed [OUTPUT_LENGTH-1:0] acc_out,        // 누적 연산 결과
    output logic signed [DATA_LENGTH-1  :0] data_out        // input data
);

    logic signed [DATA_LENGTH-1:0] weight;
    logic [3:0] load_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        data_out <= data_in;
        if (!rst_n) begin
            weight   <= '0;
            acc_out  <= '0;
            load_cnt <= '0;
        end
        else if (load_w) begin
            load_cnt <= load_cnt + 1;
            if ((int'(load_cnt)) == COL_ID * 2) weight <= data_in;
        end
        else if (load_en) begin
            acc_out <= acc_in + (OUTPUT_LENGTH'(data_in * weight));
        end
    end
endmodule
