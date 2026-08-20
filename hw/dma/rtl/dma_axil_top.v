`resetall
`timescale 1ns / 1ps
`default_nettype none

module dma_axil_top #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter FIFO_DEPTH = 16
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

    output wire [    ADDR_WIDTH-1:0] m_axil_awaddr,
    output wire [               2:0] m_axil_awprot,
    output wire                      m_axil_awvalid,
    input  wire                      m_axil_awready,
    output wire [    DATA_WIDTH-1:0] m_axil_wdata,
    output wire [(DATA_WIDTH/8)-1:0] m_axil_wstrb,
    output wire                      m_axil_wvalid,
    input  wire                      m_axil_wready,
    input  wire [               1:0] m_axil_bresp,
    input  wire                      m_axil_bvalid,
    output wire                      m_axil_bready,

    output wire [    ADDR_WIDTH-1:0] m_axil_araddr,
    output wire [               2:0] m_axil_arprot,
    output wire                      m_axil_arvalid,
    input  wire                      m_axil_arready,
    input  wire [    DATA_WIDTH-1:0] m_axil_rdata,
    input  wire [               1:0] m_axil_rresp,
    input  wire                      m_axil_rvalid,
    output wire                      m_axil_rready
);

    wire                      dma_valid;
    wire [    ADDR_WIDTH-1:0] dma_addr;
    wire                      dma_write;
    wire [    DATA_WIDTH-1:0] dma_wdata;
    wire [(DATA_WIDTH/8)-1:0] dma_wstrb;
    wire                      dma_ready;
    wire [    DATA_WIDTH-1:0] dma_rdata;
    wire                      dma_error;

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

        .m_valid(dma_valid),
        .m_addr (dma_addr),
        .m_write(dma_write),
        .m_wdata(dma_wdata),
        .m_wstrb(dma_wstrb),
        .m_ready(dma_ready),
        .m_rdata(dma_rdata),
        .m_error(dma_error)
    );

    dma_reg_top #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_dma (
        .clock(clock),
        .reset(reset),

        .interrupt(interrupt),

        .s_valid(dma_valid),
        .s_addr (dma_addr),
        .s_write(dma_write),
        .s_wdata(dma_wdata),
        .s_wstrb(dma_wstrb),
        .s_ready(dma_ready),
        .s_rdata(dma_rdata),
        .s_error(dma_error),

        .m_axil_awaddr (m_axil_awaddr),
        .m_axil_awprot (m_axil_awprot),
        .m_axil_awvalid(m_axil_awvalid),
        .m_axil_awready(m_axil_awready),
        .m_axil_wdata  (m_axil_wdata),
        .m_axil_wstrb  (m_axil_wstrb),
        .m_axil_wvalid (m_axil_wvalid),
        .m_axil_wready (m_axil_wready),
        .m_axil_bresp  (m_axil_bresp),
        .m_axil_bvalid (m_axil_bvalid),
        .m_axil_bready (m_axil_bready),

        .m_axil_araddr (m_axil_araddr),
        .m_axil_arprot (m_axil_arprot),
        .m_axil_arvalid(m_axil_arvalid),
        .m_axil_arready(m_axil_arready),
        .m_axil_rdata  (m_axil_rdata),
        .m_axil_rresp  (m_axil_rresp),
        .m_axil_rvalid (m_axil_rvalid),
        .m_axil_rready (m_axil_rready)
    );

endmodule

`resetall
