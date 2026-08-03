`timescale 1ns/1ps

module systolic_array (
    input logic clk,
    input logic rst_n,
    input logic load_weight,
    input logic start_calc,
    input mnist_pkg::data_vec_t data_in,
    output mnist_pkg::acc_vec_t data_out,
    output logic done
);

    import mnist_pkg::*;

    sys_state_t state;

    data_vec_t data_q;
    acc_vec_t  acc_d;

    logic result_out;

    systolic_array_fsm u_systolic_array_fsm (
        .clk(clk),
        .rst_n(rst_n),
        .load_weight(load_weight),
        .start_calc(start_calc),

        .result_out(result_out),
        .state(state),
        .done(done)
    );

    input_control_unit u_input_control_unit (
        .clk(clk),
        .rst_n(rst_n),
        .input_ctrl(state),
        .data_in(data_in),

        .data_out(data_q)
    );

    matrix_mult_unit u_matrix_mult_unit (
        .clk(clk),
        .rst_n(rst_n),
        .state(state),
        .data_in(data_q),

        .acc_out(acc_d)
    );

    output_control_unit u_output_control_unit (
        .clk(clk),
        .rst_n(rst_n),
        .start(result_out),
        .acc_in(acc_d),
        .acc_out(data_out)
    );



endmodule
