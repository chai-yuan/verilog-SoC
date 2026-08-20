`resetall
`timescale 1ns / 1ps
`default_nettype none

module axil2reg #(
    parameter DATA_WIDTH    = 32,
    parameter ADDR_WIDTH    = 32,
    parameter STRB_WIDTH    = (DATA_WIDTH/8)
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
    output wire [               1:0] s_axi_rresp,

    output wire                      m_valid,
    output wire [    ADDR_WIDTH-1:0] m_addr,
    output wire                      m_write,
    output wire [    DATA_WIDTH-1:0] m_wdata,
    output wire [(DATA_WIDTH/8)-1:0] m_wstrb,
    input  wire                      m_ready,
    input  wire [    DATA_WIDTH-1:0] m_rdata,
    input  wire                      m_error
);

    localparam ST_IDLE = 3'd0, ST_WRITE = 3'd1, ST_READ = 3'd2, ST_B_RESP = 3'd3, ST_R_RESP = 3'd4;

    reg [               2:0] state;

    reg                      aw_pending;
    reg                      w_pending;
    reg                      ar_pending;

    reg [    ADDR_WIDTH-1:0] latched_addr;
    reg [    DATA_WIDTH-1:0] latched_wdata;
    reg [(DATA_WIDTH/8)-1:0] latched_wstrb;

    reg [    DATA_WIDTH-1:0] latched_rdata;
    reg [               1:0] latched_resp;

    localparam RESP_OKAY = 2'b00;
    localparam RESP_SLVERR = 2'b10;

    // 各请求通道独立握手，READY 仅由寄存状态决定，避免输入到输出的组合路径。
    assign s_axi_awready = !reset && (state == ST_IDLE) && !aw_pending;
    assign s_axi_wready  = !reset && (state == ST_IDLE) && !w_pending;
    assign s_axi_arready = !reset && (state == ST_IDLE) && !ar_pending;

    always @(posedge clock) begin
        if (reset) begin
            state <= ST_IDLE;
            aw_pending <= 1'b0;
            w_pending <= 1'b0;
            ar_pending <= 1'b0;
            latched_addr <= 0;
            latched_wdata <= 0;
            latched_wstrb <= 0;
            latched_rdata <= 0;
            latched_resp <= RESP_OKAY;
        end else begin
            if (s_axi_awready && s_axi_awvalid) begin
                latched_addr <= s_axi_awaddr;
                aw_pending   <= 1'b1;
            end

            if (s_axi_wready && s_axi_wvalid) begin
                latched_wdata <= s_axi_wdata;
                latched_wstrb <= s_axi_wstrb;
                w_pending     <= 1'b1;
            end

            if (s_axi_arready && s_axi_arvalid) begin
                latched_addr <= s_axi_araddr;
                ar_pending   <= 1'b1;
            end

            case (state)
            ST_IDLE: begin
                if (aw_pending && w_pending) begin
                    aw_pending <= 1'b0;
                    w_pending  <= 1'b0;
                    state      <= ST_WRITE;
                end else if (ar_pending) begin
                    ar_pending <= 1'b0;
                    state      <= ST_READ;
                end
            end

            ST_WRITE: begin
                if (m_ready) begin
                    latched_resp <= m_error ? RESP_SLVERR : RESP_OKAY;
                    state        <= ST_B_RESP;
                end
            end

            ST_READ: begin
                if (m_ready) begin
                    latched_rdata <= m_rdata;
                    latched_resp  <= m_error ? RESP_SLVERR : RESP_OKAY;
                    state         <= ST_R_RESP;
                end
            end

            ST_B_RESP: begin
                if (s_axi_bready) begin
                    state <= ST_IDLE;
                end
            end

            ST_R_RESP: begin
                if (s_axi_rready) begin
                    state <= ST_IDLE;
                end
            end

            default: state <= ST_IDLE;
            endcase
        end
    end

    assign m_valid = (state == ST_WRITE) || (state == ST_READ);
    assign m_write = (state == ST_WRITE);
    assign m_addr = latched_addr;
    assign m_wdata = latched_wdata;
    assign m_wstrb = latched_wstrb;

    assign s_axi_bvalid = (state == ST_B_RESP);
    assign s_axi_bresp = latched_resp;

    assign s_axi_rvalid = (state == ST_R_RESP);
    assign s_axi_rdata = latched_rdata;
    assign s_axi_rresp = latched_resp;

endmodule


`resetall
