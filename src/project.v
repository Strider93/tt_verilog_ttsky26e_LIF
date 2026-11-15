/*
 * Copyright (c) 2025 Kosmas Wernhard
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Tapeout wrapper around one LIF processing element (PE) of the
 * master-thesis convolutional SNN accelerator.
 *
 * Byte-wide register interface, driven by the microcontroller on the demo board:
 *   ui_in[7:0]  : DATA
 *   uio[3:0]    : ADDR (input)  - selects write register and read-back byte
 *   uio[4]      : WR   (input)  - rising edge writes DATA to ADDR (synchronised)
 *   uio[5]      : unused input
 *   uio[6]      : last spike (output, result of the last updateLIF)
 *   uio[7]      : spike_vector_full (output)
 *   uo_out[7:0] : read-back byte selected by ADDR
 *
 * Write map:
 *   0x0/0x1 LEAK  lo/hi   (store -leak)
 *   0x2/0x3 THR   lo/hi   (store -Vth)
 *   0x4/0x5 VMEM_IN lo/hi
 *   0x6     ACC   : DATA[3:0]=weight (signed), DATA[4]=spike -> 1-cycle accumulate
 *   0x7     CTRL  : bit0 updateLIF pulse, bit1 membrane_out_lower_bity_n (level),
 *                   bit2 zero_spike_vector pulse, bit3 feedback enable (level)
 * Read map:
 *   0x0-0x5 LEAK/THR/VMEM_IN, 0x6 accumulator,
 *   0x7 status {full, last_spike, spike_now, counter[4:0]},
 *   0x8-0xB membrane_out bytes 0..3, 0xC-0xF spike_vector bytes 0..3
 */

`default_nettype none

module tt_um_strider93_lif (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  // ---------------- write strobe synchroniser / edge detect ----------------
  reg [2:0] wr_sync;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) wr_sync <= 3'b000;
    else wr_sync <= {wr_sync[1:0], uio_in[4]};
  end
  wire       wr_pulse = wr_sync[1] & ~wr_sync[2];
  wire [3:0] addr = uio_in[3:0];

  // ---------------- configuration / command registers ----------------
  reg [15:0] leak_r, thr_r, vmem_in_r;
  reg [3:0]  weight_r;
  reg        spike_in_r;
  reg        acc_r, upd_r, zero_r, upd_d;
  reg        lbn_r, feedback_r;
  reg        last_spike_r;

  wire signed [31:0] membrane_out;
  wire [31:0]        spike_vector;
  wire               spike_vector_full;
  wire [7:0]         acc_val;
  wire [4:0]         counter;
  wire               spike_now;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      leak_r       <= 16'd0;
      thr_r        <= 16'd0;
      vmem_in_r    <= 16'd0;
      weight_r     <= 4'd0;
      spike_in_r   <= 1'b0;
      acc_r        <= 1'b0;
      upd_r        <= 1'b0;
      zero_r       <= 1'b0;
      upd_d        <= 1'b0;
      lbn_r        <= 1'b0;
      feedback_r   <= 1'b0;
      last_spike_r <= 1'b0;
    end else begin
      // command pulses last exactly one clock
      acc_r  <= 1'b0;
      upd_r  <= 1'b0;
      zero_r <= 1'b0;
      upd_d  <= upd_r;

      if (upd_r) last_spike_r <= spike_now;

      // membrane feedback: one cycle after updateLIF copy the selected half back
      if (upd_d && feedback_r) vmem_in_r <= lbn_r ? membrane_out[31:16] : membrane_out[15:0];

      if (wr_pulse) begin
        case (addr)
          4'h0: leak_r[7:0] <= ui_in;
          4'h1: leak_r[15:8] <= ui_in;
          4'h2: thr_r[7:0] <= ui_in;
          4'h3: thr_r[15:8] <= ui_in;
          4'h4: vmem_in_r[7:0] <= ui_in;
          4'h5: vmem_in_r[15:8] <= ui_in;
          4'h6: begin
            weight_r   <= ui_in[3:0];
            spike_in_r <= ui_in[4];
            acc_r      <= 1'b1;
          end
          4'h7: begin
            upd_r      <= ui_in[0];
            lbn_r      <= ui_in[1];
            zero_r     <= ui_in[2];
            feedback_r <= ui_in[3];
          end
          default: ;
        endcase
      end
    end
  end

  // ---------------- the thesis LIF neuron ----------------
  lif_pe #(
      .WIDTH(4)
  ) pe (
      .clk                      (clk),
      .rst_n                    (rst_n),
      .accumulate               (acc_r),
      .updateLIF                (upd_r),
      .membrane_out_lower_bity_n(lbn_r),
      .spike                    (spike_in_r),
      .zero_spike_vector        (zero_r),
      .weight                   (weight_r),
      .leakage_reg              (leak_r),
      .threshold_reg            (thr_r),
      .membrane_in_reg          (vmem_in_r),
      .hx_active                (1'b1),
      .k_active                 (1'b1),
      .membrane_out_reg         (membrane_out),
      .spike_vector_reg         (spike_vector),
      .spike_vector_full        (spike_vector_full),
      .acc_out                  (acc_val),
      .counter_out              (counter),
      .spike_out                (spike_now)
  );

  // ---------------- read-back mux ----------------
  reg [7:0] rdata;
  always @(*) begin
    case (addr)
      4'h0: rdata = leak_r[7:0];
      4'h1: rdata = leak_r[15:8];
      4'h2: rdata = thr_r[7:0];
      4'h3: rdata = thr_r[15:8];
      4'h4: rdata = vmem_in_r[7:0];
      4'h5: rdata = vmem_in_r[15:8];
      4'h6: rdata = acc_val;
      4'h7: rdata = {spike_vector_full, last_spike_r, spike_now, counter};
      4'h8: rdata = membrane_out[7:0];
      4'h9: rdata = membrane_out[15:8];
      4'hA: rdata = membrane_out[23:16];
      4'hB: rdata = membrane_out[31:24];
      4'hC: rdata = spike_vector[7:0];
      4'hD: rdata = spike_vector[15:8];
      4'hE: rdata = spike_vector[23:16];
      default: rdata = spike_vector[31:24];
    endcase
  end

  assign uo_out  = rdata;
  assign uio_out = {spike_vector_full, last_spike_r, 6'b0};
  assign uio_oe  = 8'b1100_0000;

  wire _unused = &{ena, uio_in[7:5], 1'b0};

endmodule
