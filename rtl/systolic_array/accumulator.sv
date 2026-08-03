`timescale 1ns/1ps

module accumulator (
    input logic clk,
    input logic rst_n,
    input logic save,
    input logic acc_en,

    input  mnist_pkg::acc_vec_t acc_in,
    output mnist_pkg::acc_vec_t acc_out
);

    import mnist_pkg::*;

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