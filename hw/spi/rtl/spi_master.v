`resetall
`timescale 1ns / 1ps
`default_nettype none

module spi_master #(
    parameter integer DATA_WIDTH = 32
) (
    input wire clock,
    input wire reset,

    input wire [7:0] prescale,
    input wire       cpol,
    input wire       cpha,

    input wire                  cmd_valid,
    output wire                 cmd_ready,
    input wire [DATA_WIDTH-1:0] cmd_data,
    input wire [$clog2(DATA_WIDTH+1)-1:0] cmd_bits,
    input wire                  cmd_cs_autofree,

    output wire                 rsp_valid,
    input wire                  rsp_ready,
    output wire [DATA_WIDTH-1:0] rsp_data,

    output wire SCK,
    output wire SS,
    output wire MOSI,
    input wire  MISO
);

    localparam integer LENGTH_WIDTH = (DATA_WIDTH < 2) ? 1 : $clog2(DATA_WIDTH + 1);
    localparam integer EDGE_COUNT_WIDTH = (DATA_WIDTH < 2) ? 1 : $clog2(2 * DATA_WIDTH);
    localparam [LENGTH_WIDTH-1:0] DATA_WIDTH_VALUE = LENGTH_WIDTH'(DATA_WIDTH);

    reg busy;
    reg sck_reg;
    reg ss_reg;
    reg mosi_reg;
    reg cpol_reg;
    reg cpha_reg;
    reg cs_autofree_reg;
    reg [DATA_WIDTH-1:0] tx_shift_reg;
    reg [DATA_WIDTH-1:0] rx_shift_reg;
    reg [LENGTH_WIDTH-1:0] active_len_reg;
    reg [7:0] prescale_reg;
    reg [7:0] prescale_count;
    reg [EDGE_COUNT_WIDTH-1:0] edge_count;
    reg [DATA_WIDTH-1:0] rsp_data_reg;
    reg rsp_valid_reg;

    wire rsp_output_ready = !rsp_valid_reg || rsp_ready;
    wire cmd_fire = cmd_valid && cmd_ready;
    wire [31:0] cmd_bits_value = {{(32-LENGTH_WIDTH){1'b0}}, cmd_bits};
    wire cmd_bits_full = (cmd_bits == 0) || (cmd_bits_value > DATA_WIDTH);
    wire [DATA_WIDTH-1:0] start_tx_shifted = cmd_bits_full ?
                                               cmd_data :
                                               (cmd_data << (DATA_WIDTH - cmd_bits_value));
    wire [DATA_WIDTH-1:0] tx_shift_next = tx_shift_reg << 1;
    wire [DATA_WIDTH-1:0] miso_value = {{(DATA_WIDTH-1){1'b0}}, MISO};
    wire [EDGE_COUNT_WIDTH-1:0] final_edge_count = 2 * active_len_reg - 1;

    assign cmd_ready = !busy && rsp_output_ready;
    assign rsp_valid = rsp_valid_reg;
    assign rsp_data  = rsp_data_reg;

    assign SCK  = sck_reg;
    assign SS   = ss_reg;
    assign MOSI = mosi_reg;

    initial begin
        if (DATA_WIDTH < 1) begin
            $error("Error: DATA_WIDTH must be at least 1 (instance %m)");
            $finish;
        end
        if (DATA_WIDTH > 255) begin
            $error("Error: DATA_WIDTH must be at most 255 (instance %m)");
            $finish;
        end
    end

    always @(posedge clock) begin
        if (reset) begin
            busy           <= 1'b0;
            sck_reg        <= cpol;
            ss_reg         <= 1'b1;
            mosi_reg       <= 1'b0;
            cpol_reg       <= cpol;
            cpha_reg       <= cpha;
            cs_autofree_reg<= 1'b1;
            tx_shift_reg   <= {DATA_WIDTH{1'b0}};
            rx_shift_reg   <= {DATA_WIDTH{1'b0}};
            active_len_reg <= DATA_WIDTH_VALUE;
            prescale_reg   <= 8'd0;
            prescale_count <= 8'd0;
            edge_count     <= {EDGE_COUNT_WIDTH{1'b0}};
            rsp_data_reg   <= {DATA_WIDTH{1'b0}};
            rsp_valid_reg  <= 1'b0;
        end else begin
            if (rsp_valid_reg && rsp_ready) begin
                rsp_valid_reg <= 1'b0;
            end

            if (!busy) begin
                // 命令间保持自动片选状态，并将 SCK 保持在当前配置的空闲电平。
                sck_reg <= ss_reg ? cpol : cpol_reg;

                if (cmd_fire) begin
                    busy            <= 1'b1;
                    ss_reg          <= 1'b0;
                    cs_autofree_reg <= cmd_cs_autofree;
                    cpol_reg        <= cpol;
                    cpha_reg        <= cpha;
                    active_len_reg  <= cmd_bits_full ? DATA_WIDTH_VALUE : cmd_bits;
                    tx_shift_reg    <= start_tx_shifted;
                    rx_shift_reg    <= {DATA_WIDTH{1'b0}};
                    edge_count      <= {EDGE_COUNT_WIDTH{1'b0}};
                    prescale_reg    <= (prescale == 0) ? 8'd0 : prescale - 1'b1;
                    prescale_count  <= (prescale == 0) ? 8'd0 : prescale - 1'b1;

                    sck_reg  <= cpol;
                    mosi_reg <= cpha ? 1'b0 : start_tx_shifted[DATA_WIDTH-1];
                end
            end else if (prescale_count != 0) begin
                prescale_count <= prescale_count - 1'b1;
            end else begin
                prescale_count <= prescale_reg;
                sck_reg        <= ~sck_reg;

                if (sck_reg == cpol_reg) begin
                    // Leading edge.
                    if (cpha_reg) begin
                        mosi_reg     <= tx_shift_reg[DATA_WIDTH-1];
                        tx_shift_reg <= tx_shift_reg << 1;
                    end else begin
                        rx_shift_reg <= (rx_shift_reg << 1) | miso_value;
                    end
                end else begin
                    // Trailing edge.
                    if (cpha_reg) begin
                        rx_shift_reg <= (rx_shift_reg << 1) | miso_value;
                    end else if (edge_count != final_edge_count) begin
                        mosi_reg     <= tx_shift_next[DATA_WIDTH-1];
                        tx_shift_reg <= tx_shift_next;
                    end
                end

                if (edge_count == final_edge_count) begin
                    busy         <= 1'b0;
                    sck_reg      <= cpol_reg;
                    rsp_data_reg <= cpha_reg ? ((rx_shift_reg << 1) | miso_value) : rx_shift_reg;
                    rsp_valid_reg<= 1'b1;

                    if (cs_autofree_reg) begin
                        ss_reg <= 1'b1;
                    end
                end else begin
                    edge_count <= edge_count + 1'b1;
                end
            end
        end
    end

endmodule

`resetall
