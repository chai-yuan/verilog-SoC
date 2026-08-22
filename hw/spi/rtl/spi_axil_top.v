`resetall
`timescale 1ns / 1ps
`default_nettype none

module spi_axil_top #(
    parameter integer ADDR_WIDTH              = 32,
    parameter integer DATA_WIDTH              = 32,
    parameter integer SPI_DATA_WIDTH          = 32,
    parameter integer DEFAULT_PRESCALE        = 1,
    parameter integer DEFAULT_TRANSFER_LENGTH = SPI_DATA_WIDTH
) (
    input wire clock,
    input wire reset,

    output wire interrupt,

    input  wire                      s_axi_awvalid,
    output wire                      s_axi_awready,
    input  wire [    ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire [               2:0] s_axi_awprot,
    input  wire                      s_axi_wvalid,
    output wire                      s_axi_wready,
    input  wire [    DATA_WIDTH-1:0] s_axi_wdata,
    input  wire [(DATA_WIDTH/8)-1:0] s_axi_wstrb,
    output wire                      s_axi_bvalid,
    input  wire                      s_axi_bready,
    output wire [               1:0] s_axi_bresp,
    input  wire                      s_axi_arvalid,
    output wire                      s_axi_arready,
    input  wire [    ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire [               2:0] s_axi_arprot,
    output wire                      s_axi_rvalid,
    input  wire                      s_axi_rready,
    output wire [    DATA_WIDTH-1:0] s_axi_rdata,
    output wire [               1:0] s_axi_rresp,

    output wire SCK,
    output wire SS,
    output wire MOSI,
    input  wire MISO
);

    wire                      spi_valid;
    wire [    ADDR_WIDTH-1:0] spi_addr;
    wire                      spi_write;
    wire [    DATA_WIDTH-1:0] spi_wdata;
    wire [(DATA_WIDTH/8)-1:0] spi_wstrb;
    wire                      spi_ready;
    wire [    DATA_WIDTH-1:0] spi_rdata;
    wire                      spi_error;

    axil2reg #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_axil2reg (
        .clock(clock),
        .reset(reset),

        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_awaddr (s_axi_awaddr),
        .s_axi_awprot (s_axi_awprot),

        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_wdata (s_axi_wdata),
        .s_axi_wstrb (s_axi_wstrb),

        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_bresp (s_axi_bresp),

        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_araddr (s_axi_araddr),
        .s_axi_arprot (s_axi_arprot),

        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .s_axi_rdata (s_axi_rdata),
        .s_axi_rresp (s_axi_rresp),

        .m_valid(spi_valid),
        .m_addr (spi_addr),
        .m_write(spi_write),
        .m_wdata(spi_wdata),
        .m_wstrb(spi_wstrb),
        .m_ready(spi_ready),
        .m_rdata(spi_rdata),
        .m_error(spi_error)
    );

    spi_reg_top #(
        .ADDR_WIDTH             (ADDR_WIDTH),
        .DATA_WIDTH             (DATA_WIDTH),
        .SPI_DATA_WIDTH         (SPI_DATA_WIDTH),
        .DEFAULT_PRESCALE       (DEFAULT_PRESCALE),
        .DEFAULT_TRANSFER_LENGTH(DEFAULT_TRANSFER_LENGTH)
    ) u_spi_reg_top (
        .clock(clock),
        .reset(reset),

        .interrupt(interrupt),

        .s_valid(spi_valid),
        .s_addr (spi_addr),
        .s_write(spi_write),
        .s_wdata(spi_wdata),
        .s_wstrb(spi_wstrb),
        .s_ready(spi_ready),
        .s_rdata(spi_rdata),
        .s_error(spi_error),

        .SCK (SCK),
        .SS  (SS),
        .MOSI(MOSI),
        .MISO(MISO)
    );

endmodule

`resetall
