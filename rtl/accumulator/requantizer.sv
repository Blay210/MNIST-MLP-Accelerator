`timescale 1ns/1ps

module requantizer (
    input  logic relu_en,
    input  logic [4:0] shift_amount,
    input  mnist_pkg::acc_vec_t  acc_in,

    output mnist_pkg::data_vec_t data_out
);

    import mnist_pkg::*;

    logic signed [OUTPUT_LENGTH-1:0] scaled [0:PE_DIM-1];

    always_comb begin
        for (int i = 0; i < PE_DIM; i++) begin
            scaled[i] = $signed(acc_in[i]) >>> shift_amount;

            if (relu_en && scaled[i] < 0) begin
                data_out[i] = data_t'(0);
            end

            else if (scaled[i] > 127) begin
                data_out[i] = data_t'(127);
            end

            else if (scaled[i] < -128) begin
                data_out[i] = data_t'(-128);
            end

            else begin
                data_out[i] = data_t'(scaled[i]);
            end
        end
    end

endmodule