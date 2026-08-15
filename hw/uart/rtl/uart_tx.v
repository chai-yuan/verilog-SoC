`timescale 1ns / 1ps

module uart_tx (
    input wire clock,
    input wire reset,

    input wire [15:0] prescale,

    input  wire [7:0] s_axis_tdata,
    input  wire       s_axis_tvalid,
    output reg        s_axis_tready,

    output wire tx
);

    localparam IDLE = 1'b0;  // 空闲
    localparam SEND = 1'b1;  // 发送
    reg state;

    wire [15:0] cycles_per_bit = prescale - 1;
    reg [15:0] clk_cnt;  // 记录当前 Bit 维持了多少个时钟周期

    reg [9:0] shift_reg;
    reg [3:0] bit_cnt;  // 记录还需要发送多少位

    assign tx = shift_reg[0];

    always @(posedge clock) begin
        if (reset) begin
            state         <= IDLE;
            s_axis_tready <= 1'b0;
            shift_reg     <= 10'b11_1111_1111;  // 复位时全为1，确保 tx 空闲时为高电平
            clk_cnt       <= 0;
            bit_cnt       <= 0;
        end else begin
            case (state)
                IDLE: begin
                    s_axis_tready <= 1'b1;

                    if (s_axis_tvalid && s_axis_tready) begin
                        s_axis_tready <= 1'b0;

                        shift_reg <= {1'b1, s_axis_tdata, 1'b0};
                        bit_cnt <= 10;     // 接下来要发送 10 个 bit

                        clk_cnt <= cycles_per_bit;
                        state   <= SEND;
                    end
                end

                SEND: begin
                    if (clk_cnt == 0) begin
                        clk_cnt   <= cycles_per_bit;
                        bit_cnt   <= bit_cnt - 1;

                        shift_reg <= {1'b1, shift_reg[9:1]};

                        if (bit_cnt == 0) begin
                            state <= IDLE;
                        end
                    end else begin
                        clk_cnt <= clk_cnt - 1;
                    end
                end
            endcase
        end
    end

endmodule
