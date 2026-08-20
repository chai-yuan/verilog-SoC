`resetall
`timescale 1ns / 1ps
`default_nettype none

module axil_dma_wr #(
    parameter DATA_WIDTH = 32,  // AXI-Lite 数据位宽
    parameter ADDR_WIDTH = 32
) (
    input wire clock,
    input wire reset,

    output wire [ADDR_WIDTH-1:0]     m_axil_awaddr,
    output wire [             2:0]   m_axil_awprot,
    output wire                      m_axil_awvalid,
    input  wire                      m_axil_awready,
    output wire [DATA_WIDTH-1:0]     m_axil_wdata,
    output wire [(DATA_WIDTH/8)-1:0] m_axil_wstrb,
    output wire                      m_axil_wvalid,
    input  wire                      m_axil_wready,
    input  wire [             1:0]   m_axil_bresp,
    input  wire                      m_axil_bvalid,
    output wire                      m_axil_bready,

    input  wire       s_axis_tvalid,
    output wire       s_axis_tready,
    input  wire [7:0] s_axis_tdata,
    input  wire       s_axis_tlast,

    // DMA 事务配置信号；write_count 为写事务数，write_size 为每次写入的字节数。
    input wire [                 ADDR_WIDTH-1:0] write_begin,
    input wire [                 ADDR_WIDTH-1:0] write_step,
    input wire [                 ADDR_WIDTH-1:0] write_count,
    input wire [$clog2(DATA_WIDTH/8+1)-1:0]      write_size,

    input  wire write_start,
    output wire write_busy,
    output wire write_error
);

    localparam BYTE_LANES = DATA_WIDTH / 8;
    localparam SIZE_WIDTH = $clog2(BYTE_LANES + 1);
    localparam BYTE_OFFSET_WIDTH = BYTE_LANES > 1 ? $clog2(BYTE_LANES) : 1;
    localparam [SIZE_WIDTH:0] BYTE_LANES_VALUE = {{SIZE_WIDTH{1'b0}}, 1'b1} << (SIZE_WIDTH - 1);

    localparam [1:0] RESP_OKAY = 2'b00;

    localparam [1:0] ST_IDLE   = 2'd0,
                     ST_STREAM = 2'd1,
                     ST_WRITE  = 2'd2,
                     ST_RESP   = 2'd3;

    reg [1:0] state;

    reg [ADDR_WIDTH-1:0] current_addr;
    reg [ADDR_WIDTH-1:0] step_reg;
    reg [ADDR_WIDTH-1:0] writes_remaining;
    reg [SIZE_WIDTH-1:0] size_reg;

    reg [DATA_WIDTH-1:0] data_reg;
    reg [BYTE_LANES-1:0] strb_reg;
    reg [SIZE_WIDTH-1:0] bytes_received;
    reg                  aw_done;
    reg                  w_done;
    reg                  error_reg;

    wire [BYTE_OFFSET_WIDTH-1:0] current_byte_offset;
    generate
        if (BYTE_LANES > 1) begin : gen_byte_offset
            assign current_byte_offset = current_addr[BYTE_OFFSET_WIDTH-1:0];
        end else begin : gen_no_byte_offset
            assign current_byte_offset = {BYTE_OFFSET_WIDTH{1'b0}};
        end
    endgenerate

    wire [SIZE_WIDTH:0] current_offset_ext =
        {{(SIZE_WIDTH+1-BYTE_OFFSET_WIDTH){1'b0}}, current_byte_offset};
    wire [SIZE_WIDTH:0] current_size_ext = {1'b0, size_reg};
    wire [SIZE_WIDTH:0] current_write_end = current_offset_ext + current_size_ext;
    wire [BYTE_OFFSET_WIDTH-1:0] input_byte_lane =
        current_byte_offset + bytes_received[BYTE_OFFSET_WIDTH-1:0];
    wire current_config_valid = size_reg != 0 && current_size_ext <= BYTE_LANES_VALUE &&
                                current_write_end <= BYTE_LANES_VALUE;
    wire expected_tlast = writes_remaining == 1 && bytes_received == size_reg - 1'b1;

    wire aw_handshake = m_axil_awvalid && m_axil_awready;
    wire w_handshake  = m_axil_wvalid && m_axil_wready;

    initial begin
        if (DATA_WIDTH < 8 || DATA_WIDTH % 8 != 0) begin
            $error("Error: DATA_WIDTH must be a multiple of 8 (instance %m)");
            $finish;
        end
        if ((BYTE_LANES & (BYTE_LANES - 1)) != 0) begin
            $error("Error: DATA_WIDTH must contain a power-of-two number of bytes (instance %m)");
            $finish;
        end
        if (ADDR_WIDTH < BYTE_OFFSET_WIDTH) begin
            $error("Error: ADDR_WIDTH is too small for DATA_WIDTH (instance %m)");
            $finish;
        end
    end

    always @(posedge clock) begin
        if (reset) begin
            state            <= ST_IDLE;
            current_addr     <= 0;
            step_reg         <= 0;
            writes_remaining <= 0;
            size_reg         <= 0;
            data_reg         <= 0;
            strb_reg         <= 0;
            bytes_received   <= 0;
            aw_done          <= 1'b0;
            w_done           <= 1'b0;
            error_reg        <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (write_start) begin
                        error_reg <= 1'b0;

                        if (write_count != 0) begin
                            current_addr     <= write_begin;
                            step_reg         <= write_step;
                            writes_remaining <= write_count;
                            size_reg         <= write_size;
                            data_reg         <= 0;
                            strb_reg         <= 0;
                            bytes_received   <= 0;
                            aw_done          <= 1'b0;
                            w_done           <= 1'b0;
                            state            <= ST_STREAM;
                        end
                    end
                end

                ST_STREAM: begin
                    if (!current_config_valid) begin
                        error_reg <= 1'b1;
                        state     <= ST_IDLE;
                    end else if (s_axis_tvalid) begin
                        if (s_axis_tlast != expected_tlast) begin
                            error_reg <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            data_reg[input_byte_lane*8+:8] <= s_axis_tdata;
                            strb_reg[input_byte_lane]      <= 1'b1;

                            if (bytes_received == size_reg - 1'b1) begin
                                bytes_received <= 0;
                                aw_done        <= 1'b0;
                                w_done         <= 1'b0;
                                state          <= ST_WRITE;
                            end else begin
                                bytes_received <= bytes_received + 1'b1;
                            end
                        end
                    end
                end

                ST_WRITE: begin
                    if (aw_handshake)
                        aw_done <= 1'b1;
                    if (w_handshake)
                        w_done <= 1'b1;

                    if ((aw_done || aw_handshake) && (w_done || w_handshake))
                        state <= ST_RESP;
                end

                ST_RESP: begin
                    if (m_axil_bvalid) begin
                        if (m_axil_bresp != RESP_OKAY) begin
                            error_reg <= 1'b1;
                            state     <= ST_IDLE;
                        end else if (writes_remaining == 1) begin
                            writes_remaining <= 0;
                            state            <= ST_IDLE;
                        end else begin
                            current_addr     <= current_addr + step_reg;
                            writes_remaining <= writes_remaining - 1'b1;
                            data_reg         <= 0;
                            strb_reg         <= 0;
                            bytes_received   <= 0;
                            aw_done          <= 1'b0;
                            w_done           <= 1'b0;
                            state            <= ST_STREAM;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    assign m_axil_awaddr  = current_addr;
    assign m_axil_awprot  = 3'b000;
    assign m_axil_awvalid = state == ST_WRITE && !aw_done;
    assign m_axil_wdata   = data_reg;
    assign m_axil_wstrb   = strb_reg;
    assign m_axil_wvalid  = state == ST_WRITE && !w_done;
    assign m_axil_bready  = state == ST_RESP;

    assign s_axis_tready = state == ST_STREAM && current_config_valid;

    assign write_busy  = state != ST_IDLE;
    assign write_error = error_reg;

endmodule

`resetall
