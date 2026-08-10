`timescale 1ns/1ps

package mnist_pkg;

    localparam int PE_DIM = 8;
    localparam int DATA_LENGTH = 8;
    localparam int OUTPUT_LENGTH = 32;
    localparam int K_MAX = 784;
    localparam int N_MAX = 128;

    typedef logic signed [DATA_LENGTH-1:0]   data_t ;
    typedef logic signed [OUTPUT_LENGTH-1:0] acc_t;
    typedef logic signed [DATA_LENGTH-1:0]   data_vec_t [0:PE_DIM-1];
    typedef logic signed [OUTPUT_LENGTH-1:0] acc_vec_t  [0:PE_DIM-1];
    typedef logic signed [DATA_LENGTH-1:0]   row_wire_t [0:PE_DIM-1][0:PE_DIM];
    typedef logic signed [OUTPUT_LENGTH-1:0] col_wire_t [0:PE_DIM][0:PE_DIM-1];
    typedef logic [4:0] shift_t;
    typedef logic [6:0] k_idx_t;
    typedef logic [3:0] n_idx_t;
    typedef logic [7:0] n_total_t;
    
    typedef enum logic [1:0] {
        MEM_ACTIVATION,
        MEM_WEIGHT,
        MEM_RESULT
    } mem_kind_t;

    typedef enum logic [4:0] {
        GEMM_IDLE,

        GEMM_WEIGHT_REQ,
        GEMM_WEIGHT_RECV,
        GEMM_WEIGHT_SEND,

        GEMM_DATA_REQ,
        GEMM_DATA_RECV,
        GEMM_CALC,

        GEMM_ACCUMULATE,

        GEMM_WRITE_REQ,
        GEMM_WRITE_WAIT,

        GEMM_COMMIT_REQ,
        GEMM_COMMIT_WAIT,

        GEMM_NEXT_TILE,
        GEMM_DONE
    } gemm_state_t;

    typedef enum logic [1:0] {
        SYS_IDLE = 2'b00,
        SYS_LOAD = 2'b01,
        SYS_CALC = 2'b10,
        SYS_DONE = 2'b11
    } sys_state_t;

    typedef enum logic [2:0] {
        BRAM_IDLE,
        BRAM_WEIGHT,
        BRAM_DATA,
        BRAM_WRITE,
        BRAM_COMMIT,
        BRAM_DONE
    } bram_state_t;

    typedef enum logic[2:0] {
        REQ_NONE,
        REQ_WEIGHT,
        REQ_DATA,
        REQ_WRITE,
        REQ_COMMIT
    } req_type_t;

    typedef struct packed {
        logic [6:0] kt;   // K-tile index, 0~97
        logic [3:0] nt;   // N-tile index, 0~15
        logic [7:0] n_total;
    } matrix_size_t;
    
endpackage
