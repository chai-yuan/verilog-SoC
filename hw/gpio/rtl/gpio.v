`resetall
`timescale 1ns / 1ps
`default_nettype none

module gpio #(
    parameter integer IO_NUM = 8
) (
    input wire clock,
    input wire reset,

    input  wire [IO_NUM-1:0] direction,         // 1：输出，0：输入
    input  wire [IO_NUM-1:0] output_data,
    output wire [IO_NUM-1:0] input_data,

    input wire [IO_NUM-1:0] interrupt_enable,   // 仅用于逐位屏蔽 interrupt 输出
    input wire [2*IO_NUM-1:0] interrupt_type,   // 每位编码：00 低电平，01 高电平，10 下降沿，11 上升沿
    // 该信号必须由本模块 clock 域的同步逻辑产生，高电平有效，持续至少一个时钟周期。
    input wire interrupt_clear,
    output reg [IO_NUM-1:0] interrupt_status,   // 不受 interrupt_enable 影响的原始锁存状态
    output wire interrupt,                      // 所有已使能中断状态的按位或

    input  wire [IO_NUM-1:0] gpio_i,
    output wire [IO_NUM-1:0] gpio_o,
    output wire [IO_NUM-1:0] gpio_oe  // 高电平输出使能：~reset & direction
);

    localparam INTERRUPT_LOW_LEVEL = 2'b00;
    localparam INTERRUPT_HIGH_LEVEL = 2'b01;
    localparam INTERRUPT_FALLING_EDGE = 2'b10;
    localparam INTERRUPT_RISING_EDGE = 2'b11;

    reg     [IO_NUM-1:0] gpio_sync1;
    reg     [IO_NUM-1:0] gpio_sync2;
    reg     [IO_NUM-1:0] gpio_sync_prev;
    reg     [       2:0] sync_valid;

    reg     [IO_NUM-1:0] interrupt_event;
    integer              i;

    initial begin
        if (IO_NUM < 1 || IO_NUM > 32) begin
            $error("Error: IO_NUM must be between 1 and 32 (instance %m)");
            $finish;
        end
    end

    assign input_data = gpio_sync2;
    assign gpio_o = output_data;
    assign gpio_oe = {IO_NUM{!reset}} & direction;

    assign interrupt = !reset && |(interrupt_status & interrupt_enable);

    // 两级同步器持续采样，使 input_data 始终反映经过同步的引脚输入。
    always @(posedge clock) begin
        if (reset) begin
            gpio_sync1    <= {IO_NUM{1'b0}};
            gpio_sync2    <= {IO_NUM{1'b0}};
            gpio_sync_prev <= {IO_NUM{1'b0}};
            sync_valid    <= 3'b000;
        end else begin
            gpio_sync1     <= gpio_i;
            gpio_sync2     <= gpio_sync1;
            gpio_sync_prev <= gpio_sync2;
            sync_valid     <= {sync_valid[1:0], 1'b1};
        end
    end

    // 等待同步及历史采样有效后再检测中断，避免复位后产生伪边沿。
    always @* begin
        interrupt_event = {IO_NUM{1'b0}};

        if (sync_valid[2]) begin
            for (i = 0; i < IO_NUM; i = i + 1) begin
                case (interrupt_type[(i*2)+:2])
                    INTERRUPT_LOW_LEVEL:    interrupt_event[i] = !gpio_sync2[i];
                    INTERRUPT_HIGH_LEVEL:   interrupt_event[i] = gpio_sync2[i];
                    INTERRUPT_FALLING_EDGE: interrupt_event[i] = gpio_sync_prev[i] && !gpio_sync2[i];
                    INTERRUPT_RISING_EDGE:  interrupt_event[i] = !gpio_sync_prev[i] && gpio_sync2[i];
                    default:                interrupt_event[i] = 1'b0;
                endcase
            end
        end
    end

    // 新中断事件与状态清除同时发生时，新事件优先。
    always @(posedge clock) begin
        if (reset) begin
            interrupt_status <= {IO_NUM{1'b0}};
        end else begin
            interrupt_status <= (interrupt_status & {IO_NUM{!interrupt_clear}}) | interrupt_event;
        end
    end

endmodule

`resetall