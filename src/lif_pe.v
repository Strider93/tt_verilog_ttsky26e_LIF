/*
 * Copyright (c) 2025 Kosmas Wernhard
 * SPDX-License-Identifier: Apache-2.0
 *
 * LIF processing element, ported from the master-thesis module PE.sv
 * (convolutional SNN accelerator, TUM / Lund University).
 *
 * The arithmetic is bit-exact to the thesis RTL. Changes are only those needed
 * for the Tiny Tapeout (Yosys / OpenLane) flow:
 *   - mem_out_counter / counter_deactivated were driven from two always blocks;
 *     both blocks are merged into one (accumulate clears, updateLIF sets).
 *   - counter_deactivated now has a reset value (was X after reset).
 *   - implicit net "spikle_out" declared, "input reg" -> "input wire".
 *   - extra debug outputs (accumulator, counter, spike) for chip readout.
 *
 * Convention (as in the thesis): leakage_reg and threshold_reg are only ever
 * ADDED, so they must be supplied negated (-leak, -Vth).
 *   sum        = acc + leak + Vmem_in
 *   sub_th_sum = sum + thr
 *   spike      = (sub_th_sum >= 0)
 *   Vmem_out   = spike ? sub_th_sum : sum
 */

`default_nettype none

module lif_pe #(
    parameter WIDTH = 4
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     accumulate,
    input  wire                     updateLIF,
    input  wire                     membrane_out_lower_bity_n,  // 0: update [15:0], 1: update [31:16]
    input  wire                     spike,                      // input spike
    input  wire                     zero_spike_vector,
    input  wire signed [WIDTH-1:0]  weight,
    input  wire signed [4*WIDTH-1:0] leakage_reg,
    input  wire signed [4*WIDTH-1:0] threshold_reg,
    input  wire signed [4*WIDTH-1:0] membrane_in_reg,
    input  wire                     hx_active,
    input  wire                     k_active,
    output wire signed [31:0]       membrane_out_reg,
    output reg  [31:0]              spike_vector_reg,
    output reg                      spike_vector_full,
    // debug / readout
    output wire signed [2*WIDTH-1:0] acc_out,
    output wire [4:0]               counter_out,
    output wire                     spike_out
);

  // Signals
  wire signed [2*WIDTH-1:0] sum_adder_weight_accumulate_reg;
  wire signed [4*WIDTH-1:0] sum_adder_weight_accumulate_leakage;
  wire signed [4*WIDTH-1:0] sub_th_sum, sum;
  wire signed [4*WIDTH-1:0] membrane_out;
  wire MSB_sub_th_sum, spikle_out, spike_reg;

  // Registers
  reg signed [2*WIDTH-1:0] weight_accumulate_reg;
  reg [4:0] counter;
  reg signed [4*WIDTH-1:0] membrane_out_lower, membrane_out_upper;
  reg mem_out_counter;
  reg counter_deactivated;

  wire acc_en = accumulate & hx_active & k_active;
  wire upd_en = updateLIF & hx_active & k_active;

  clamped_adder #(2 * WIDTH) adder_weight_accumulate (
      .A  (weight_accumulate_reg),
      .B  ({{WIDTH{weight[WIDTH-1]}}, weight}),
      .Sum(sum_adder_weight_accumulate_reg)
  );

  clamped_adder #(4 * WIDTH) adder_weight_accumulate_leakage (
      .A  ({{(2 * WIDTH) {weight_accumulate_reg[(2*WIDTH)-1]}}, weight_accumulate_reg}),
      .B  (leakage_reg),
      .Sum(sum_adder_weight_accumulate_leakage)
  );

  clamped_adder #(4 * WIDTH) adder_weight_accumulate_leakage_membrane (
      .A  (sum_adder_weight_accumulate_leakage),
      .B  (membrane_in_reg),
      .Sum(sum)
  );

  clamped_adder #(4 * WIDTH) adder_weight_accumulate_leakage_membrane_threshold (
      .A  (sum),
      .B  (threshold_reg),
      .Sum(sub_th_sum)
  );

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      weight_accumulate_reg <= 0;
      membrane_out_upper    <= 0;
      membrane_out_lower    <= 0;
      spike_vector_reg      <= 0;
      counter               <= 0;
      spike_vector_full     <= 0;
      mem_out_counter       <= 0;
      counter_deactivated   <= 0;
    end else begin
      // ---- former block 1: weight accumulation ----
      if (acc_en) begin
        if (spike) weight_accumulate_reg <= sum_adder_weight_accumulate_reg;
        mem_out_counter     <= 1'b0;
        counter_deactivated <= 1'b0;
      end else if (upd_en) begin
        weight_accumulate_reg <= 0;
      end

      // ---- former block 2: LIF update / spike vector ----
      if (upd_en) begin
        if (membrane_out_lower_bity_n & !mem_out_counter) begin
          membrane_out_upper <= membrane_out;
          mem_out_counter    <= 1'b1;
        end else if (!membrane_out_lower_bity_n) begin
          membrane_out_lower <= membrane_out;
        end
        if (!counter_deactivated) begin
          spike_vector_reg[counter] <= spike_reg;
          counter                   <= counter + 1'd1;
          counter_deactivated       <= 1'b1;
        end
        spike_vector_full <= (counter >= 31);
        if (zero_spike_vector) begin
          spike_vector_reg <= 0;
          counter          <= 0;
        end
      end else if (zero_spike_vector) begin
        spike_vector_reg <= 0;
        counter          <= 0;
      end
    end
  end

  assign MSB_sub_th_sum = sub_th_sum[4*WIDTH-1];
  assign spikle_out     = ~MSB_sub_th_sum;
  assign spike_reg      = spikle_out;
  assign membrane_out   = spike_reg ? sub_th_sum : sum;

  assign membrane_out_reg[31:16] = membrane_out_upper;
  assign membrane_out_reg[15:0]  = membrane_out_lower;

  assign acc_out     = weight_accumulate_reg;
  assign counter_out = counter;
  assign spike_out   = spike_reg;

endmodule
