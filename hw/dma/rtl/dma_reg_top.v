`resetall
`timescale 1ns / 1ps
`default_nettype none

module dma_reg_top #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter FIFO_DEPTH = 16
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

    localparam BYTE_LANES = DATA_WIDTH / 8;
    localparam SIZE_WIDTH = $clog2(BYTE_LANES + 1);
    localparam BYTE_OFFSET_WIDTH = BYTE_LANES > 1 ? $clog2(BYTE_LANES) : 1;
    localparam TOTAL_WIDTH = ADDR_WIDTH + SIZE_WIDTH;
    localparam [SIZE_WIDTH:0] BYTE_LANES_VALUE =
        {{SIZE_WIDTH{1'b0}}, 1'b1} << (SIZE_WIDTH - 1);

    localparam [7:0] ADDR_READ_BEGIN  = 8'h00;
    localparam [7:0] ADDR_READ_STEP   = 8'h04;
    localparam [7:0] ADDR_READ_COUNT  = 8'h08;
    localparam [7:0] ADDR_READ_SIZE   = 8'h0C;
    localparam [7:0] ADDR_WRITE_BEGIN = 8'h10;
    localparam [7:0] ADDR_WRITE_STEP  = 8'h14;
    localparam [7:0] ADDR_WRITE_COUNT = 8'h18;
    localparam [7:0] ADDR_WRITE_SIZE  = 8'h1C;
    localparam [7:0] ADDR_CONTROL     = 8'h20;
    localparam [7:0] ADDR_STATUS      = 8'h24;

    localparam [31:0] CONTROL_START         = 32'h0000_0001;
    localparam [31:0] CONTROL_ABORT         = 32'h0000_0002;
    localparam [31:0] CONTROL_CLEAR_STATUS  = 32'h0000_0004;
    localparam [31:0] CONTROL_INTR_ENABLE   = 32'h0000_0100;

    reg [ADDR_WIDTH-1:0] read_begin_reg;
    reg [ADDR_WIDTH-1:0] read_step_reg;
    reg [ADDR_WIDTH-1:0] read_count_reg;
    reg [SIZE_WIDTH-1:0] read_size_reg;
    reg [ADDR_WIDTH-1:0] write_begin_reg;
    reg [ADDR_WIDTH-1:0] write_step_reg;
    reg [ADDR_WIDTH-1:0] write_count_reg;
    reg [SIZE_WIDTH-1:0] write_size_reg;

    reg interrupt_enable_reg;
    reg active_reg;
    reg aborting_reg;
    reg done_reg;
    reg read_error_reg;
    reg write_error_reg;
    reg config_error_reg;

    wire [7:0] register_addr = s_addr[7:0] - {{6{1'b0}}, s_addr[1:0]};
    wire addr_in_range;
    generate
        if (ADDR_WIDTH > 8) begin : g_addr_range_check
            assign addr_in_range = s_addr[ADDR_WIDTH-1:8] == {(ADDR_WIDTH-8){1'b0}};
        end else begin : g_addr_range_always_ok
            assign addr_in_range = 1'b1;
        end
    endgenerate

    wire addr_mapped = register_addr == ADDR_READ_BEGIN  ||
                       register_addr == ADDR_READ_STEP   ||
                       register_addr == ADDR_READ_COUNT  ||
                       register_addr == ADDR_READ_SIZE   ||
                       register_addr == ADDR_WRITE_BEGIN ||
                       register_addr == ADDR_WRITE_STEP  ||
                       register_addr == ADDR_WRITE_COUNT ||
                       register_addr == ADDR_WRITE_SIZE  ||
                       register_addr == ADDR_CONTROL     ||
                       register_addr == ADDR_STATUS;
    wire addr_valid = addr_in_range && addr_mapped;
    wire write_fire = s_valid && s_ready && s_write && addr_valid;

    assign s_ready = 1'b1;
    assign s_error = s_valid && !addr_valid;

    function [31:0] write_bytes;
        input [31:0] current_value;
        input [31:0] write_data;
        input [ 3:0] write_strobe;
        begin
            write_bytes =
                (current_value & ~{
                    {8{write_strobe[3]}}, {8{write_strobe[2]}},
                    {8{write_strobe[1]}}, {8{write_strobe[0]}}
                }) |
                (write_data & {
                    {8{write_strobe[3]}}, {8{write_strobe[2]}},
                    {8{write_strobe[1]}}, {8{write_strobe[0]}}
                });
        end
    endfunction

    wire start_request = write_fire && register_addr == ADDR_CONTROL &&
                         s_wstrb[0] && (s_wdata[31:0] & CONTROL_START) != 0;
    wire abort_request = write_fire && register_addr == ADDR_CONTROL &&
                         s_wstrb[0] && (s_wdata[31:0] & CONTROL_ABORT) != 0;
    wire clear_status_request = write_fire && register_addr == ADDR_CONTROL &&
                                s_wstrb[0] &&
                                (s_wdata[31:0] & CONTROL_CLEAR_STATUS) != 0;

    wire [SIZE_WIDTH:0] read_offset_ext =
        {{(SIZE_WIDTH+1-BYTE_OFFSET_WIDTH){1'b0}},
         read_begin_reg[BYTE_OFFSET_WIDTH-1:0]};
    wire [SIZE_WIDTH:0] write_offset_ext =
        {{(SIZE_WIDTH+1-BYTE_OFFSET_WIDTH){1'b0}},
         write_begin_reg[BYTE_OFFSET_WIDTH-1:0]};
    wire [SIZE_WIDTH:0] read_size_ext = {1'b0, read_size_reg};
    wire [SIZE_WIDTH:0] write_size_ext = {1'b0, write_size_reg};
    wire [TOTAL_WIDTH-1:0] read_total_bytes = read_count_reg * read_size_reg;
    wire [TOTAL_WIDTH-1:0] write_total_bytes = write_count_reg * write_size_reg;

    wire transfer_config_valid = read_count_reg != 0 && write_count_reg != 0 &&
                                 read_size_reg != 0 && write_size_reg != 0 &&
                                 read_size_ext <= BYTE_LANES_VALUE &&
                                 write_size_ext <= BYTE_LANES_VALUE &&
                                 read_offset_ext + read_size_ext <= BYTE_LANES_VALUE &&
                                 write_offset_ext + write_size_ext <= BYTE_LANES_VALUE &&
                                 read_total_bytes == write_total_bytes;
    wire dma_start_pulse = start_request && !active_reg && !aborting_reg &&
                           !abort_request && transfer_config_valid;

    wire read_busy;
    wire write_busy;
    wire read_error;
    wire write_error;

    // 中止时先停止流接口，再让已经发出的 AXI-Lite 请求完成；总线静默后才复位引擎。
    wire dma_error_event = active_reg && (read_error || write_error);
    wire stop_stream = aborting_reg || abort_request || dma_error_event;
    wire read_bus_idle = !m_axil_arvalid && !m_axil_rready;
    wire write_bus_idle = !m_axil_awvalid && !m_axil_wvalid && !m_axil_bready;
    wire cleanup_reset = aborting_reg && read_bus_idle && write_bus_idle;
    wire engine_reset = reset || cleanup_reset;
    wire fifo_reset = reset || dma_start_pulse || cleanup_reset;

    wire read_stream_valid;
    wire read_stream_ready;
    wire [7:0] read_stream_data;
    wire read_stream_last;
    wire fifo_input_ready;

    wire fifo_output_valid;
    wire fifo_output_ready;
    wire [7:0] fifo_output_data;
    wire fifo_output_last;
    wire write_stream_ready;

    wire fifo_full;
    wire fifo_ram_empty;

    assign read_stream_ready = fifo_input_ready && !stop_stream;
    assign fifo_output_ready = write_stream_ready && !stop_stream;

    wire error_status = read_error_reg || write_error_reg || config_error_reg;
    wire [31:0] control_value = interrupt_enable_reg ? CONTROL_INTR_ENABLE : 32'b0;
    wire [31:0] status_value = {
        20'b0,
        aborting_reg,         // Bit 11
        interrupt_enable_reg, // Bit 10
        fifo_ram_empty,       // Bit 9: FIFO RAM empty; output pipeline may still contain data
        fifo_full,            // Bit 8
        config_error_reg,     // Bit 7
        write_error_reg,      // Bit 6
        read_error_reg,       // Bit 5
        write_busy,           // Bit 4
        read_busy,            // Bit 3
        error_status,         // Bit 2
        done_reg,             // Bit 1
        active_reg            // Bit 0
    };

    reg [31:0] read_data;
    always @* begin
        read_data = 32'b0;

        if (!s_write && addr_valid) begin
            case (register_addr)
                ADDR_READ_BEGIN:  read_data = read_begin_reg;
                ADDR_READ_STEP:   read_data = read_step_reg;
                ADDR_READ_COUNT:  read_data = read_count_reg;
                ADDR_READ_SIZE:   read_data = {{(32-SIZE_WIDTH){1'b0}}, read_size_reg};
                ADDR_WRITE_BEGIN: read_data = write_begin_reg;
                ADDR_WRITE_STEP:  read_data = write_step_reg;
                ADDR_WRITE_COUNT: read_data = write_count_reg;
                ADDR_WRITE_SIZE:  read_data = {{(32-SIZE_WIDTH){1'b0}}, write_size_reg};
                ADDR_CONTROL:     read_data = control_value;
                ADDR_STATUS:      read_data = status_value;
                default:          read_data = 32'b0;
            endcase
        end
    end

    assign s_rdata = {{(DATA_WIDTH-32){1'b0}}, read_data};
    assign interrupt = interrupt_enable_reg && (done_reg || error_status);

    always @(posedge clock) begin
        if (reset) begin
            read_begin_reg      <= 0;
            read_step_reg       <= 0;
            read_count_reg      <= 0;
            read_size_reg       <= 0;
            write_begin_reg     <= 0;
            write_step_reg      <= 0;
            write_count_reg     <= 0;
            write_size_reg      <= 0;
            interrupt_enable_reg<= 1'b0;
            active_reg          <= 1'b0;
            aborting_reg        <= 1'b0;
            done_reg            <= 1'b0;
            read_error_reg      <= 1'b0;
            write_error_reg     <= 1'b0;
            config_error_reg    <= 1'b0;
        end else begin
            if (write_fire) begin
                case (register_addr)
                    ADDR_READ_BEGIN:
                        read_begin_reg <= write_bytes(read_begin_reg, s_wdata[31:0], s_wstrb[3:0]);
                    ADDR_READ_STEP:
                        read_step_reg <= write_bytes(read_step_reg, s_wdata[31:0], s_wstrb[3:0]);
                    ADDR_READ_COUNT:
                        read_count_reg <= write_bytes(read_count_reg, s_wdata[31:0], s_wstrb[3:0]);
                    ADDR_READ_SIZE:
                        read_size_reg <= write_bytes(
                            {{(32-SIZE_WIDTH){1'b0}}, read_size_reg},
                            s_wdata[31:0], s_wstrb[3:0]
                        )[SIZE_WIDTH-1:0];
                    ADDR_WRITE_BEGIN:
                        write_begin_reg <= write_bytes(write_begin_reg, s_wdata[31:0], s_wstrb[3:0]);
                    ADDR_WRITE_STEP:
                        write_step_reg <= write_bytes(write_step_reg, s_wdata[31:0], s_wstrb[3:0]);
                    ADDR_WRITE_COUNT:
                        write_count_reg <= write_bytes(write_count_reg, s_wdata[31:0], s_wstrb[3:0]);
                    ADDR_WRITE_SIZE:
                        write_size_reg <= write_bytes(
                            {{(32-SIZE_WIDTH){1'b0}}, write_size_reg},
                            s_wdata[31:0], s_wstrb[3:0]
                        )[SIZE_WIDTH-1:0];
                    ADDR_CONTROL:
                        if (s_wstrb[1]) interrupt_enable_reg <= s_wdata[8];
                    default: begin
                    end
                endcase
            end

            if (clear_status_request) begin
                done_reg         <= 1'b0;
                read_error_reg   <= 1'b0;
                write_error_reg  <= 1'b0;
                config_error_reg <= 1'b0;
            end

            // 错误锁存独立于 abort 优先级，保证同周期软件中止不会吞掉总线错误。
            if (dma_error_event) begin
                read_error_reg  <= read_error_reg || read_error;
                write_error_reg <= write_error_reg || write_error;
            end

            if (cleanup_reset) begin
                active_reg   <= 1'b0;
                aborting_reg <= 1'b0;
                done_reg     <= 1'b0;
            end else if (abort_request && active_reg) begin
                aborting_reg <= 1'b1;
                done_reg     <= 1'b0;
            end else if (start_request && !abort_request && !active_reg && !aborting_reg) begin
                done_reg         <= 1'b0;
                read_error_reg   <= 1'b0;
                write_error_reg  <= 1'b0;
                config_error_reg <= !transfer_config_valid;
                active_reg       <= transfer_config_valid;
            end else if (active_reg && !aborting_reg) begin
                if (read_error || write_error) begin
                    aborting_reg <= 1'b1;
                    done_reg     <= 1'b0;
                end else if (!read_busy && !write_busy) begin
                    active_reg <= 1'b0;
                    done_reg   <= 1'b1;
                end
            end
        end
    end

    axil_dma_rd #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_dma_rd (
        .clock(clock),
        .reset(engine_reset),

        .m_axil_araddr (m_axil_araddr),
        .m_axil_arprot (m_axil_arprot),
        .m_axil_arvalid(m_axil_arvalid),
        .m_axil_arready(m_axil_arready),
        .m_axil_rdata  (m_axil_rdata),
        .m_axil_rresp  (m_axil_rresp),
        .m_axil_rvalid (m_axil_rvalid),
        .m_axil_rready (m_axil_rready),

        .m_axis_tvalid(read_stream_valid),
        .m_axis_tready(read_stream_ready),
        .m_axis_tdata (read_stream_data),
        .m_axis_tlast (read_stream_last),

        .read_begin(read_begin_reg),
        .read_step (read_step_reg),
        .read_count(read_count_reg),
        .read_size (read_size_reg),
        .read_start(dma_start_pulse),
        .read_busy (read_busy),
        .read_error(read_error)
    );

    axis_fifo #(
        .DATA_WIDTH (8),
        .DEPTH      (FIFO_DEPTH),
        .KEEP_ENABLE(0),
        .LAST_ENABLE(1),
        .ID_ENABLE  (0),
        .DEST_ENABLE(0),
        .USER_ENABLE(0)
    ) u_data_fifo (
        .clock(clock),
        .reset(fifo_reset),

        .s_axis_tvalid(read_stream_valid && !stop_stream),
        .s_axis_tready(fifo_input_ready),
        .s_axis_tdata (read_stream_data),
        .s_axis_tkeep (1'b1),
        .s_axis_tlast (read_stream_last),
        .s_axis_tid   (1'b0),
        .s_axis_tdest (1'b0),
        .s_axis_tuser (1'b0),

        .m_axis_tvalid(fifo_output_valid),
        .m_axis_tready(fifo_output_ready),
        .m_axis_tdata (fifo_output_data),
        .m_axis_tkeep (),
        .m_axis_tlast (fifo_output_last),
        .m_axis_tid   (),
        .m_axis_tdest (),
        .m_axis_tuser (),

        .status_full (fifo_full),
        .status_empty(fifo_ram_empty)
    );

    axil_dma_wr #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_dma_wr (
        .clock(clock),
        .reset(engine_reset),

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

        .s_axis_tvalid(fifo_output_valid && !stop_stream),
        .s_axis_tready(write_stream_ready),
        .s_axis_tdata (fifo_output_data),
        .s_axis_tlast (fifo_output_last),

        .write_begin(write_begin_reg),
        .write_step (write_step_reg),
        .write_count(write_count_reg),
        .write_size (write_size_reg),
        .write_start(dma_start_pulse),
        .write_busy (write_busy),
        .write_error(write_error)
    );

    initial begin
        if (ADDR_WIDTH != 32) begin
            $error("Error: ADDR_WIDTH must be 32 (instance %m)");
            $finish;
        end
        if (DATA_WIDTH != 32) begin
            $error("Error: DATA_WIDTH must be 32 (instance %m)");
            $finish;
        end
        if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin
            $error("Error: FIFO_DEPTH must be a power of two and at least 2 (instance %m)");
            $finish;
        end
    end

endmodule

`resetall
