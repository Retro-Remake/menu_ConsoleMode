// Copyright (C) 2026 Retro-Remake
// SPDX-License-Identifier: GPL-3.0-or-later

// Native video wrapper: timing + RGBX8888 DDR reader

module native_video_top
(
	input  wire        clk_sys,
	input  wire        clk_vid,
	input  wire        ce_timing,
	input  wire        reset,

	input  wire        ddr_busy,
	output wire  [7:0] ddr_burstcnt,
	output wire [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output wire        ddr_rd,
	output wire [63:0] ddr_din,
	output wire  [7:0] ddr_be,
	output wire        ddr_we,

	output wire  [7:0] vga_r,
	output wire  [7:0] vga_g,
	output wire  [7:0] vga_b,
	output wire        vga_hs,
	output wire        vga_vs,
	output wire        vga_de,
	output wire        vga_hblank,
	output wire        vga_vblank,
	output wire  [8:0] vga_vcount,
	output wire        vga_new_frame,
	output wire        vga_field,

	input  wire        enable,
	output wire        active,

	// 0=NTSC 240p, 1=480i 640, 2=PAL 288p, 3=480i 720, 4=576i PAL
	input  wire  [2:0] mode,
	input  wire signed [5:0] h_offset,
	input  wire signed [5:0] v_offset
);

localparam [2:0] MODE_NTSC = 3'd0;
localparam [2:0] MODE_PAL  = 3'd2;

wire       tim_hs;
wire       tim_vs;
wire       tim_hblank;
wire       tim_vblank;
wire       tim_de;
wire [9:0] tim_hcount;
wire [8:0] tim_vcount;
wire       tim_new_frame;
wire       tim_new_line;
wire       tim_field;

native_video_timing timing
(
	.clk       (clk_vid),
	.ce_pix    (ce_timing),
	.reset     (reset),
	.mode      (mode),
	.h_offset  (h_offset),
	.v_offset  (v_offset),
	.hsync     (tim_hs),
	.vsync     (tim_vs),
	.hblank    (tim_hblank),
	.vblank    (tim_vblank),
	.de        (tim_de),
	.hcount    (tim_hcount),
	.vcount    (tim_vcount),
	.new_frame (tim_new_frame),
	.new_line  (tim_new_line),
	.field     (tim_field)
);

// double low-res pixels on even hcount, phase restarts per line (odd totals would drift it)
wire low_resolution = (mode == MODE_NTSC) || (mode == MODE_PAL);
wire reader_ce      = ce_timing && (!low_resolution || !tim_hcount[0]);

wire frame_ready;
native_video_reader reader
(
	.ddr_clk        (clk_sys),
	.ddr_busy       (ddr_busy),
	.ddr_burstcnt   (ddr_burstcnt),
	.ddr_addr       (ddr_addr),
	.ddr_dout       (ddr_dout),
	.ddr_dout_ready (ddr_dout_ready),
	.ddr_rd         (ddr_rd),
	.ddr_din        (ddr_din),
	.ddr_be         (ddr_be),
	.ddr_we         (ddr_we),
	.clk_vid        (clk_vid),
	.ce_pix         (reader_ce),
	.reset          (reset),
	.de             (tim_de),
	.vblank         (tim_vblank),
	.new_frame      (tim_new_frame),
	.new_line       (tim_new_line),
	.vcount         (tim_vcount),
	.mode_vid       (mode),
	.field          (tim_field),

	.r_out          (vga_r),
	.g_out          (vga_g),
	.b_out          (vga_b),
	.enable_sys     (enable),
	.frame_ready    (frame_ready)
);

assign vga_hs        = tim_hs;
assign vga_vs        = tim_vs;
assign vga_de        = tim_de;
assign vga_hblank    = tim_hblank;
assign vga_vblank    = tim_vblank;
assign vga_vcount    = tim_vcount;
assign vga_new_frame = tim_new_frame;
assign vga_field     = tim_field;
assign active        = enable & frame_ready;

endmodule
