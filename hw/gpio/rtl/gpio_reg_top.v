`timescale 1ns / 1ps

module gpio_reg_top #(
    parameter integer IO_NUM     = 8,
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32
) (
    input wire clock,
    input wire reset,

    output wire interrupt,

    input  wire                      s_valid,
    input  wire [    ADDR_WIDTH-1:0] s_addr,
    input  wire                      s_write,
    input  wire [    DATA_WIDTH-1:0] s_wdata,
    input  wire [(DATA_WIDTH/8)-1:0] s_wstrb,
    output wire                      s_ready,
    output wire [    DATA_WIDTH-1:0] s_rdata,
    output wire                      s_error,

    input  wire [IO_NUM-1:0] gpio_i,
    output wire [IO_NUM-1:0] gpio_o,
    output wire [IO_NUM-1:0] gpio_oe
);

    localparam [7:0] ADDR_INPUT_DATA = 8'h00;
    localparam [7:0] ADDR_OUTPUT_DATA = 8'h04;
    localparam [7:0] ADDR_DIRECTION = 8'h08;
    localparam [7:0] ADDR_INTERRUPT_ENABLE = 8'h0C;
    localparam [7:0] ADDR_INTERRUPT_TYPE_LOW = 8'h10;
    localparam [7:0] ADDR_INTERRUPT_TYPE_HIGH = 8'h14;
    localparam [7:0] ADDR_INTERRUPT_STATUS = 8'h18;
    localparam [7:0] ADDR_INTERRUPT_CLEAR = 8'h1C;

    localparam [31:0] RESET_ZERO = 32'h0000_0000;
    localparam [31:0] RESET_ALL = 32'hFFFF_FFFF;

    localparam [31:0] INTERRUPT_TYPE_LOW_MASK =
        (IO_NUM >= 16) ? 32'hFFFF_FFFF : (32'hFFFF_FFFF >> (32 - 2 * IO_NUM));
    localparam [31:0] INTERRUPT_TYPE_HIGH_MASK =
        (IO_NUM <= 16) ? 32'h0000_0000 : (32'hFFFF_FFFF >> (64 - 2 * IO_NUM));

    reg [IO_NUM-1:0] output_data_reg;
    reg [IO_NUM-1:0] direction_reg;
    reg [IO_NUM-1:0] interrupt_enable_reg;
    reg [      31:0] interrupt_type_low_reg;
    reg [      31:0] interrupt_type_high_reg;

    wire [IO_NUM-1:0] input_data;
    wire [IO_NUM-1:0] interrupt_status;
    wire [(2*IO_NUM)-1:0] interrupt_type_value;

    wire [31:0] input_data_value = {{(32 - IO_NUM) {1'b0}}, input_data};
    wire [31:0] output_data_value = {{(32 - IO_NUM) {1'b0}}, output_data_reg};
    wire [31:0] direction_value = {{(32 - IO_NUM) {1'b0}}, direction_reg};
    wire [31:0] interrupt_enable_value = {{(32 - IO_NUM) {1'b0}}, interrupt_enable_reg};
    wire [31:0] interrupt_status_value = {{(32 - IO_NUM) {1'b0}}, interrupt_status};
    wire [7:0] register_addr = {s_addr[7:2], 2'b00};

    wire addr_in_range;
    generate
        if (ADDR_WIDTH > 8) begin : g_addr_range_check
            assign addr_in_range = (s_addr[ADDR_WIDTH-1:8] == {(ADDR_WIDTH-8) {1'b0}});
        end else begin : g_addr_range_always_ok
            assign addr_in_range = 1'b1;
        end
    endgenerate

    wire addr_mapped =  (register_addr == ADDR_INPUT_DATA) ||
                        (register_addr == ADDR_OUTPUT_DATA) ||
                        (register_addr == ADDR_DIRECTION) ||
                        (register_addr == ADDR_INTERRUPT_ENABLE) ||
                        (register_addr == ADDR_INTERRUPT_TYPE_LOW) ||
                        (register_addr == ADDR_INTERRUPT_TYPE_HIGH) ||
                        (register_addr == ADDR_INTERRUPT_STATUS) ||
                        (register_addr == ADDR_INTERRUPT_CLEAR);
    wire addr_valid = addr_in_range && addr_mapped;

    assign s_ready = 1'b1;
    assign s_error = s_valid && !addr_valid;

    wire write_fire = s_valid && s_ready && s_write && addr_valid;
    wire interrupt_clear_pulse = write_fire && (register_addr == ADDR_INTERRUPT_CLEAR) && s_wstrb[0] && s_wdata[0];

    reg [31:0] read_data;

    function [31:0] write_bytes;
        input [31:0] current_value;
        input [31:0] write_data;
        input [ 3:0] write_strobe;
        reg [31:0] byte_mask;
        begin
            byte_mask = {
                {8{write_strobe[3]}}, {8{write_strobe[2]}}, {8{write_strobe[1]}}, {8{write_strobe[0]}}
            };
            write_bytes = (current_value & ~byte_mask) | (write_data & byte_mask);
        end
    endfunction

    initial begin
        if (IO_NUM < 1 || IO_NUM > 32) begin
            $error("Error: IO_NUM must be between 1 and 32 (instance %m)");
            $finish;
        end
        if (ADDR_WIDTH < 8) begin
            $error("Error: ADDR_WIDTH must be at least 8 (instance %m)");
            $finish;
        end
        if (DATA_WIDTH != 32) begin
            $error("Error: DATA_WIDTH must be 32 (instance %m)");
            $finish;
        end
    end

    // 简单总线采用零等待响应，每个 s_valid && s_ready 周期表示一次完成的事务。
    assign s_rdata = read_data;

    generate
        if (IO_NUM <= 16) begin : g_interrupt_type_low_only
            assign interrupt_type_value = interrupt_type_low_reg[(2*IO_NUM)-1:0];
        end else begin : g_interrupt_type_low_high
            assign interrupt_type_value = {
                interrupt_type_high_reg[(2*(IO_NUM-16))-1:0], interrupt_type_low_reg
            };
        end
    endgenerate

    // 配置寄存器支持按字节写入，只读和未映射地址的写操作被忽略。
    always @(posedge clock) begin
        if (reset) begin
            output_data_reg         <= {IO_NUM{1'b0}};
            direction_reg           <= {IO_NUM{1'b0}};
            interrupt_enable_reg    <= {IO_NUM{1'b0}};
            interrupt_type_low_reg  <= RESET_ALL;
            interrupt_type_high_reg <= RESET_ALL;
        end else if (write_fire) begin
        case (register_addr)
            ADDR_OUTPUT_DATA:
            output_data_reg <= write_bytes(output_data_value, s_wdata[31:0], s_wstrb[3:0])[IO_NUM-1:0];
            ADDR_DIRECTION:
            direction_reg <= write_bytes(direction_value, s_wdata[31:0], s_wstrb[3:0])[IO_NUM-1:0];
            ADDR_INTERRUPT_ENABLE:
            interrupt_enable_reg <= write_bytes(interrupt_enable_value, s_wdata[31:0], s_wstrb[3:0])[IO_NUM-1:0];
            ADDR_INTERRUPT_TYPE_LOW:
            interrupt_type_low_reg <= write_bytes(interrupt_type_low_reg, s_wdata[31:0], s_wstrb[3:0]);
            ADDR_INTERRUPT_TYPE_HIGH:
            interrupt_type_high_reg <= write_bytes(interrupt_type_high_reg, s_wdata[31:0], s_wstrb[3:0]);
            default: begin
            end
            endcase
        end
    end

    // 所有寄存器读取均为组合逻辑，未映射地址读取为零。
    always @* begin
        read_data = RESET_ZERO;

        if (!s_write && addr_valid) begin
            case (register_addr)
                ADDR_INPUT_DATA:         read_data = input_data_value;
                ADDR_OUTPUT_DATA:        read_data = output_data_value;
                ADDR_DIRECTION:          read_data = direction_value;
                ADDR_INTERRUPT_ENABLE:   read_data = interrupt_enable_value;
                ADDR_INTERRUPT_TYPE_LOW: read_data = interrupt_type_low_reg & INTERRUPT_TYPE_LOW_MASK;
                ADDR_INTERRUPT_TYPE_HIGH:read_data = interrupt_type_high_reg & INTERRUPT_TYPE_HIGH_MASK;
                ADDR_INTERRUPT_STATUS:   read_data = interrupt_status_value;
                default:                 read_data = RESET_ZERO;
            endcase
        end
    end

    gpio #(
        .IO_NUM(IO_NUM)
    ) u_gpio (
        .clock(clock),
        .reset(reset),

        .direction  (direction_reg),
        .output_data(output_data_reg),
        .input_data (input_data),

        .interrupt_enable(interrupt_enable_reg),
        .interrupt_type  (interrupt_type_value),
        .interrupt_clear (interrupt_clear_pulse),
        .interrupt_status(interrupt_status),
        .interrupt       (interrupt),

        .gpio_i (gpio_i),
        .gpio_o (gpio_o),
        .gpio_oe(gpio_oe)
    );

endmodule
