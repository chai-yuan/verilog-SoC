`timescale 1ns / 1ps

module gpio_axil_top #(
    parameter integer IO_NUM     = 8,
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32
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

    input  wire [IO_NUM-1:0] gpio_i,
    output wire [IO_NUM-1:0] gpio_o,
    output wire [IO_NUM-1:0] gpio_oe
);

    wire                      gpio_valid;
    wire [    ADDR_WIDTH-1:0] gpio_addr;
    wire                      gpio_write;
    wire [    DATA_WIDTH-1:0] gpio_wdata;
    wire [(DATA_WIDTH/8)-1:0] gpio_wstrb;
    wire                      gpio_ready;
    wire [    DATA_WIDTH-1:0] gpio_rdata;
    wire                      gpio_error;

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

        .m_valid(gpio_valid),
        .m_addr (gpio_addr),
        .m_write(gpio_write),
        .m_wdata(gpio_wdata),
        .m_wstrb(gpio_wstrb),
        .m_ready(gpio_ready),
        .m_rdata(gpio_rdata),
        .m_error(gpio_error)
    );

    gpio_reg_top #(
        .IO_NUM    (IO_NUM),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_gpio (
        .clock(clock),
        .reset(reset),

        .interrupt(interrupt),

        .s_valid(gpio_valid),
        .s_addr (gpio_addr),
        .s_write(gpio_write),
        .s_wdata(gpio_wdata),
        .s_wstrb(gpio_wstrb),
        .s_ready(gpio_ready),
        .s_rdata(gpio_rdata),
        .s_error(gpio_error),

        .gpio_i (gpio_i),
        .gpio_o (gpio_o),
        .gpio_oe(gpio_oe)
    );

endmodule
