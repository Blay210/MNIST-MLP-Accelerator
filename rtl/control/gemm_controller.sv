`timescale 1ns/1ps

module fsm #(
    parameter int MAX_DIM_IDX = 10,
    parameter int MAX_ITER = 7,
    parameter int PE_DIM = 8,
    parameter int DATA_LENGTH = 8,
    parameter int OUTPUT_LENGTH = 32
)(
    input logic clk,
    input logic rst_n,
    input logic start,
    input logic [MAX_DIM_IDX-1:0] K_total,
    input logic [MAX_DIM_IDX-1:0] N_total
);

    import mnist_pkg::*;
    
    // define states
    gemm_state_t current_state, next_state;

    // Weight Dim : K x N
    logic [MAX_ITER-1:0] K_iter_reg;
    logic [MAX_ITER-1:0] N_iter_reg;

    // iter
    logic [MAX_ITER-1:0] k_iter;
    logic [MAX_ITER-1:0] n_iter;

    // bram IO
    // bram Input
    logic bc_weight, bc_data;
    logic [6:0] bc_kt;
    logic [3:0] bc_nt;
    logic [7:0] bc_n_total;
    // bram_Output
    logic bc_valid;
    logic [DATA_LENGTH-1:0] bc_weight_out [0:PE_DIM-1];
    logic [DATA_LENGTH-1:0] bc_data_out   [0:PE_DIM-1];

    // systolic array IO
    // systolic array Input
    logic sa_load_w, sa_load_en;
    logic [DATA_LENGTH-1  :0] sa_data_in  [0:PE_DIM-1];
    // systolic array Output
    logic sa_done;
    logic [OUTPUT_LENGTH-1:0] sa_data_out [0:PE_DIM-1];


    // iter variable initializing and setting
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            K_iter_reg <= '0;
            N_iter_reg <= '0;
            k_iter <= '0;
            n_iter <= '0;
        end
        else if (start) begin
            K_iter_reg <= K_total >> 3;
            N_iter_reg <= N_total >> 3;
        end
    end

    // state transition
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            current_state <= IDLE;
        else
            current_state <= next_state;
    end

    // state condition
    always_comb begin
        next_state = current_state;

        case (current_state)
            IDLE: begin
                if (start) next_state = LOAD_WEIGHT;
            end

            LOAD_WEIGHT: begin
                
            end

            LOAD_DATA: begin
                
            end

            ACC: begin
                
            end

            COL_END: begin
                
            end

            DONE: begin
                
            end

            default: next_state = IDLE;

        endcase
    end

    // tiling loop
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            
        end
    end

    systolic_array u_sa(
        // input
        .clk(clk),
        .rst_n(rst_n),
        .load_w(sa_load_w),
        .load_en(sa_load_en),
        .data_in(sa_data_in),
        // output
        .done(sa_done),
        .acc_out(sa_data_out)
    );

    accumulator u_acc(
        // input
        .clk(clk),
        .rst_n(rst_n),
        .save(acc_save),
        .acc_en(acc_en),
        .acc_in(acc_data_in),
        // output
        .acc_out(acc_data_out)
    );

    bram_controller #(
        .DATA_LENGTH(DATA_LENGTH),
        .PE_DIM(PE_DIM)
    ) u_bc (
        // input
        .weight_req(bc_weight),
        .data_req(bc_data),
        .kt(bc_kt),
        .nt(bc_nt),
        .n_total(bc_n_total),
        // output
        .valid(bc_valid),
        .weight_out(bc_weight_out),
        .data_out(bc_data_out)
    );


endmodule