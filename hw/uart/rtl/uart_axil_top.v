`timescale 1ns / 1ps

module uart_axil_top #(
    parameter ADDR_WIDTH       = 32,
    parameter DATA_WIDTH       = 32,
    parameter TX_FIFO_DEPTH    = 16,
    parameter RX_FIFO_DEPTH    = 16,
    parameter DEFAULT_PRESCALE = 16'd50
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

    input  wire rx,
    output wire tx
);

    wire                      uart_valid;
    wire [    ADDR_WIDTH-1:0] uart_addr;
    wire                      uart_write;
    wire [    DATA_WIDTH-1:0] uart_wdata;
    wire [(DATA_WIDTH/8)-1:0] uart_wstrb;
    wire                      uart_ready;
    wire [    DATA_WIDTH-1:0] uart_rdata;
    wire                      uart_error;

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

        .m_valid(uart_valid),
        .m_addr (uart_addr),
        .m_write(uart_write),
        .m_wdata(uart_wdata),
        .m_wstrb(uart_wstrb),
        .m_ready(uart_ready),
        .m_rdata(uart_rdata),
        .m_error(uart_error)
    );

    uart_reg_top #(
        .ADDR_WIDTH      (ADDR_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .TX_FIFO_DEPTH   (TX_FIFO_DEPTH),
        .RX_FIFO_DEPTH   (RX_FIFO_DEPTH),
        .DEFAULT_PRESCALE(DEFAULT_PRESCALE)
    ) u_uart (
        .clock(clock),
        .reset(reset),

        .interrupt(interrupt),

        .s_valid(uart_valid),
        .s_addr (uart_addr),
        .s_write(uart_write),
        .s_wdata(uart_wdata),
        .s_wstrb(uart_wstrb),
        .s_ready(uart_ready),
        .s_rdata(uart_rdata),
        .s_error(uart_error),

        .rx(rx),
        .tx(tx)
    );

endmodule
