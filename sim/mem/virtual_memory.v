`resetall
`timescale 1ns / 1ps
`default_nettype none

module virtual_memory #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32,
    parameter integer DEPTH      = 1024,
    parameter [ADDR_WIDTH-1:0] BASE_ADDR = 32'h8000_0000,
    parameter         INIT_FILE  = ""
) (
    input wire clock,
    input wire reset,

    input  wire                      s_valid,
    input  wire [    ADDR_WIDTH-1:0] s_addr,
    input  wire                      s_write,
    input  wire [    DATA_WIDTH-1:0] s_wdata,
    input  wire [(DATA_WIDTH/8)-1:0] s_wstrb,
    output wire                      s_ready,
    output wire [    DATA_WIDTH-1:0] s_rdata,
    output wire                      s_error
);

    localparam integer BYTE_LANES     = DATA_WIDTH / 8;
    localparam integer CAPACITY_BYTES = DEPTH * BYTE_LANES;

    reg [7:0] mem[0:CAPACITY_BYTES-1];
    reg [DATA_WIDTH-1:0] read_data;

    wire [ADDR_WIDTH-1:0] local_addr = s_addr - BASE_ADDR;
    wire [ADDR_WIDTH-1:0] word_index = local_addr / BYTE_LANES;
    wire [ADDR_WIDTH-1:0] byte_index = word_index * BYTE_LANES;
    wire address_valid = s_addr >= BASE_ADDR && word_index < DEPTH;

    integer init_file_handle;
    integer init_bytes_read;
    integer init_index;
    integer read_byte_index;
    integer write_byte_index;

    initial begin
        if (ADDR_WIDTH < 1) begin
            $error("Error: ADDR_WIDTH must be positive (instance %m)");
            $finish;
        end
        if (DATA_WIDTH < 8 || DATA_WIDTH % 8 != 0) begin
            $error("Error: DATA_WIDTH must be a positive multiple of 8 (instance %m)");
            $finish;
        end
        if ((BYTE_LANES & (BYTE_LANES - 1)) != 0) begin
            $error("Error: DATA_WIDTH/8 must be a power of two (instance %m)");
            $finish;
        end
        if (DEPTH < 1) begin
            $error("Error: DEPTH must be positive (instance %m)");
            $finish;
        end
        if (BASE_ADDR % BYTE_LANES != 0) begin
            $error("Error: BASE_ADDR must be aligned to DATA_WIDTH (instance %m)");
            $finish;
        end

        for (init_index = 0; init_index < CAPACITY_BYTES; init_index = init_index + 1) begin
            mem[init_index] = 8'h00;
        end
        if (INIT_FILE != "") begin
            init_file_handle = $fopen(INIT_FILE, "rb");
            if (init_file_handle == 0) begin
                $error("Error: failed to open INIT_FILE '%s' (instance %m)", INIT_FILE);
                $finish;
            end
            init_bytes_read = $fread(mem, init_file_handle);
            $fclose(init_file_handle);
            if (init_bytes_read == 0) begin
                $error("Error: INIT_FILE '%s' is empty (instance %m)", INIT_FILE);
                $finish;
            end
        end
    end

    // The simple bus completes one transaction per s_valid cycle without wait states.
    assign s_ready = 1'b1;
    assign s_rdata = read_data;
    assign s_error = s_valid && !address_valid;

    always @* begin
        read_data = {DATA_WIDTH{1'b0}};
        if (s_valid && !s_write && address_valid) begin
            for (read_byte_index = 0; read_byte_index < BYTE_LANES; read_byte_index = read_byte_index + 1) begin
                read_data[read_byte_index*8+:8] = mem[byte_index+read_byte_index];
            end
        end
    end

    always @(posedge clock) begin
        if (!reset && s_valid && s_write && address_valid) begin
            for (
                write_byte_index = 0;
                write_byte_index < BYTE_LANES;
                write_byte_index = write_byte_index + 1
            ) begin
                if (s_wstrb[write_byte_index]) begin
                    mem[byte_index+write_byte_index] <= s_wdata[write_byte_index*8+:8];
                end
            end
        end
    end

endmodule

`resetall
