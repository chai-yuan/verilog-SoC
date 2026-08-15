module uart_reg_top #(
    parameter ADDR_WIDTH       = 32,     // 总线地址位宽
    parameter DATA_WIDTH       = 32,     // 总线读写数据位宽
    parameter TX_FIFO_DEPTH    = 16,     // 发送 FIFO 深度
    parameter RX_FIFO_DEPTH    = 16,     // 接收 FIFO 深度
    parameter DEFAULT_PRESCALE = 16'd50  // 默认分频系数
) (
    input wire clock,
    input wire reset,

    output wire interrupt,

    input wire                      s_valid,
    input wire [    ADDR_WIDTH-1:0] s_addr,
    input wire                      s_write,
    input wire [    DATA_WIDTH-1:0] s_wdata,
    input wire [(DATA_WIDTH/8)-1:0] s_wstrb,

    output wire                  s_ready,
    output wire [DATA_WIDTH-1:0] s_rdata,
    output wire                  s_error,

    input  wire rx,
    output wire tx
);

    initial begin
        if (ADDR_WIDTH < 32) begin
            $error("Error: ADDR_WIDTH must be at least 32 (instance %m)");
            $finish;
        end
        if (DATA_WIDTH < 32 || DATA_WIDTH % 8 != 0) begin
            $error("Error: DATA_WIDTH must be at least 32 and a multiple of 8 (instance %m)");
            $finish;
        end
    end

    wire        sel_rx_fifo = (s_addr[7:0] == 8'h00);  // Read-only
    wire        sel_tx_fifo = (s_addr[7:0] == 8'h04);  // Write-only
    wire        sel_stat = (s_addr[7:0] == 8'h08);  // Read-only
    wire        sel_ctrl = (s_addr[7:0] == 8'h0C);  // Write-only

    reg  [15:0] prescale_reg;
    reg         intr_enable;

    wire        tx_fifo_rst_pulse;
    wire        rx_fifo_rst_pulse;
    wire        tx_fifo_reset;
    wire        rx_fifo_reset;

    wire        tx_fifo_full;
    wire        tx_fifo_empty;
    wire        rx_fifo_full;
    wire        rx_fifo_valid;

    wire        uart_rx_overrun;
    wire        uart_rx_frame;
    reg         err_overrun_reg;
    reg         err_frame_reg;

    // 0-wait state 响应 (只要有有效请求，立刻响应完成)
    assign s_ready = 1'b1;
    assign s_error = 1'b0;

    // 写操作逻辑 (Tx FIFO, CTRL_REG, PRESCALE)
    always @(posedge clock) begin
        if (reset) begin
            intr_enable  <= 1'b0;
            prescale_reg <= DEFAULT_PRESCALE;
        end else if (s_valid && s_write) begin
            // 写入 CTRL_REG ，高16位充当分频寄存器
            if (sel_ctrl) begin
                if (s_wstrb[0]) intr_enable <= s_wdata[4];
                if (s_wstrb[2]) prescale_reg[7:0] <= s_wdata[23:16];
                if (s_wstrb[3]) prescale_reg[15:8] <= s_wdata[31:24];
            end
        end
    end

    // FIFO 软件复位脉冲 (CTRL_REG Bit0 和 Bit1)
    assign tx_fifo_rst_pulse = (s_valid && s_write && sel_ctrl && s_wstrb[0] && s_wdata[0]);
    assign rx_fifo_rst_pulse = (s_valid && s_write && sel_ctrl && s_wstrb[0] && s_wdata[1]);

    assign tx_fifo_reset = reset | tx_fifo_rst_pulse;
    assign rx_fifo_reset = reset | rx_fifo_rst_pulse;


    // 手册规定：当读取状态寄存器时，这些错误标志被清除
    wire read_stat_reg_pulse = (s_valid && !s_write && sel_stat);

    always @(posedge clock) begin
        if (reset) begin
            err_overrun_reg <= 1'b0;
            err_frame_reg   <= 1'b0;
        end else begin
            if (read_stat_reg_pulse) begin
                err_overrun_reg <= 1'b0;
                err_frame_reg   <= 1'b0;
            end

            if (uart_rx_overrun) err_overrun_reg <= 1'b1;
            if (uart_rx_frame) err_frame_reg <= 1'b1;
        end
    end

    // 读操作逻辑 (Rx FIFO, STAT_REG, PRESCALE)
    wire [7:0] rx_fifo_rdata;

    wire [7:0] status_reg = {
                                1'b0,  // Bit 7: Parity Error (不支持，恒定为0)
                                err_frame_reg,  // Bit 6: Frame Error
                                err_overrun_reg,  // Bit 5: Overrun Error
                                intr_enable,  // Bit 4: Interrupt Enabled
                                tx_fifo_full,  // Bit 3: Tx FIFO Full
                                tx_fifo_empty,  // Bit 2: Tx FIFO Empty
                                rx_fifo_full,  // Bit 1: Rx FIFO Full
                                rx_fifo_valid  // Bit 0: Rx FIFO Valid Data
                            };

    assign s_rdata =    (sel_rx_fifo && !s_write) ? {{(DATA_WIDTH-8){1'b0}}, rx_fifo_rdata} :
                        (sel_stat    && !s_write) ? {{(DATA_WIDTH-8){1'b0}}, status_reg}    :
                                                    {DATA_WIDTH{1'b0}};

    // 中断输出
    assign interrupt = intr_enable & (rx_fifo_valid | tx_fifo_empty);

    // 发送路径
    wire       tx_fifo_s_valid = s_valid && s_write && sel_tx_fifo && s_wstrb[0];
    wire [7:0] tx_fifo_s_data = s_wdata[7:0];

    wire       tx_fifo_m_valid;
    wire       tx_fifo_m_ready;
    wire [7:0] tx_fifo_m_data;

    axis_fifo #(
        .DATA_WIDTH (8),
        .DEPTH      (TX_FIFO_DEPTH),
        .KEEP_ENABLE(0),
        .LAST_ENABLE(0),
        .ID_ENABLE  (0),
        .DEST_ENABLE(0),
        .USER_ENABLE(0)
    ) u_tx_fifo (
        .clock(clock),
        .reset(tx_fifo_reset),

        .s_axis_tvalid(tx_fifo_s_valid),
        .s_axis_tready(),  // 根据UARTLite行为，写满时自动丢弃，不反压总线
        .s_axis_tdata(tx_fifo_s_data),
        .s_axis_tkeep(1'b0),
        .s_axis_tlast(1'b0),
        .s_axis_tid(1'b0),
        .s_axis_tdest(1'b0),
        .s_axis_tuser(1'b0),

        .m_axis_tvalid(tx_fifo_m_valid),
        .m_axis_tready(tx_fifo_m_ready),
        .m_axis_tdata (tx_fifo_m_data),

        .status_full (tx_fifo_full),
        .status_empty(tx_fifo_empty)
    );

    uart_tx u_uart_tx (
        .clock        (clock),
        .reset        (reset),
        .prescale     (prescale_reg),
        .s_axis_tdata (tx_fifo_m_data),
        .s_axis_tvalid(tx_fifo_m_valid),
        .s_axis_tready(tx_fifo_m_ready),
        .tx           (tx)
    );

    // 接收路径
    wire       rx_fifo_s_valid;
    wire       rx_fifo_s_ready;
    wire [7:0] rx_fifo_s_data;
    wire       rx_fifo_m_valid;

    // 只有当对 0x00 进行读操作时，才向 FIFO 产生 read 信号(tready)
    wire       rx_fifo_m_ready = s_valid && !s_write && sel_rx_fifo;

    uart_rx u_uart_rx (
        .clock        (clock),
        .reset        (reset),
        .prescale     (prescale_reg),
        .m_axis_tdata (rx_fifo_s_data),
        .m_axis_tvalid(rx_fifo_s_valid),
        .m_axis_tready(rx_fifo_s_ready),
        .overrun_error(uart_rx_overrun),
        .frame_error  (uart_rx_frame),
        .rx           (rx)
    );

    axis_fifo #(
        .DATA_WIDTH (8),
        .DEPTH      (RX_FIFO_DEPTH),
        .KEEP_ENABLE(0),
        .LAST_ENABLE(0),
        .ID_ENABLE  (0),
        .DEST_ENABLE(0),
        .USER_ENABLE(0)
    ) u_rx_fifo (
        .clock(clock),
        .reset(rx_fifo_reset),

        .s_axis_tvalid(rx_fifo_s_valid),
        .s_axis_tready(rx_fifo_s_ready),
        .s_axis_tdata (rx_fifo_s_data),
        .s_axis_tkeep (1'b0),
        .s_axis_tlast (1'b0),
        .s_axis_tid   (1'b0),
        .s_axis_tdest (1'b0),
        .s_axis_tuser (1'b0),

        .m_axis_tvalid(rx_fifo_m_valid),
        .m_axis_tready(rx_fifo_m_ready),
        .m_axis_tdata (rx_fifo_rdata),

        .status_full (rx_fifo_full),
        .status_empty()
    );

    assign rx_fifo_valid = rx_fifo_m_valid;

endmodule
