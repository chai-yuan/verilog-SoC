`resetall
`timescale 1ns / 1ps
`default_nettype none

module spi_reg_top #(
    parameter integer ADDR_WIDTH              = 32,
    parameter integer DATA_WIDTH              = 32,
    parameter integer SPI_DATA_WIDTH          = 32,
    parameter integer DEFAULT_PRESCALE        = 1,
    parameter integer DEFAULT_TRANSFER_LENGTH = SPI_DATA_WIDTH
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

    output wire SCK,
    output wire SS,
    output wire MOSI,
    input  wire MISO
);

    localparam [7:0] ADDR_CONFIG   = 8'h00;
    localparam [7:0] ADDR_PRESCALE = 8'h04;
    localparam [7:0] ADDR_DATA     = 8'h08;
    localparam [7:0] ADDR_SS       = 8'h0C;
    localparam integer SPI_LENGTH_WIDTH =
        (SPI_DATA_WIDTH < 2) ? 1 : $clog2(SPI_DATA_WIDTH + 1);
    localparam [7:0] DEFAULT_PRESCALE_VALUE = 8'(DEFAULT_PRESCALE);

    reg [31:0] config_reg;
    reg [7:0]  prescale_reg;
    reg [31:0] data_reg;
    reg        ss_reg;

    wire [7:0] register_addr = {s_addr[7:2], 2'b00};
    wire addr_in_range;
    wire addr_mapped;
    wire addr_valid;
    wire write_fire;
    wire data_write_fire;
    wire [31:0] data_write_value;

    wire spi_cmd_ready;
    wire spi_rsp_valid;
    wire [SPI_DATA_WIDTH-1:0] spi_rsp_data;

    generate
        if (ADDR_WIDTH > 8) begin : g_addr_range_check
            assign addr_in_range = (s_addr[ADDR_WIDTH-1:8] == {(ADDR_WIDTH-8){1'b0}});
        end else begin : g_addr_range_always_ok
            assign addr_in_range = 1'b1;
        end
    endgenerate

    assign addr_mapped = (register_addr == ADDR_CONFIG) ||
                         (register_addr == ADDR_PRESCALE) ||
                         (register_addr == ADDR_DATA) ||
                         (register_addr == ADDR_SS);
    assign addr_valid = addr_in_range && addr_mapped;

    // 数据寄存器在 SPI 忙时等待命令接口可接收，其他寄存器为零等待访问。
    assign s_ready = !(s_write && addr_valid && (register_addr == ADDR_DATA) &&
                       (s_wstrb != 0)) || spi_cmd_ready;
    assign s_error = s_valid && !addr_valid;

    assign write_fire = s_valid && s_ready && s_write && addr_valid;
    assign data_write_fire = write_fire && (register_addr == ADDR_DATA) &&
                             (s_wstrb != 0);

    function [31:0] write_bytes;
        input [31:0] current_value;
        input [31:0] write_data;
        input [3:0]  write_strobe;
        reg [31:0] byte_mask;
        begin
            byte_mask = {
                {8{write_strobe[3]}}, {8{write_strobe[2]}},
                {8{write_strobe[1]}}, {8{write_strobe[0]}}
            };
            write_bytes = (current_value & ~byte_mask) | (write_data & byte_mask);
        end
    endfunction

    assign data_write_value = write_bytes(data_reg, s_wdata[31:0], s_wstrb[3:0]);

    reg [31:0] read_data;
    always @* begin
        read_data = 32'b0;
        if (!s_write && addr_valid) begin
            case (register_addr)
                ADDR_CONFIG:   read_data = config_reg;
                ADDR_PRESCALE: read_data = {24'b0, prescale_reg};
                ADDR_DATA:     read_data = data_reg;
                ADDR_SS:       read_data = {31'b0, ss_reg};
                default:       read_data = 32'b0;
            endcase
        end
    end

    assign s_rdata   = read_data;
    assign SS        = ss_reg;
    assign interrupt = spi_rsp_valid;

    always @(posedge clock) begin
        if (reset) begin
            config_reg   <= (DEFAULT_TRANSFER_LENGTH & 32'h0000_00ff) << 8;
            prescale_reg <= DEFAULT_PRESCALE_VALUE;
            data_reg     <= 32'b0;
            ss_reg       <= 1'b1;
        end else begin
            if (write_fire && (register_addr == ADDR_CONFIG)) begin
                config_reg <= write_bytes(config_reg, s_wdata[31:0], s_wstrb[3:0]);
            end
            if (write_fire && (register_addr == ADDR_PRESCALE)) begin
                prescale_reg <= write_bytes(
                    {24'b0, prescale_reg}, s_wdata[31:0], s_wstrb[3:0]
                )[7:0];
            end
            if (write_fire && (register_addr == ADDR_SS) && s_wstrb[0]) begin
                ss_reg <= s_wdata[0];
            end
            if (data_write_fire) begin
                data_reg <= data_write_value;
            end
            if (spi_rsp_valid) begin
                data_reg <= {{(32-SPI_DATA_WIDTH){1'b0}}, spi_rsp_data};
            end
        end
    end

    spi_master #(
        .DATA_WIDTH(SPI_DATA_WIDTH)
    ) u_spi_master (
        .clock         (clock),
        .reset         (reset),
        .prescale      (prescale_reg),
        .cpol          (config_reg[0]),
        .cpha          (config_reg[1]),
        .cmd_valid     (data_write_fire),
        .cmd_ready     (spi_cmd_ready),
        .cmd_data      (data_write_value[SPI_DATA_WIDTH-1:0]),
        .cmd_bits      (config_reg[8+SPI_LENGTH_WIDTH-1:8]),
        .cmd_cs_autofree(1'b0),
        .rsp_valid     (spi_rsp_valid),
        .rsp_ready     (1'b1),
        .rsp_data      (spi_rsp_data),
        .SCK           (SCK),
        .SS            (),
        .MOSI          (MOSI),
        .MISO          (MISO)
    );

    initial begin
        if (ADDR_WIDTH < 8) begin
            $error("Error: ADDR_WIDTH must be at least 8 (instance %m)");
            $finish;
        end
        if (DATA_WIDTH != 32) begin
            $error("Error: DATA_WIDTH must be 32 (instance %m)");
            $finish;
        end
        if (SPI_DATA_WIDTH < 1 || SPI_DATA_WIDTH > 32) begin
            $error("Error: SPI_DATA_WIDTH must be between 1 and 32 (instance %m)");
            $finish;
        end
        if (DEFAULT_PRESCALE < 0 || DEFAULT_PRESCALE > 255) begin
            $error("Error: DEFAULT_PRESCALE must fit in 8 bits (instance %m)");
            $finish;
        end
        if (DEFAULT_TRANSFER_LENGTH < 1 || DEFAULT_TRANSFER_LENGTH > SPI_DATA_WIDTH) begin
            $error("Error: DEFAULT_TRANSFER_LENGTH must be in the SPI data width range (instance %m)");
            $finish;
        end
    end

endmodule

`resetall
