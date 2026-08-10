`timescale 1ns/1ps

module activation_bram_model #(
    parameter int DEPTH  = 784,
    parameter int ADDR_W = $clog2(DEPTH)
)(
    input logic clk,

    // ==========================================
    // Port A : Accelerator side
    // Read / Write
    // ==========================================
    input  logic                    a_en,
    input  logic                    a_we,
    input  logic [ADDR_W-1:0]       a_addr,
    input  mnist_pkg::data_t        a_wdata,
    output mnist_pkg::data_t        a_rdata,

    // ==========================================
    // Port B : Host / Testbench side
    // Read / Write
    // ==========================================
    input  logic                    b_en,
    input  logic                    b_we,
    input  logic [ADDR_W-1:0]       b_addr,
    input  mnist_pkg::data_t        b_wdata,
    output mnist_pkg::data_t        b_rdata
);

    import mnist_pkg::*;

    data_t mem [0:DEPTH-1];

    always_ff @(posedge clk) begin

        // Accelerator Port A
        if (a_en) begin
            if (a_we) begin
                mem[a_addr] <= a_wdata;
            end

            a_rdata <= mem[a_addr];
        end

        // Host/Testbench Port B
        if (b_en) begin
            if (b_we) begin
                mem[b_addr] <= b_wdata;
            end

            b_rdata <= mem[b_addr];
        end

    end

endmodule