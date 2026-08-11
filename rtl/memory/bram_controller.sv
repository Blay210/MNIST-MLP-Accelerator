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
    input  logic [9:0] k_total,
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
    output logic [14:0] w_addr,
    input  mnist_pkg::word_t w_rdata,

    // -----------------------------
    // External Activation BRAM interface
    // -----------------------------
    output logic        m_en,
    output logic        m_we,
    output logic [7:0]  m_addr,
    output mnist_pkg::word_t m_wdata,
    input  mnist_pkg::word_t m_rdata
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
    k_total_t k_total_reg;

    n_idx_t write_nt_reg;
    data_vec_t data_write_reg;

    data_t result_buffer [0:N_MAX-1];

    // initial begin
    //     $readmemh("./rtl/memory/w_data.mem", w_mem);
    //     $readmemh("./rtl/memory/m_data.mem", m_mem);
    // end

    logic [7:0] n_word_stride;

    always_comb begin
        n_word_stride = (n_total_reg + WORD_NUM - 1) / WORD_NUM;
    end

    logic [7:0] commit_word_count;

    always_comb begin
        commit_word_count =
            (n_total_reg + WORD_NUM - 1) / WORD_NUM;
    end

    logic [3:0] valid_n_count;
    logic [3:0] valid_k_count;

    always_comb begin
        if (n_total_reg > nt_reg * PE_DIM) begin
            if ((n_total_reg - nt_reg * PE_DIM) >= PE_DIM)
                valid_n_count = PE_DIM;
            else
                valid_n_count = n_total_reg - nt_reg * PE_DIM;
        end
        else begin
            valid_n_count = 0;
        end
    end

    always_comb begin
        if (k_total_reg > kt_reg * PE_DIM) begin
            if ((k_total_reg - kt_reg * PE_DIM) >= PE_DIM)
                valid_k_count = PE_DIM;
            else
                valid_k_count = k_total_reg - kt_reg * PE_DIM;
        end
        else begin
            valid_k_count = 0;
        end
    end

    logic [2:0] weight_word_count;
    logic [2:0] data_word_count;

    always_comb begin
        weight_word_count =
            (valid_n_count + WORD_NUM - 1) / WORD_NUM;
    end

    always_comb begin
        data_word_count =
            (valid_k_count + WORD_NUM - 1) / WORD_NUM;
    end

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

                    w_addr = ((kt_reg * PE_DIM + iter_row) * n_word_stride)
                           + (nt_reg * WORD_COL_ITER)
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
                        (kt_reg * WORD_COL_ITER)
                        + iter_row;
                end
            end


            // ------------------------------------
            // Activation write
            // ------------------------------------
            BRAM_COMMIT: begin
                m_en   = 1'b1;
                m_we   = 1'b1;
                m_addr = commit_idx;

                for (int b = 0; b < WORD_NUM; b++) begin
                    if (commit_idx*WORD_NUM + b < n_total_reg) begin
                        m_wdata[b*8 +: 8]
                            = result_buffer[
                                commit_idx*WORD_NUM + b
                            ];
                    end
                end
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
                if (weight_capture_done)
                    next_state = BRAM_DONE;
            end

            BRAM_DATA: begin
                if (data_capture_done)
                    next_state = BRAM_DONE;
            end

            BRAM_WRITE: begin
                next_state = BRAM_DONE;
            end

            BRAM_COMMIT: begin
                if (commit_idx == commit_word_count - 1'b1)
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
            k_total_reg    <= '0;
            data_write_reg <= '{default:'0};
        end
        else if (current_state == BRAM_IDLE &&
                (weight_req || data_req)) begin
            kt_reg      <= kt;
            nt_reg      <= nt;
            n_total_reg <= n_total;
            k_total_reg <= k_total;
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

            w_pending            <= 1'b0;
            weight_issue_done    <= 1'b0;
            weight_capture_done  <= 1'b0;
            w_row_d              <= '0;
            w_col_d              <= '0;

            m_pending            <= 1'b0;
            data_issue_done      <= 1'b0;
            data_capture_done    <= 1'b0;
            m_row_d              <= '0;

            commit_idx           <= '0;

            for (int i = 0; i < N_MAX; i++) begin
                result_buffer[i] <= '0;
            end
        end
        else begin
            case (current_state)

                BRAM_IDLE: begin
                    iter_row <= '0;
                    iter_col <= '0;

                    w_pending            <= 1'b0;
                    weight_issue_done    <= 1'b0;
                    weight_capture_done  <= 1'b0;
                    w_row_d              <= '0;
                    w_col_d              <= '0;

                    m_pending            <= 1'b0;
                    data_issue_done      <= 1'b0;
                    data_capture_done    <= 1'b0;
                    m_row_d              <= '0;

                    commit_idx           <= '0;

                    if (weight_req) begin
                        for (int r = 0; r < PE_DIM; r++) begin
                            for (int c = 0; c < PE_DIM; c++) begin
                                data_reg[r][c] <= '0;
                            end
                        end
                    end
                    else if (data_req) begin
                        for (int c = 0; c < PE_DIM; c++) begin
                            data_reg[0][c] <= '0;
                        end
                    end
                end


                BRAM_WEIGHT: begin

                    // Previous cycle's BRAM response
                    if (w_pending) begin
                        for (int b = 0; b < WORD_NUM; b++) begin
                            if ((w_col_d * WORD_NUM + b) < valid_n_count) begin
                                data_reg[w_row_d]
                                        [PE_DIM - 1 - (w_col_d*WORD_NUM + b)]
                                    <= w_rdata[b*8 +: 8];
                            end
                        end

                        if (kt_reg == 0 && nt_reg == 0) begin
                            $display(
                                "[W_CAPTURE] row=%0d col=%0d dst=%0d data=%0d",
                                w_row_d,
                                w_col_d,
                                WORD_COL_ITER-w_col_d-1,
                                $signed(w_rdata)
                            );
                        end

                        if ((w_row_d == PE_DIM-1) &&
                            (w_col_d == weight_word_count-1)) begin
                            weight_capture_done <= 1'b1;
                        end
                    end

                    // Issue a new BRAM request
                    if (!weight_issue_done) begin
                        w_row_d   <= iter_row;
                        w_col_d   <= iter_col;
                        w_pending <= 1'b1;

                        if ((iter_row == PE_DIM-1) &&
                            (iter_col == weight_word_count-1)) begin

                            weight_issue_done <= 1'b1;
                        end
                        else if (iter_col == weight_word_count-1) begin
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


                BRAM_DATA: begin

                    // Previous cycle's BRAM response
                    if (m_pending) begin
                        for (int b = 0; b < WORD_NUM; b++) begin
                            if ((m_row_d * WORD_NUM + b) < valid_k_count) begin
                                data_reg[0][m_row_d*WORD_NUM + b]
                                    <= m_rdata[b*8 +: 8];
                            end
                        end

                        if (m_row_d == data_word_count - 1'b1)
                            data_capture_done <= 1'b1;
                    end

                    // Issue a new read
                    if (!data_issue_done) begin
                        m_row_d <= iter_row;
                        m_pending <= 1'b1;

                        if (iter_row == data_word_count -1) begin
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


                BRAM_WRITE: begin
                    for (int i = 0; i < PE_DIM; i++) begin
                        if (write_nt_reg == 1) begin
                            $display(
                                "[WRITE] nt=%0d lane=%0d index=%0d data=%0d valid=%0d",
                                write_nt_reg,
                                i,
                                write_nt_reg * PE_DIM + i,
                                $signed(data_write_reg[i]),
                                (write_nt_reg * PE_DIM + i < n_total_reg)
                            );
                        end

                        if (write_nt_reg * PE_DIM + i < n_total_reg) begin
                            result_buffer[
                                write_nt_reg * PE_DIM + i
                            ] <= data_write_reg[i];
                        end
                    end
                end

                BRAM_COMMIT: begin
                    for (int b = 0; b < WORD_NUM; b++) begin
                        if (commit_idx*WORD_NUM + b < n_total_reg) begin
                            result_buffer[commit_idx*WORD_NUM + b] <= '0;
                        end
                    end

                    if (commit_idx < commit_word_count - 1'b1)
                        commit_idx <= commit_idx + 1'b1;
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
