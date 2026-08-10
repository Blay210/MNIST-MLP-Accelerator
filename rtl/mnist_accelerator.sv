`timescale 1ns/1ps

module mnist_accelerator (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic relu_en,
    input  mnist_pkg::k_idx_t   k_idx_max,
    input  mnist_pkg::n_idx_t   n_idx_max,
    input  mnist_pkg::n_total_t n_total,
    input  mnist_pkg::shift_t   shift_amount,
    
    output logic done
);

    import mnist_pkg::*;

    gemm_state_t current_state, next_state;

    // bram variables

    // weight matrix size : (K X N)
    // tile size : (8 x 8)
    k_idx_t   k_idx_iter, k_idx_max_reg;             // current K-tile index, 0~97 (row tile 개수)
    n_idx_t   n_idx_iter, n_idx_max_reg;             // current N-tile index, 0~15 (col tile 개수)
    n_total_t n_total_reg;

    logic weight_req, data_req, write_req, commit_req, write_done, commit_done;

    logic bram_valid;
    data_vec_t bram_out;
    data_vec_t bram_out_buffer;

    logic load_weight, start_calc, systolic_done;
    acc_vec_t systolic_out;

    logic [2:0] weight_cnt;

    logic acc_en, acc_save;
    acc_vec_t acc_out;
    data_vec_t acc2data_out;

    logic   relu_en_reg;
    shift_t shift_amount_reg;

    assign weight_req = (current_state == GEMM_WEIGHT_REQ);
    assign data_req   = (current_state == GEMM_DATA_REQ);
    assign write_req  = (current_state == GEMM_WRITE_REQ);
    assign commit_req = (current_state == GEMM_COMMIT_REQ);

    assign load_weight = (current_state == GEMM_WEIGHT_RECV) && bram_valid;
    assign start_calc  = (current_state == GEMM_DATA_RECV) && bram_valid;

    assign acc_en   = (current_state == GEMM_ACCUMULATE);
    assign acc_save = (current_state == GEMM_ACCUMULATE && k_idx_iter == 0);

    assign done = (current_state == GEMM_DONE);

    always_comb begin
        next_state = current_state;

        unique case (current_state)
            GEMM_IDLE: begin
                if (start) next_state = GEMM_WEIGHT_REQ;
            end
            GEMM_WEIGHT_REQ: begin
                next_state = GEMM_WEIGHT_RECV;
            end
            GEMM_WEIGHT_RECV: begin
                if (bram_valid) next_state = GEMM_WEIGHT_SEND;
            end
            GEMM_WEIGHT_SEND: begin
                if (weight_cnt == PE_DIM-1) next_state = GEMM_DATA_REQ;
            end
            GEMM_DATA_REQ: begin
                next_state = GEMM_DATA_RECV;                
            end
            GEMM_DATA_RECV: begin
                if (bram_valid) next_state = GEMM_CALC;
            end
            GEMM_CALC: begin
                if (systolic_done) next_state = GEMM_ACCUMULATE;
            end
            GEMM_ACCUMULATE: begin
                if (k_idx_iter < k_idx_max_reg)
                    next_state = GEMM_NEXT_TILE;
                else if (k_idx_iter == k_idx_max_reg)
                    next_state = GEMM_WRITE_REQ;
            end
            GEMM_WRITE_REQ: begin
                next_state = GEMM_WRITE_WAIT;
            end
            GEMM_WRITE_WAIT: begin
                if (write_done) next_state = GEMM_NEXT_TILE;
            end
            GEMM_NEXT_TILE: begin
                if (k_idx_iter < k_idx_max_reg) begin
                    next_state = GEMM_WEIGHT_REQ;
                end
                else if (n_idx_iter < n_idx_max_reg) begin
                    next_state = GEMM_WEIGHT_REQ;
                end
                else begin
                    next_state = GEMM_COMMIT_REQ;
                end
            end
            GEMM_COMMIT_REQ: begin
                next_state = GEMM_COMMIT_WAIT;
            end
            GEMM_COMMIT_WAIT: begin
                if (commit_done) next_state = GEMM_DONE;
            end
            GEMM_DONE: begin
                next_state = GEMM_IDLE;
            end
            default: begin
                next_state = GEMM_IDLE;
            end
        endcase
    end


    // bram buffer
    always_ff @( posedge clk or negedge rst_n ) begin : bram_buffer_delay
        if(!rst_n) begin
            bram_out_buffer <= '{default: '0};
        end
        else if (bram_valid) begin
            bram_out_buffer <= bram_out;
        end
        else begin
            bram_out_buffer <= '{default: '0};
        end
    end

    // gemm iter
    always_ff @( posedge clk or negedge rst_n ) begin : matrix_meta_data
        if (!rst_n) begin
            k_idx_iter <= '0;
            n_idx_iter <= '0;
            k_idx_max_reg <= '0;
            n_idx_max_reg <= '0;
            n_total_reg   <= '0;
        end
        else if (start && current_state == GEMM_IDLE) begin
            k_idx_iter <= '0;
            n_idx_iter <= '0;
            k_idx_max_reg <= k_idx_max;
            n_idx_max_reg <= n_idx_max;
            n_total_reg <= n_total;
        end
        else if (current_state == GEMM_NEXT_TILE) begin
            if (k_idx_iter < k_idx_max_reg) begin
                k_idx_iter <= k_idx_iter + 1'b1;
            end
            else if (
                (k_idx_iter == (k_idx_max_reg)) && 
                (n_idx_iter < (n_idx_max_reg))
            ) begin
                k_idx_iter <= '0;
                n_idx_iter <= n_idx_iter + 1'b1;
            end
        end
    end

    // quantizer option
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            relu_en_reg      <= 1'b0;
            shift_amount_reg <= '0;
        end
        else if (current_state == GEMM_IDLE && start) begin
            relu_en_reg      <= relu_en;
            shift_amount_reg <= shift_amount;
        end
    end

    // weight load counter
    always_ff @( posedge clk or negedge rst_n ) begin
        if (!rst_n) begin
            weight_cnt <= 0;
        end
        else if (current_state != GEMM_WEIGHT_SEND) begin
            weight_cnt <= 0;
        end
        else if (weight_cnt < PE_DIM-1) begin
            weight_cnt <= weight_cnt + 1;
        end
    end

    // current state <= next state
    always_ff @( posedge clk or negedge rst_n ) begin
        if (!rst_n) begin
            current_state <= GEMM_IDLE;
        end
        else begin
            current_state <= next_state;
        end
    end

    bram_controller u_bram_controller(
        .clk(clk),
        .rst_n(rst_n),
        .weight_req(weight_req),
        .data_req(data_req),
        .write_req(write_req),
        .commit_req(commit_req),
        .write_nt(n_idx_iter),
        .write_data(acc2data_out),
        .kt(k_idx_iter),
        .nt(n_idx_iter),
        .n_total(n_total_reg),
        .valid(bram_valid),
        .write_done(write_done),
        .commit_done(commit_done),
        .out(bram_out)
    );

    systolic_array u_systolic_array (
        .clk(clk),
        .rst_n(rst_n),
        .load_weight(load_weight),
        .start_calc(start_calc),
        .data_in(bram_out_buffer),
        .data_out(systolic_out),
        .done(systolic_done)
    );

    accumulator u_accumulator (
        .clk(clk),
        .rst_n(rst_n),
        .save(acc_save),
        .acc_en(acc_en),
        .acc_in(systolic_out),
        .acc_out(acc_out)
    );

    requantizer u_requantizer (
        .relu_en(relu_en_reg),
        .shift_amount(shift_amount_reg),
        .acc_in(acc_out),
        .data_out(acc2data_out)
    );

endmodule
