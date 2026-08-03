`timescale 1ns/1ps

module output_control_unit (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  mnist_pkg::acc_vec_t acc_in,
    output mnist_pkg::acc_vec_t acc_out
);

    import mnist_pkg::*;

    logic harvest;
    int cnt;
    acc_vec_t buffer;

    always_ff @( posedge clk or negedge rst_n ) begin 
        if (!rst_n) begin
            harvest <= 1'b0;
        end
        else if (start) begin
            harvest <= 1'b1;
        end
        else if (cnt >= PE_DIM) begin
            harvest <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= '{default: '0};
            buffer  <= '{default: '0};
        end
        else if (harvest) begin
            if (cnt < PE_DIM) begin
                buffer[cnt] <= acc_in[cnt];
            end
            else if (cnt == PE_DIM) begin
                acc_out <= buffer;
            end
        end
    end

    always_ff @( posedge clk or negedge rst_n ) begin
        if (!rst_n) begin
            cnt <= 0;
        end
        else if (harvest) begin
            cnt <= cnt + 1;
        end
        else begin
            cnt <= 0;
        end
    end

    
endmodule