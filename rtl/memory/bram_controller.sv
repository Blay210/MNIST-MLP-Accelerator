`timescale 1ns / 1ps

module bram_controller (
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
    output mnist_pkg::data_vec_t out,

    // -----------------------------
    // External Weight BRAM interface
    // -----------------------------
    output logic        w_en,
    output logic [16:0] w_addr,
    input  mnist_pkg::data_t w_rdata,

    // -----------------------------
    // External Activation BRAM interface
    // -----------------------------
    output logic        m_en,
    output logic        m_we,
    output logic [9:0]  m_addr,
    output mnist_pkg::data_t m_wdata,
    input  mnist_pkg::data_t m_rdata
);

    import mnist_pkg::*;
    localparam PE_DIM_IDX = $clog2(PE_DIM);
    
    bram_state_t current_state, next_state;

    // 실제 온칩 메모리 (시뮬레이션 단계: $readmemh로 초기값 로드)
    data_t data_reg [0:PE_DIM-1][0:PE_DIM-1];

    logic [PE_DIM_IDX-1:0] iter_row, iter_col, iter_out;

    // Weight BRAM read pipeline
    logic w_pending;
    logic weight_issue_done;
    logic weight_capture_done;

    logic [PE_DIM_IDX-1:0] w_row_d;
    logic [PE_DIM_IDX-1:0] w_col_d;

    // Activation BRAM read pipeline
    logic m_pending;
    logic data_issue_done;
    logic data_capture_done;

    logic [PE_DIM_IDX-1:0] m_row_d;

    // Sequential commit counter
    logic [7:0] commit_idx;

    req_type_t req_type;
    k_idx_t kt_reg;
    n_idx_t nt_reg;
    n_total_t n_total_reg;

    n_idx_t write_nt_reg;
    data_vec_t data_write_reg;

    data_t result_buffer [0:N_MAX-1];

    // initial begin
    //     $readmemh("./rtl/memory/w_data.mem", w_mem);
    //     $readmemh("./rtl/memory/m_data.mem", m_mem);
    // end

    // bram control signal
    always_comb begin
        // Defaults
        w_en   = 1'b0;
        w_addr = '0;

        m_en    = 1'b0;
        m_we    = 1'b0;
        m_addr  = '0;
        m_wdata = '0;

        case (current_state)

            // ------------------------------------
            // Weight read
            // ------------------------------------
            BRAM_WEIGHT: begin
                if (!weight_issue_done) begin
                    w_en = 1'b1;

                    w_addr =
                        ((iter_row + kt_reg * PE_DIM)
                            * n_total_reg)
                        + (nt_reg * PE_DIM)
                        + iter_col;
                end
            end


            // ------------------------------------
            // Activation read
            // ------------------------------------
            BRAM_DATA: begin
                if (!data_issue_done) begin
                    m_en = 1'b1;
                    m_we = 1'b0;

                    m_addr =
                        (kt_reg * PE_DIM)
                        + iter_row;
                end
            end


            // ------------------------------------
            // Activation write
            // ------------------------------------
            BRAM_COMMIT: begin
                m_en    = 1'b1;
                m_we    = 1'b1;
                m_addr  = commit_idx;
                m_wdata = result_buffer[commit_idx];
            end


            default: begin
            end

        endcase
    end

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
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iter_row <= '0;
            iter_col <= '0;

            w_pending          <= 1'b0;
            weight_issue_done  <= 1'b0;
            weight_capture_done <= 1'b0;
            w_row_d            <= '0;
            w_col_d            <= '0;

            m_pending          <= 1'b0;
            data_issue_done    <= 1'b0;
            data_capture_done  <= 1'b0;
            m_row_d            <= '0;

            commit_idx <= '0;

            for (int i = 0; i < N_MAX; i++) begin
                result_buffer[i] <= '0;
            end
        end
        else begin
            case (current_state)

                BRAM_IDLE: begin
                    iter_row <= '0;
                    iter_col <= '0;

                    w_pending           <= 1'b0;
                    weight_issue_done   <= 1'b0;
                    weight_capture_done <= 1'b0;

                    m_pending           <= 1'b0;
                    data_issue_done     <= 1'b0;
                    data_capture_done   <= 1'b0;

                    commit_idx <= '0;
                end


                // ------------------------------------
                // Weight BRAM read
                // ------------------------------------
                BRAM_WEIGHT: begin

                    // Previous cycle's BRAM response
                    if (w_pending) begin
                        data_reg[w_row_d][PE_DIM-w_col_d-1]
                            <= w_rdata;

                        if ((w_row_d == PE_DIM-1) &&
                            (w_col_d == PE_DIM-1)) begin
                            weight_capture_done <= 1'b1;
                        end
                    end

                    // Issue a new BRAM request
                    if (!weight_issue_done) begin
                        w_row_d <= iter_row;
                        w_col_d <= iter_col;
                        w_pending <= 1'b1;

                        if ((iter_row == PE_DIM-1) &&
                            (iter_col == PE_DIM-1)) begin

                            weight_issue_done <= 1'b1;
                        end
                        else if (iter_col == PE_DIM-1) begin
                            iter_row <= iter_row + 1'b1;
                            iter_col <= '0;
                        end
                        else begin
                            iter_col <= iter_col + 1'b1;
                        end
                    end
                    else begin
                        w_pending <= 1'b0;
                    end
                end


                // ------------------------------------
                // Activation BRAM read
                // ------------------------------------
                BRAM_DATA: begin

                    // Previous cycle's BRAM response
                    if (m_pending) begin
                        data_reg[0][m_row_d] <= m_rdata;

                        if (m_row_d == PE_DIM-1) begin
                            data_capture_done <= 1'b1;
                        end
                    end

                    // Issue a new read
                    if (!data_issue_done) begin
                        m_row_d <= iter_row;
                        m_pending <= 1'b1;

                        if (iter_row == PE_DIM-1) begin
                            data_issue_done <= 1'b1;
                        end
                        else begin
                            iter_row <= iter_row + 1'b1;
                        end
                    end
                    else begin
                        m_pending <= 1'b0;
                    end
                end


                // ------------------------------------
                // Save one N-tile result
                // ------------------------------------
                BRAM_WRITE: begin
                    for (int i = 0; i < PE_DIM; i++) begin
                        if (write_nt_reg * PE_DIM + i < n_total_reg) begin
                            result_buffer[
                                write_nt_reg * PE_DIM + i
                            ] <= data_write_reg[i];
                        end
                    end
                end


                // ------------------------------------
                // result_buffer -> Activation BRAM
                // one byte per clock
                // ------------------------------------
                BRAM_COMMIT: begin
                    result_buffer[commit_idx] <= '0;

                    if (commit_idx < n_total_reg - 1'b1) begin
                        commit_idx <= commit_idx + 1'b1;
                    end
                end


                default: begin
                end

            endcase
        end
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
