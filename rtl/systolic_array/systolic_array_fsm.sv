`timescale 1ns/1ps

module systolic_array_fsm (
    input  logic clk,
    input  logic rst_n,
    input  logic load_weight,
    input  logic start_calc,

    output logic done,
    output logic result_out,
    output mnist_pkg::sys_state_t state
);

    import mnist_pkg::*;

    sys_state_t current_state, next_state;

    int calc_cnt;

    assign state = current_state;
    assign result_out = (calc_cnt == PE_DIM)
                      ? 1'b1
                      : 1'b0;

    always_comb begin : next_state_control
        next_state = current_state;
        done = 1'b0;

        unique case (current_state)
            SYS_IDLE: begin
                if (load_weight) begin
                    next_state = SYS_LOAD;
                end
            end
            SYS_LOAD: begin
                if (start_calc) begin
                    next_state = SYS_CALC;
                end
            end
            SYS_CALC: begin
                if (calc_cnt == PE_DIM*2) next_state = SYS_DONE;
            end
            SYS_DONE: begin
                done = 1;
                next_state = SYS_IDLE;
            end
            default: next_state = SYS_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin : state_transition
        if (!rst_n) begin
            current_state <= SYS_IDLE;
        end
        else begin
            current_state <= next_state;
        end
    end

    always_ff @( posedge clk or negedge rst_n ) begin
        if (!rst_n) begin
            calc_cnt <= 0;
        end
        else if (current_state == SYS_CALC) begin
            calc_cnt <= calc_cnt + 1;
        end
        else begin
            calc_cnt <= 0;
        end
    end



    
    
endmodule
