`timescale 1ns / 1ps


module systolic_array #(
    parameter int DATA_LENGTH = 8,
    parameter int OUTPUT_LENGTH = 32,
    parameter int PE_DIM = 8
)(
    input  logic clk,
    input  logic rst_n,
    input  logic load_w,
    input  logic load_en,
    input  logic signed [DATA_LENGTH-1  :0] data_in [0:PE_DIM-1],

    output logic signed [OUTPUT_LENGTH-1:0] acc_out [0:PE_DIM-1],
    output logic done
);

    // state 정의
    typedef enum logic [1:0] {
        IDLE = 2'b00,
        LOAD = 2'b01,
        CALC = 2'b10,
        DONE = 2'b11
    } state_t;
    state_t current_state, next_state;
    
    logic [DATA_LENGTH-1  :0] h_wire [0:PE_DIM-1][0:PE_DIM];
    logic [OUTPUT_LENGTH-1:0] v_wire [0:PE_DIM][0:PE_DIM-1];

    logic [DATA_LENGTH-1  :0] data_in_reg [0:PE_DIM-1];
    logic [OUTPUT_LENGTH-1:0] result [0:PE_DIM-1];

    logic [4:0] cnt;

    // state transition (sequential)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            current_state <= IDLE;
        else
            current_state <= next_state;
    end


    // counter (sequential)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 0;
        end else if (current_state == CALC) begin
            cnt <= cnt + 1;
        end else begin
            cnt <= 0;
        end
    end


    // state condition
    always_comb begin
        done = 0;
        next_state = current_state;

        case (current_state)
            IDLE: begin
                if (load_w) next_state = LOAD;
            end

            LOAD: begin
                if (load_en) next_state = CALC;
            end

            CALC: begin
                if (int'(cnt) == (PE_DIM*2-1)) begin
                    next_state = DONE;
                end
            end

            DONE: begin
                done = 1;
                next_state = IDLE;
            end

            default: begin
                next_state = IDLE;
            end

        endcase
    end

    
    // save input data in registers (sequential)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < PE_DIM; i++) begin
                data_in_reg[i] <= '0;
            end
        end else if (current_state == CALC && int'(cnt) == 0) begin
            for (int i = 0; i < PE_DIM; i++) begin
                data_in_reg[i] <= data_in[i];
            end
        end
    end


    // input logic for weight and matrix data (combinational)
    always_comb begin
        for (int i = 0; i < PE_DIM; i++) begin
            h_wire[i][0] = '0;
            v_wire[0][i] = '0;
        end

        if (current_state == LOAD) begin
            for (int i = 0; i < PE_DIM; i++) begin
                h_wire[i][0] = data_in[i];
            end
        end else if (current_state == CALC) begin
            if (int'(cnt) == 0) begin
                h_wire[0][0] = data_in[0];
            end else begin
                if (int'(cnt) < PE_DIM) begin
                    h_wire[cnt][0] = data_in_reg[cnt];
                end
            end
        end
    end


    // output harvest logic (sequential)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < PE_DIM; i++) begin
                result[i] <= '0;
                acc_out[i] <= '0;
            end
        end else if (current_state == CALC) begin
            if (int'(cnt) >= PE_DIM && int'(cnt) < PE_DIM*2) begin
                result[int'(cnt)-PE_DIM] <= v_wire[PE_DIM][int'(cnt)-PE_DIM];
            end
        end else if (current_state == DONE) begin
            for (int i = 0; i < PE_DIM; i++) begin
                acc_out[i] <= result[i];
            end
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
                    .load_w(load_w),
                    .load_en(load_en),
                    .data_in(h_wire[i][j]),
                    .acc_in(v_wire[i][j]),
                    .data_out(h_wire[i][j+1]),
                    .acc_out(v_wire[i+1][j])
                );
            end
        end
    endgenerate

endmodule
