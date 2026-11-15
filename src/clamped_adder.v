/*
 * Copyright (c) 2025 Kosmas Wernhard
 * SPDX-License-Identifier: Apache-2.0
 *
 * Port of the master-thesis module clamped_adder.sv (TUM / Lund University).
 *
 * NOTE: kept bit-exact to the thesis RTL. Because raw_sum has the same width as
 * the operands, the clamp comparisons can never be true and the adder wraps
 * around (plain two's complement addition). Synthesis removes the dead logic.
 */

`default_nettype none

module clamped_adder #(
    parameter WIDTH = 4
) (
    input  wire signed [WIDTH-1:0] A,
    input  wire signed [WIDTH-1:0] B,
    output wire signed [WIDTH-1:0] Sum
);

  localparam signed MINvalue = -(2 ** (WIDTH - 1));
  localparam signed MAXvalue = (2 ** (WIDTH - 1)) - 1;

  wire signed [WIDTH-1:0] raw_sum;
  assign raw_sum = A + B;

  assign Sum = (raw_sum > MAXvalue) ? MAXvalue[WIDTH-1:0] :
               (raw_sum < MINvalue) ? MINvalue[WIDTH-1:0] : raw_sum;

endmodule
