// Copyright (C) 2026 Retro-Remake
// SPDX-License-Identifier: GPL-3.0-or-later

// Native video timing, 320x240 at 15.734 kHz from 27 MHz / 4

module native_video_timing
(
	input  wire       clk,
	input  wire       ce_pix,
	input  wire       reset,

	// Image centering: positive = shift right/down (FP shrinks, BP grows).
	input  wire signed [3:0] h_offset,  // -8..+7 pixels (budget H_FP=14 / H_BP=63)
	input  wire signed [3:0] v_offset,  // -8..+7 lines  (budget V_FP=8 / V_BP=11)

	output reg        hsync,
	output reg        vsync,
	output reg        hblank,
	output reg        vblank,
	output reg        de,
	output reg [9:0]  hcount,
	output reg [8:0]  vcount,
	output reg        new_frame,
	output reg        new_line
);

localparam [9:0] H_ACTIVE = 10'd320;
localparam [9:0] H_FP     = 10'd14;
localparam [5:0] H_SYNC   = 6'd32;
localparam [9:0] H_BP     = 10'd63;
localparam [9:0] H_TOTAL  = 10'd429;

// V blanking rebalanced to 8/3/11 for a symmetric +-8 budget, V_TOTAL stays 262
localparam [8:0] V_ACTIVE = 9'd240;
localparam [8:0] V_FP     = 9'd8;
localparam [4:0] V_SYNC   = 5'd3;
localparam [8:0] V_BP     = 9'd11;
localparam [8:0] V_TOTAL  = 9'd262;

// two's-complement subtraction in unsigned arithmetic works at both range ends
wire [9:0] H_SYNC_START = H_ACTIVE + (H_FP - {{6{h_offset[3]}}, h_offset});
wire [9:0] H_SYNC_END   = H_SYNC_START + H_SYNC;
wire [8:0] V_SYNC_START = V_ACTIVE + (V_FP - {{5{v_offset[3]}}, v_offset});
wire [8:0] V_SYNC_END   = V_SYNC_START + V_SYNC;

always @(posedge clk) begin
	if(reset) begin
		hcount    <= 10'd0;
		vcount    <= 9'd0;
		hsync     <= 1'b0;
		vsync     <= 1'b0;
		hblank    <= 1'b0;
		vblank    <= 1'b0;
		de        <= 1'b1;
		new_frame <= 1'b0;
		new_line  <= 1'b0;
	end
	else if(ce_pix) begin
		reg next_hblank;
		reg next_vblank;

		new_frame <= 1'b0;
		new_line  <= 1'b0;

		if(hcount == H_TOTAL - 10'd1) begin
			hcount <= 10'd0;
			if(vcount == V_TOTAL - 9'd1) vcount <= 9'd0;
				else vcount <= vcount + 9'd1;
		end
		else begin
			hcount <= hcount + 10'd1;
		end

		if(hcount == H_ACTIVE - 10'd1) hblank <= 1'b1;
			else if(hcount == H_TOTAL - 10'd1) hblank <= 1'b0;

		if(hcount == H_SYNC_START - 10'd1) hsync <= 1'b1;
			else if(hcount == H_SYNC_END - 10'd1) hsync <= 1'b0;

		if(hcount == H_TOTAL - 10'd1) begin
			if(vcount == V_ACTIVE - 9'd1) vblank <= 1'b1;
				else if(vcount == V_TOTAL - 9'd1) vblank <= 1'b0;

			if(vcount == V_SYNC_START - 9'd1) vsync <= 1'b1;
				else if(vcount == V_SYNC_END - 9'd1) vsync <= 1'b0;
		end

		if(hcount == H_ACTIVE - 10'd1) new_line <= 1'b1;
		if(hcount == H_TOTAL - 10'd1 && vcount == V_ACTIVE - 9'd1) new_frame <= 1'b1;

		next_hblank = hblank;
		if(hcount == H_ACTIVE - 10'd1) next_hblank = 1'b1;
			else if(hcount == H_TOTAL - 10'd1) next_hblank = 1'b0;

		next_vblank = vblank;
		if(hcount == H_TOTAL - 10'd1) begin
			if(vcount == V_ACTIVE - 9'd1) next_vblank = 1'b1;
				else if(vcount == V_TOTAL - 9'd1) next_vblank = 1'b0;
		end

		de <= ~next_hblank & ~next_vblank;
	end
end

endmodule
