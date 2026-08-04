`timescale 1ns/1ps


module pe #(
    parameter int COL_ID = 0
)(
    input  logic clk,
    input  logic rst_n,
    input  logic load_weight,
    input  logic start_calc,
    input  mnist_pkg::acc_t  acc_in,         // 누적 연산 입력
    input  mnist_pkg::data_t data_in,        // input data

    output mnist_pkg::acc_t  acc_out,        // 누적 연산 결과
    output mnist_pkg::data_t data_out        // input data
);

    import mnist_pkg::*;

    data_t weight;
    logic [3:0] load_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= '0;
            weight   <= '0;
            acc_out  <= '0;
            load_cnt <= '0;
        end
        else begin
            data_out <= data_in;
            if (load_weight) begin
                load_cnt <= load_cnt + 1;
                if ((int'(load_cnt)) == PE_DIM-1) weight <= data_in;
            end
            else if (start_calc) begin
                load_cnt <= '0;
                acc_out <= acc_in + (OUTPUT_LENGTH'(data_in * weight));
            end
        end
    end

endmodule
