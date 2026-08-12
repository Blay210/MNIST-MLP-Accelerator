`timescale 1ns/1ps

module activation_bram_model #(
    parameter int DEPTH = 784 / 4
)(
    input logic clk,

    // ==========================================
    // Port A : Accelerator side
    // Read / Write
    // byte-addressed
    // ==========================================
    input  logic [31:0]       a_addr,
    input  logic              a_en,
    input  logic [3:0]        a_we,
    input  mnist_pkg::word_t  a_wdata,
    output mnist_pkg::word_t  a_rdata,

    // ==========================================
    // Port B : Host/Testbench side
    // Read / Write
    // byte-addressed
    // ==========================================
    input  logic [31:0]       b_addr,
    input  logic              b_en,
    input  logic [3:0]        b_we,
    input  mnist_pkg::word_t  b_wdata,
    output mnist_pkg::word_t  b_rdata
);

    import mnist_pkg::*;

    localparam int ADDR_W = $clog2(DEPTH);

    word_t mem [0:DEPTH-1];

    logic [ADDR_W-1:0] a_word_addr;
    logic [ADDR_W-1:0] b_word_addr;

    assign a_word_addr = a_addr[ADDR_W+1:2];
    assign b_word_addr = b_addr[ADDR_W+1:2];

    always_ff @(posedge clk) begin

        // Accelerator Port A
        if (a_en) begin
            for (int b = 0; b < 4; b++) begin
                if (a_we[b])
                    mem[a_word_addr][b*8 +: 8]
                        <= a_wdata[b*8 +: 8];
            end

            a_rdata <= mem[a_word_addr];
        end

        // Host Port B
        if (b_en) begin
            for (int b = 0; b < 4; b++) begin
                if (b_we[b])
                    mem[b_word_addr][b*8 +: 8]
                        <= b_wdata[b*8 +: 8];
            end

            b_rdata <= mem[b_word_addr];
        end
    end

endmodule
