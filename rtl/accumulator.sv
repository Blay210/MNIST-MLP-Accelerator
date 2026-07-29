`timescale 1ns/1ps

module accumulator #(
    parameter int PE_DIM = 8,
    parameter int OUTPUT_LENGTH = 32
)(
    input logic clk,
    input logic rst_n,
    input logic save,
    input logic acc_en,

    input  logic [OUTPUT_LENGTH-1:0] acc_in  [0:PE_DIM-1],
    output logic [OUTPUT_LENGTH-1:0] acc_out [0:PE_DIM-1]
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= '{default: '0};
        end
        else if (acc_en) begin
            if (save) begin
                acc_out <= acc_in;
            end
            else begin
                for (int i = 0; i < PE_DIM; i++) begin
                    acc_out[i] <= acc_out[i] + acc_in[i];
                end
            end
        end
    end

endmodule