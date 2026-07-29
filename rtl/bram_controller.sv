`timescale 1ns / 1ps

module bram_controller #(
    parameter int PE_DIM      = 8,
    parameter int PE_DIM_IDX  = 3,
    parameter int DATA_LENGTH = 8,
    parameter int K_MAX       = 784,   // 레이어1 기준 (가장 큰 값)
    parameter int N_MAX       = 128
)(
    input  logic clk,
    input  logic rst_n,

    // FSM -> bram_controller
    input  logic weight_req,
    input  logic data_req,
    input  logic [6:0] kt,   // K-tile index, 0~97
    input  logic [3:0] nt,   // N-tile index, 0~15
    input  logic [7:0] n_total,

    // bram_controller -> FSM
    output logic valid,
    output logic signed [DATA_LENGTH-1:0] weight_out [0:PE_DIM-1],
    output logic signed [DATA_LENGTH-1:0] data_out   [0:PE_DIM-1]
);

    typedef enum logic [1:0] {
        IDLE = 2'b00,
        READ = 2'b01,
        DONE = 2'b10
    } state_t;
    state_t current_state, next_state;

    // 실제 온칩 메모리 (시뮬레이션 단계: $readmemh로 초기값 로드)
    logic [DATA_LENGTH-1:0] w_mem    [0:K_MAX*N_MAX-1];
    logic [DATA_LENGTH-1:0] m_mem    [0:K_MAX-1];
    logic [DATA_LENGTH-1:0] data_reg [0:PE_DIM-1][0:PE_DIM-1];

    logic [PE_DIM_IDX-1:0] iter_row, iter_col, iter_out;

    // internal signals for control
    logic load_end, out_end;

    initial begin
        $readmemh("w_data.mem", w_mem);
        $readmemh("m_data.mem", m_mem);
    end


    // state conditions
    always_comb begin
        next_state = current_state;

        case (current_state)
            IDLE: if (weight_req || data_req) next_state = READ;

            READ: if (load_end) next_state = DONE;

            DONE: if (out_end) next_state = IDLE;

            default: next_state = IDLE;
        endcase
    end

    // state transition
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= IDLE;
        end
        else begin
            current_state <= next_state;
        end
    end

    // memory load
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iter_row <= '0;
            iter_col <= '0;
            load_end <= 0;
        end
        else case (current_state)

            IDLE: begin
                load_end <= 0;
                iter_row <= '0;
                iter_col <= '0;
            end
            READ: begin
                if (weight_req) begin
                    data_reg[iter_row][PE_DIM-iter_col-1] <= w_mem[((iter_row+kt*PE_DIM)*n_total+nt*PE_DIM)+iter_col];
                    if (iter_col == PE_DIM-1) begin
                        if (iter_row == PE_DIM-1) begin
                            load_end <= 1;
                        end
                        else begin
                            iter_row <= iter_row + 1;
                            iter_col <= '0;
                        end
                    end
                    else begin
                        iter_col <= iter_col + 1;
                    end
                end
                else if (data_req) begin
                    data_reg[0][iter_row] <= m_mem[kt*PE_DIM+iter_row];
                    if (iter_row == PE_DIM-1) begin
                        load_end <= 1;
                    end
                    else begin
                        iter_row <= iter_row + 1;
                    end
                end
            end

            default: begin
                load_end <= 0;
            end
        endcase
    end

    // output control
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid <= 0;
            out_end <= 0;
            iter_out <= '0;
        end
        else case (current_state)
            IDLE: begin
                valid <= 0;
                out_end <= 0;
                iter_out <= '0;
            end

            DONE:begin
                valid <= 1;
                if (weight_req) begin
                    for (int i = 0; i < PE_DIM; i++) begin
                        weight_out[i] <= data_reg[i][iter_out];
                    end
                    if (iter_out == PE_DIM-1) begin
                        out_end <= 1;
                    end
                    else begin
                        iter_out <= iter_out + 1;
                    end
                end
                else if (data_req) begin
                    for (int i = 0; i < PE_DIM; i++) begin
                        data_out[i] <= data_reg[0][i];
                    end
                    out_end <= 1;
                end
            end

            default: begin
                valid <= 0;
                out_end <= 0;
            end
        endcase 
    end

endmodule