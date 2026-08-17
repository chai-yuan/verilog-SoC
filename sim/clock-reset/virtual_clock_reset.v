`resetall
`timescale 1ns / 1ps
`default_nettype none

module virtual_clock_reset #(
) (
    input wire clock,
    input wire reset,

    output wire clock_out,
    output wire reset_out,
);

    assign clock_out = clock;
    assign reset_out = reset;

endmodule

`resetall