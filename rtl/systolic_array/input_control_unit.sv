`timescale 1ns/1ps

module input_control_unit (
    input  logic clk,
    input  logic rst_n,
    input  mnist_pkg::sys_state_t input_ctrl,
    input  mnist_pkg::data_vec_t  data_in,

    output mnist_pkg::data_vec_t  data_out
);

    import mnist_pkg::*;

    data_vec_t buffer;

    logic [PE_DIM-1:0] lane_en;
    logic calc;

    always_comb begin
        data_out = '{default:'0};

        case (input_ctrl)

            SYS_LOAD: begin
                data_out = data_in;
            end

            SYS_CALC: begin
                for (int i = 0; i < PE_DIM; i++) begin
                    if (lane_en[i])
                        data_out[i] = buffer[i];
                end
            end

            default: begin
                data_out = '{default:'0};
            end

        endcase
    end


    // Input capture
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer <= '{default:'0};
        end
        else begin
            if (input_ctrl == SYS_LOAD)
                buffer <= data_in;

            else if (input_ctrl == SYS_CALC && !calc)
                buffer <= data_in;
        end
    end


    // One-hot skew control
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lane_en <= '0;
            calc    <= 1'b0;
        end
        else if (input_ctrl != SYS_CALC) begin
            lane_en <= '0;
            calc    <= 1'b0;
        end
        else begin
            if (!calc) begin
                lane_en <= {{(PE_DIM-1){1'b0}}, 1'b1};
                calc    <= 1'b1;
            end

            else if (lane_en[PE_DIM-1]) begin
                lane_en <= '0;
            end

            else if (lane_en != '0) begin
                lane_en <= lane_en << 1;
            end
        end
    end

endmodule
