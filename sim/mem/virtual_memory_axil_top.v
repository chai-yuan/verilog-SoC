`resetall
`timescale 1ns / 1ps
`default_nettype none

module virtual_memory_axil_top #(
    parameter integer ADDR_WIDTH    = 32,
    parameter integer DATA_WIDTH    = 32,
    parameter integer DEPTH         = 1024,
    parameter         BASE_ADDR     = 32'h8000_0000,
    parameter         INIT_FILE     = ""
) (
    input wire clock,
    input wire reset,

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
    output wire [               1:0] s_axi_rresp
);

    wire                      memory_valid;
    wire [    ADDR_WIDTH-1:0] memory_addr;
    wire                      memory_write;
    wire [    DATA_WIDTH-1:0] memory_wdata;
    wire [(DATA_WIDTH/8)-1:0] memory_wstrb;
    wire                      memory_ready;
    wire [    DATA_WIDTH-1:0] memory_rdata;
    wire                      memory_error;

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

        .m_valid(memory_valid),
        .m_addr (memory_addr),
        .m_write(memory_write),
        .m_wdata(memory_wdata),
        .m_wstrb(memory_wstrb),
        .m_ready(memory_ready),
        .m_rdata(memory_rdata),
        .m_error(memory_error)
    );

    virtual_memory #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH     (DEPTH),
        .BASE_ADDR (BASE_ADDR),
        .INIT_FILE (INIT_FILE)
    ) u_memory (
        .clock(clock),
        .reset(reset),

        .s_valid(memory_valid),
        .s_addr (memory_addr),
        .s_write(memory_write),
        .s_wdata(memory_wdata),
        .s_wstrb(memory_wstrb),
        .s_ready(memory_ready),
        .s_rdata(memory_rdata),
        .s_error(memory_error)
    );

endmodule

`resetall
