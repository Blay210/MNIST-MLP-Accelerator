`timescale 1ns/1ps

module input_control_unit (
    input  logic clk,
    input  logic rst_n,
    input  mnist_pkg::sys_state_t input_ctrl,
    input  mnist_pkg::data_vec_t  data_in,

    output mnist_pkg::data_vec_t  data_out
);

    import mnist_pkg::*;

    int cnt;
    data_vec_t buffer;
    logic calc;

    always_comb begin
        data_out = '{default: '0};
        unique case (input_ctrl)
            SYS_LOAD: begin
                data_out = data_in;
            end
            SYS_CALC: begin
                if (cnt > 0 && cnt <= PE_DIM) begin
                    data_out[cnt-1] = buffer[cnt-1];
                end
            end
            default: 
                data_out = '{default: '0};
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer   <= '{default: '0};
        end
        else begin
            if ((input_ctrl == SYS_CALC && cnt == 0) || input_ctrl == SYS_LOAD)
                buffer <= data_in;
        end
    end

    always_ff @( posedge clk or negedge rst_n ) begin
        if (!rst_n) begin
            cnt <= 0;
        end
        else if (input_ctrl == SYS_CALC) begin
            cnt <= cnt + 1;
        end
        else begin
            cnt <= 0;
        end
    end
    
endmodule