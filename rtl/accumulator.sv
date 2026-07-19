`timescale 1ns / 1ps

module accumulator #(
    parameter int PE_DIM = 8,
    parameter int OUTPUT_LENGTH = 32
)(
    input logic clk,
    input logic rst_n,
    input logic save,

    input  logic [OUTPUT_LENGTH-1:0] acc_in  [0:PE_DIM-1],
    output logic [OUTPUT_LENGTH-1:0] acc_out [0:PE_DIM-1]
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= '{default: '0};
        end
    end

endmodule