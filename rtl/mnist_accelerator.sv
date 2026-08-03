module mnist_accelerator (
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    output logic done
);

    import mnist_pkg::*;

    // Controller → Memory
    logic mem_req;
    logic mem_write;
    logic mem_done;

    // Memory → Systolic array
    data_vec_t mem_data;

    // Controller → Systolic array
    logic weight_load_start;
    logic calc_start;

    // Systolic array → Controller
    logic calc_done;

    // Systolic array → Accumulator
    acc_vec_t partial_sum;

    // Controller → Accumulator
    logic acc_clear;
    logic acc_en;

    // Accumulator output
    acc_vec_t accumulated_result;

    gemm_controller u_controller (
        .clk               (clk),
        .rst_n             (rst_n),
        .start             (start),
        .done              (done),

        .mem_req           (mem_req),
        .mem_write         (mem_write),
        .mem_done          (mem_done),

        .weight_load_start (weight_load_start),
        .calc_start        (calc_start),
        .calc_done         (calc_done),

        .acc_clear         (acc_clear),
        .acc_en            (acc_en)
    );

    bram_controller u_memory (
        .clk      (clk),
        .rst_n    (rst_n),

        .req      (mem_req),
        .write_en (mem_write),
        .done     (mem_done),

        .data_out (mem_data),
        .data_in  (accumulated_result)
    );

    systolic_array u_systolic_array (
        .clk               (clk),
        .rst_n             (rst_n),

        .weight_load_start (weight_load_start),
        .calc_start        (calc_start),

        .data_in           (mem_data),

        .partial_sum       (partial_sum),
        .done              (calc_done)
    );

    accumulator u_accumulator (
        .clk      (clk),
        .rst_n    (rst_n),

        .clear    (acc_clear),
        .enable   (acc_en),

        .data_in  (partial_sum),
        .data_out (accumulated_result)
    );

endmodule