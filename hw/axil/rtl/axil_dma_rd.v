`resetall
`timescale 1ns / 1ps
`default_nettype none

module axil_dma_rd #(
    parameter DATA_WIDTH = 32,  // AXI-Lite 数据位宽
    parameter ADDR_WIDTH = 32
) (
    input wire clock,
    input wire reset,

    output wire [ADDR_WIDTH-1:0]    m_axil_araddr,
    output wire [             2:0]  m_axil_arprot,
    output wire                     m_axil_arvalid,
    input  wire                     m_axil_arready,
    input  wire [DATA_WIDTH-1:0]    m_axil_rdata,
    input  wire [             1:0]  m_axil_rresp,
    input  wire                     m_axil_rvalid,
    output wire                     m_axil_rready,

    output wire       m_axis_tvalid,
    input  wire       m_axis_tready,
    output wire [7:0] m_axis_tdata,
    output wire       m_axis_tlast,

    // DMA 事务配置信号；read_count 为读事务数，read_size 为每次输出的字节数。
    input wire [                 ADDR_WIDTH-1:0] read_begin,
    input wire [                 ADDR_WIDTH-1:0] read_step,
    input wire [                 ADDR_WIDTH-1:0] read_count,
    input wire [$clog2(DATA_WIDTH/8+1)-1:0]      read_size,

    input  wire read_start,
    output wire read_busy,
    output wire read_error
);

    localparam BYTE_LANES = DATA_WIDTH / 8;
    localparam SIZE_WIDTH = $clog2(BYTE_LANES + 1);
    localparam BYTE_OFFSET_WIDTH = BYTE_LANES > 1 ? $clog2(BYTE_LANES) : 1;
    localparam [SIZE_WIDTH:0] BYTE_LANES_VALUE = {{SIZE_WIDTH{1'b0}}, 1'b1} << (SIZE_WIDTH - 1);

    localparam [1:0] RESP_OKAY = 2'b00;

    localparam [1:0]    ST_IDLE   = 2'd0,
                        ST_AR     = 2'd1,
                        ST_R      = 2'd2,
                        ST_STREAM = 2'd3;

    reg [1:0] state;

    reg [ADDR_WIDTH-1:0] current_addr;
    reg [ADDR_WIDTH-1:0] step_reg;
    reg [ADDR_WIDTH-1:0] reads_remaining;
    reg [SIZE_WIDTH-1:0] size_reg;

    reg [DATA_WIDTH-1:0] data_reg;
    reg [SIZE_WIDTH-1:0] bytes_sent;
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
    wire [SIZE_WIDTH:0] current_read_end = current_offset_ext + current_size_ext;
    wire [SIZE_WIDTH:0] output_byte_index = current_offset_ext + {1'b0, bytes_sent};
    wire current_config_valid = size_reg != 0 && current_size_ext <= BYTE_LANES_VALUE &&
                                current_read_end <= BYTE_LANES_VALUE;

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
            state           <= ST_IDLE;
            current_addr    <= 0;
            step_reg        <= 0;
            reads_remaining <= 0;
            size_reg        <= 0;
            data_reg        <= 0;
            bytes_sent      <= 0;
            error_reg       <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (read_start) begin
                        error_reg <= 1'b0;

                        if (read_count != 0) begin
                            current_addr    <= read_begin;
                            step_reg        <= read_step;
                            reads_remaining <= read_count;
                            size_reg        <= read_size;
                            bytes_sent      <= 0;
                            state           <= ST_AR;
                        end
                    end
                end

                ST_AR: begin
                    if (!current_config_valid) begin
                        error_reg <= 1'b1;
                        state     <= ST_IDLE;
                    end else if (m_axil_arready) begin
                        state <= ST_R;
                    end
                end

                ST_R: begin
                    if (m_axil_rvalid) begin
                        if (m_axil_rresp == RESP_OKAY) begin
                            data_reg   <= m_axil_rdata;
                            bytes_sent <= 0;
                            state      <= ST_STREAM;
                        end else begin
                            error_reg <= 1'b1;
                            state     <= ST_IDLE;
                        end
                    end
                end

                ST_STREAM: begin
                    if (m_axis_tready) begin
                        if (bytes_sent == size_reg - 1'b1) begin
                            if (reads_remaining == 1) begin
                                reads_remaining <= 0;
                                state           <= ST_IDLE;
                            end else begin
                                current_addr    <= current_addr + step_reg;
                                reads_remaining <= reads_remaining - 1'b1;
                                bytes_sent      <= 0;
                                state           <= ST_AR;
                            end
                        end else begin
                            bytes_sent <= bytes_sent + 1'b1;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    assign m_axil_araddr  = current_addr;
    assign m_axil_arprot  = 3'b000;
    assign m_axil_arvalid = state == ST_AR && current_config_valid;
    assign m_axil_rready  = state == ST_R;

    assign m_axis_tvalid = state == ST_STREAM;
    assign m_axis_tdata = data_reg[output_byte_index*8+:8];
    assign m_axis_tlast = state == ST_STREAM && reads_remaining == 1 &&
                          bytes_sent == size_reg - 1'b1;

    assign read_busy  = state != ST_IDLE;
    assign read_error = error_reg;

endmodule

`resetall
