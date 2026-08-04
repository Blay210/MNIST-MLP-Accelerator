`timescale 1ns / 1ps

module bram_controller #(
    parameter int K_MAX       = 784,   // 레이어1 기준 (가장 큰 값)
    parameter int N_MAX       = 128
)(
    input  logic clk,
    input  logic rst_n,

    // FSM -> bram_controller
    input  logic weight_req,
    input  logic data_req,
    input  logic write_req,
    input  logic commit_req,

    input  logic [3:0] write_nt,
    input  mnist_pkg::data_vec_t write_data,

    // KXN matrix (weight)
    input  logic [6:0] kt,   // K-tile index, 0~97
    input  logic [3:0] nt,   // N-tile index, 0~15
    input  logic [7:0] n_total,

    // bram_controller -> FSM
    output logic valid,
    output logic write_done,
    output logic commit_done,
    output mnist_pkg::data_vec_t out
);

    import mnist_pkg::*;
    localparam PE_DIM_IDX = $clog2(PE_DIM);
    
    bram_state_t current_state, next_state;

    // 실제 온칩 메모리 (시뮬레이션 단계: $readmemh로 초기값 로드)
    data_t w_mem    [0:K_MAX*N_MAX-1];
    data_t m_mem    [0:K_MAX-1];
    data_t data_reg [0:PE_DIM-1][0:PE_DIM-1];

    logic [PE_DIM_IDX-1:0] iter_row, iter_col, iter_out;

    req_type_t req_type;
    logic [6:0] kt_reg;
    logic [3:0] nt_reg;
    logic [7:0] n_total_reg;

    logic [3:0] write_nt_reg;
    data_vec_t data_write_reg;

    data_t result_buffer [0:N_MAX-1];

    // initial begin
    //     $readmemh("./rtl/memory/w_data.mem", w_mem);
    //     $readmemh("./rtl/memory/m_data.mem", m_mem);
    // end


    // state conditions
    always_comb begin
        next_state = current_state;

        case (current_state)
            BRAM_IDLE: begin
                if (weight_req)      next_state = BRAM_WEIGHT;
                else if (data_req)   next_state = BRAM_DATA;
                else if (write_req)  next_state = BRAM_WRITE;
                else if (commit_req) next_state = BRAM_COMMIT;
            end

            BRAM_WEIGHT: begin
                if ((iter_row == PE_DIM-1) &&
                    (iter_col == PE_DIM-1))
                    next_state = BRAM_DONE;
            end

            BRAM_DATA: begin
                if (iter_row == PE_DIM-1)
                    next_state = BRAM_DONE;
            end

            BRAM_WRITE: begin
                next_state = BRAM_DONE;
            end

            BRAM_COMMIT: begin
                next_state = BRAM_DONE;
            end

            BRAM_DONE: begin
                if (req_type == REQ_WEIGHT) begin
                    if (iter_out == PE_DIM-1)
                        next_state = BRAM_IDLE;
                end
                else if (req_type == REQ_DATA) begin
                    next_state = BRAM_IDLE;
                end
                else if (req_type == REQ_WRITE) begin
                    next_state = BRAM_IDLE;
                end
                else if (req_type == REQ_COMMIT) begin
                    next_state = BRAM_IDLE;
                end
            end

            default: next_state = BRAM_IDLE;
        endcase
    end

    // state transition
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= BRAM_IDLE;
        end
        else begin
            current_state <= next_state;
        end
    end

    always_ff @( posedge clk or negedge rst_n ) begin
        if (!rst_n) begin
            kt_reg         <= '0;
            nt_reg         <= '0;
            n_total_reg    <= '0;
            write_nt_reg   <= '0;
            data_write_reg <= '{default:'0};
        end
        else if (current_state == BRAM_IDLE &&
                (weight_req || data_req)) begin
            kt_reg      <= kt;
            nt_reg      <= nt;
            n_total_reg <= n_total;
        end
        else if (current_state == BRAM_IDLE && write_req) begin
            write_nt_reg   <= write_nt;
            data_write_reg <= write_data;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_type <= REQ_NONE;
        end
        else if (current_state == BRAM_IDLE) begin
            if (weight_req)
                req_type <= REQ_WEIGHT;

            else if (data_req)
                req_type <= REQ_DATA;

            else if (write_req)
                req_type <= REQ_WRITE;

            else if (commit_req)
                req_type <= REQ_COMMIT;

            else
                req_type <= REQ_NONE;

        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_done  <= 1'b0;
            commit_done <= 1'b0;
        end
        else begin
            write_done  <= 1'b0;
            commit_done <= 1'b0;

            if (current_state == BRAM_DONE) begin
                if (req_type == REQ_WRITE) begin
                    write_done <= 1'b1;
                end
                else if (req_type == REQ_COMMIT) begin
                    commit_done <= 1'b1;
                end
            end
        end
    end

    // memory load
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iter_row <= '0;
            iter_col <= '0;
            for (int i = 0; i < N_MAX; i++) begin
                result_buffer[i] <= '0;
            end
        end
        else case (current_state)

            BRAM_IDLE: begin
                iter_row <= '0;
                iter_col <= '0;
            end
            BRAM_WEIGHT: begin
                data_reg[iter_row][PE_DIM-iter_col-1] <= w_mem[((iter_row+kt_reg*PE_DIM)*n_total_reg+nt_reg*PE_DIM)+iter_col];
                if (iter_col == PE_DIM-1) begin
                    if (iter_row < PE_DIM-1)  begin
                        iter_row <= iter_row + 1;
                        iter_col <= '0;
                    end
                end
                else begin
                    iter_col <= iter_col + 1;
                end
            end

            BRAM_DATA: begin
                data_reg[0][iter_row] <= m_mem[kt_reg*PE_DIM+iter_row];
                if (iter_row < PE_DIM-1) begin
                    iter_row <= iter_row + 1;
                end
            end

            BRAM_WRITE: begin
                for (int i = 0; i < PE_DIM; i++) begin
                    if (write_nt * PE_DIM + i < n_total) begin
                        result_buffer[write_nt_reg * PE_DIM + i] <= data_write_reg[i];
                    end
                end
            end

            BRAM_COMMIT: begin
                for (int i = 0; i < N_MAX; i++) begin
                    if (i < n_total_reg)
                        m_mem[i] <= result_buffer[i];
                end
                for (int i = 0; i < N_MAX; i++) begin
                    result_buffer[i] <= '0;
                end
            end

            default: begin
            end
        endcase
    end

    // output control
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid <= 0;
            iter_out <= '0;
            out <= '{default: '0};
        end
        else case (current_state)
            BRAM_IDLE: begin
                valid <= 0;
                iter_out <= '0;
                out <= '{default: '0};
            end

            BRAM_DONE:begin
                if (req_type == REQ_WEIGHT) begin
                    valid <= 1'b1;
                    for (int i = 0; i < PE_DIM; i++) begin
                        out[i] <= data_reg[i][iter_out];
                    end
                    if (iter_out < PE_DIM-1) begin
                        iter_out <= iter_out + 1;
                    end
                end
                else if (req_type == REQ_DATA) begin
                    valid <= 1'b1;
                    for (int i = 0; i < PE_DIM; i++) begin
                        out[i] <= data_reg[0][i];
                    end
                end
            end

            default: begin
                valid <= 0;
                out <= '{default: '0};
            end
        endcase 
    end

endmodule
