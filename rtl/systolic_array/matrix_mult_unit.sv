`timescale 1ns/1ps


module matrix_mult_unit (
    input  logic clk,
    input  logic rst_n,
    input  mnist_pkg::sys_state_t state,
    input  mnist_pkg::data_vec_t  data_in,
    output mnist_pkg::acc_vec_t   acc_out
);

    import mnist_pkg::*;
    
    row_wire_t row_wire;
    col_wire_t col_wire;

    logic load_weight, start_calc;

    assign load_weight = (state == SYS_LOAD)
                       ? 1'b1
                       : 1'b0;
    assign start_calc = (state == SYS_CALC)
                      ? 1'b1
                      : 1'b0;

    always_comb begin
        for (int i = 0; i < PE_DIM; i++) begin
            row_wire[i][0] = data_in[i];
        end
    end

    always_comb begin
        for (int j = 0; j < PE_DIM; j++) begin
            col_wire[0][j] = '0;
        end
    end

    always_comb begin
        for (int j = 0; j < PE_DIM; j++) begin
            acc_out[j] = col_wire[PE_DIM][j];
        end
    end

    // generate 8x8 pe module
    generate
        genvar i, j;
        for (i = 0; i < PE_DIM; i++) begin : row
            for (j = 0; j < PE_DIM; j++) begin : col
                pe #(
                    .COL_ID(j)
                ) u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .load_weight(load_weight),
                    .start_calc(start_calc),
                    .data_in(row_wire[i][j]),
                    .acc_in(col_wire[i][j]),
                    .data_out(row_wire[i][j+1]),
                    .acc_out(col_wire[i+1][j])
                );
            end
        end
    endgenerate

endmodule
