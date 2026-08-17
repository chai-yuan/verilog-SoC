`resetall
`timescale 1ns / 1ps
`default_nettype none

module uart_rx (
    input wire clock,
    input wire reset,

    input wire [15:0] prescale,

    output reg  [7:0] m_axis_tdata,
    output reg        m_axis_tvalid,
    input  wire       m_axis_tready,

    output reg overrun_error,
    output reg frame_error,

    input wire rx
);

    localparam IDLE = 2'd0;
    localparam CHECK_START = 2'd1;
    localparam RECV_DATA = 2'd2;
    localparam CHECK_STOP = 2'd3;

    reg  [ 1:0] state;

    wire [15:0] cycles_per_bit = prescale - 1;
    wire [15:0] cycles_per_half_bit = (prescale >> 1) - 1;

    reg  [15:0] clk_cnt;
    reg  [ 3:0] bit_cnt;

    reg  [ 7:0] shift_reg;

    // 解决来自外部引脚的异步 rx 信号可能导致的亚稳态问题
    reg rx_sync1, rx_sync2;
    always @(posedge clock) begin
        if (reset) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx;
            rx_sync2 <= rx_sync1;
        end
    end

    always @(posedge clock) begin
        if (reset) begin
            state         <= IDLE;
            m_axis_tdata  <= 8'd0;
            m_axis_tvalid <= 1'b0;
            overrun_error <= 1'b0;
            frame_error   <= 1'b0;
            shift_reg     <= 8'd0;
            clk_cnt       <= 0;
            bit_cnt       <= 0;
        end else begin

            if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
            end

            overrun_error <= 1'b0;
            frame_error   <= 1'b0;

            case (state)
                IDLE: begin
                    if (rx_sync2 == 1'b0) begin
                        clk_cnt <= cycles_per_half_bit;
                        state   <= CHECK_START;
                    end
                end

                CHECK_START: begin
                    if (clk_cnt == 0) begin
                        if (rx_sync2 == 1'b0) begin
                            clk_cnt <= cycles_per_bit;
                            bit_cnt <= 8;
                            state   <= RECV_DATA;
                        end else begin
                            // 是毛刺，放弃接收
                            state <= IDLE;
                        end
                    end else begin
                        clk_cnt <= clk_cnt - 1;
                    end
                end

                RECV_DATA: begin
                    if (clk_cnt == 0) begin
                        clk_cnt   <= cycles_per_bit;

                        shift_reg <= {rx_sync2, shift_reg[7:1]};

                        if (bit_cnt == 1) begin
                            state <= CHECK_STOP;
                        end else begin
                            bit_cnt <= bit_cnt - 1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt - 1;
                    end
                end

                CHECK_STOP: begin
                    if (clk_cnt == 0) begin
                        if (rx_sync2 == 1'b1) begin
                            m_axis_tdata  <= shift_reg;
                            m_axis_tvalid <= 1'b1;

                            if (m_axis_tvalid && !m_axis_tready) begin
                                overrun_error <= 1'b1;  // 尚未取出，溢出
                            end
                        end else begin
                            frame_error <= 1'b1;  // 停止位检测错误
                        end

                        state <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt - 1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

`resetall