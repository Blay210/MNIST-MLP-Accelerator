`timescale 1ns/1ps

package mnist_pkg;

    localparam int PE_DIM = 8;
    localparam int DATA_LENGTH = 8;
    localparam int OUTPUT_LENGTH = 32;

    typedef logic signed [DATA_LENGTH-1:0]   data_t ;
    typedef logic signed [OUTPUT_LENGTH-1:0] acc_t;
    typedef logic signed [DATA_LENGTH-1:0]   data_vec_t [0:PE_DIM-1];
    typedef logic signed [OUTPUT_LENGTH-1:0] acc_vec_t  [0:PE_DIM-1];
    typedef logic signed [DATA_LENGTH-1:0]   row_wire_t [0:PE_DIM-1][0:PE_DIM];
    typedef logic signed [OUTPUT_LENGTH-1:0] col_wire_t [0:PE_DIM][0:PE_DIM-1];
    
    typedef enum logic [1:0] {
        MEM_ACTIVATION,
        MEM_WEIGHT,
        MEM_RESULT
    } mem_kind_t;

    typedef enum logic [2:0] {
        IDLE = 3'd0,
        LOAD_WEIGHT = 3'd1,
        LOAD_DATA = 3'd2,
        ACC = 3'd3,
        COL_END = 3'd4,
        DONE = 3'd5
    } gemm_state_t;

    typedef enum logic [1:0] {
        SYS_IDLE = 2'b00,
        SYS_LOAD = 2'b01,
        SYS_CALC = 2'b10,
        SYS_DONE = 2'b11
    } sys_state_t;

    typedef enum logic [1:0] {
        BRAM_IDLE,
        BRAM_WEIGHT,
        BRAM_DATA,
        BRAM_DONE
    } bram_state_t;

    typedef enum logic[1:0] {
        REQ_NONE,
        REQ_WEIGHT,
        REQ_DATA
    } req_type_t;

    typedef struct packed {
        logic [6:0] kt;   // K-tile index, 0~97
        logic [3:0] nt;   // N-tile index, 0~15
        logic [7:0] n_total;
    } matrix_size_t;
    
endpackage
