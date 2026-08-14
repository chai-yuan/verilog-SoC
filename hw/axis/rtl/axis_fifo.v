`resetall
`timescale 1ns / 1ps
`default_nettype none

module axis_fifo #(
    parameter DATA_WIDTH  = 32,  // AXI-Stream 数据位宽
    parameter DEPTH       = 16,  // FIFO 深度 (BRAM深度)
    parameter KEEP_ENABLE = 1,   // 字节使能（TKEEP）使能开关
    parameter LAST_ENABLE = 1,   // 尾帧标志（TLAST）使能开关
    parameter ID_ENABLE   = 0,   // AXI-Stream TID 使能开关
    parameter ID_WIDTH    = 1,   // AXI-Stream TID 位宽
    parameter DEST_ENABLE = 0,   // AXI-Stream TDEST 使能开关
    parameter DEST_WIDTH  = 1,   // AXI-Stream TDEST 位宽
    parameter USER_ENABLE = 0,   // AXI-Stream TUSER 使能开关
    parameter USER_WIDTH  = 1    // AXI-Stream TUSER 位宽
) (
    input wire clock,
    input wire reset,

    input  wire                      s_axis_tvalid,
    output wire                      s_axis_tready,
    input  wire [    DATA_WIDTH-1:0] s_axis_tdata,
    input  wire [(DATA_WIDTH/8)-1:0] s_axis_tkeep,
    input  wire                      s_axis_tlast,
    input  wire [      ID_WIDTH-1:0] s_axis_tid,
    input  wire [    DEST_WIDTH-1:0] s_axis_tdest,
    input  wire [    USER_WIDTH-1:0] s_axis_tuser,

    output wire                      m_axis_tvalid,
    input  wire                      m_axis_tready,
    output wire [    DATA_WIDTH-1:0] m_axis_tdata,
    output wire [(DATA_WIDTH/8)-1:0] m_axis_tkeep,
    output wire                      m_axis_tlast,
    output wire [      ID_WIDTH-1:0] m_axis_tid,
    output wire [    DEST_WIDTH-1:0] m_axis_tdest,
    output wire [    USER_WIDTH-1:0] m_axis_tuser,

    output wire status_full,
    output wire status_empty
);

    // 位宽与偏移量计算
    localparam KEEP_WIDTH = DATA_WIDTH / 8;
    localparam ADDR_WIDTH = $clog2(DEPTH);

    localparam KEEP_OFFSET = DATA_WIDTH;
    localparam LAST_OFFSET = KEEP_OFFSET + (KEEP_ENABLE ? KEEP_WIDTH : 0);
    localparam ID_OFFSET = LAST_OFFSET + (LAST_ENABLE ? 1 : 0);
    localparam DEST_OFFSET = ID_OFFSET + (ID_ENABLE ? ID_WIDTH : 0);
    localparam USER_OFFSET = DEST_OFFSET + (DEST_ENABLE ? DEST_WIDTH : 0);

    localparam WIDTH = USER_OFFSET + (USER_ENABLE ? USER_WIDTH : 0);

    // 参数校验
    initial begin
        if (DATA_WIDTH % 8 != 0) begin
            $error("Error: DATA_WIDTH must be a multiple of 8 (instance %m)");
            $finish;
        end
        if (DATA_WIDTH < 8) begin
            $error("Error: DATA_WIDTH must be at least 8 (instance %m)");
            $finish;
        end
        if (DEPTH < 2) begin
            $error("Error: DEPTH must be at least 2 (instance %m)");
            $finish;
        end
        if (ID_ENABLE && !ID_WIDTH) begin
            $error("Error: ID_ENABLE set requires ID_WIDTH >= 1 (instance %m)");
            $finish;
        end
        if (DEST_ENABLE && !DEST_WIDTH) begin
            $error("Error: DEST_ENABLE set requires DEST_WIDTH >= 1 (instance %m)");
            $finish;
        end
        if (USER_ENABLE && !USER_WIDTH) begin
            $error("Error: USER_ENABLE set requires USER_WIDTH >= 1 (instance %m)");
            $finish;
        end
    end

    // 信号声明
    reg [ADDR_WIDTH:0] wr_ptr;
    reg [ADDR_WIDTH:0] rd_ptr;

    // FIFO BRAM 存储器
    reg [WIDTH-1:0] mem[0:(1<<ADDR_WIDTH)-1];
    reg [WIDTH-1:0] s_axis_packed;

    // FIFO 状态指示与写侧逻辑
    assign status_full   = (wr_ptr == (rd_ptr ^ {1'b1, {ADDR_WIDTH{1'b0}}}));
    assign status_empty  = (wr_ptr == rd_ptr);
    assign s_axis_tready = !status_full;

    // 打包输入数据组合逻辑
    always @* begin
        s_axis_packed = {WIDTH{1'b0}};
        s_axis_packed[DATA_WIDTH-1:0] = s_axis_tdata;
        if (KEEP_ENABLE) s_axis_packed[KEEP_OFFSET+:KEEP_WIDTH] = s_axis_tkeep;
        if (LAST_ENABLE) s_axis_packed[LAST_OFFSET] = s_axis_tlast;
        if (ID_ENABLE) s_axis_packed[ID_OFFSET+:ID_WIDTH] = s_axis_tid;
        if (DEST_ENABLE) s_axis_packed[DEST_OFFSET+:DEST_WIDTH] = s_axis_tdest;
        if (USER_ENABLE) s_axis_packed[USER_OFFSET+:USER_WIDTH] = s_axis_tuser;
    end

    // 写侧时序逻辑
    always @(posedge clock) begin
        if (reset) begin
            wr_ptr <= 0;
        end else begin
            if (s_axis_tready && s_axis_tvalid) begin
                mem[wr_ptr[ADDR_WIDTH-1:0]] <= s_axis_packed;
                wr_ptr <= wr_ptr + 1;
            end
        end
    end

    // 读取侧逻辑
    // RAM 输出寄存器
    reg  [WIDTH-1:0] stage1_data;
    reg              stage1_valid;
    // 输出管脚寄存器
    reg  [WIDTH-1:0] stage2_data;
    reg              stage2_valid;

    wire             stage1_ready = !stage2_valid || m_axis_tready;
    wire             ram_read_en = !status_empty && (!stage1_valid || stage1_ready);

    always @(posedge clock) begin
        if (reset) begin
            rd_ptr       <= 0;
            stage1_valid <= 1'b0;
            stage2_valid <= 1'b0;
        end else begin
            if (ram_read_en) begin
                stage1_data  <= mem[rd_ptr[ADDR_WIDTH-1:0]];
                stage1_valid <= 1'b1;
                rd_ptr       <= rd_ptr + 1;
            end else if (stage1_ready) begin
                stage1_valid <= 1'b0;
            end

            if (stage1_ready) begin
                stage2_data  <= stage1_data;
                stage2_valid <= stage1_valid;
            end
        end
    end

    // 解包 Stage 2 数据到输出总线
    assign m_axis_tvalid = stage2_valid;
    assign m_axis_tdata  = stage2_data[DATA_WIDTH-1:0];
    assign m_axis_tkeep  = KEEP_ENABLE ? stage2_data[KEEP_OFFSET+:KEEP_WIDTH] : {KEEP_WIDTH{1'b1}};
    assign m_axis_tlast  = LAST_ENABLE ? stage2_data[LAST_OFFSET] : 1'b1;
    assign m_axis_tid    = ID_ENABLE ? stage2_data[ID_OFFSET+:ID_WIDTH] : {ID_WIDTH{1'b0}};
    assign m_axis_tdest  = DEST_ENABLE ? stage2_data[DEST_OFFSET+:DEST_WIDTH] : {DEST_WIDTH{1'b0}};
    assign m_axis_tuser  = USER_ENABLE ? stage2_data[USER_OFFSET+:USER_WIDTH] : {USER_WIDTH{1'b0}};

endmodule

`resetall
