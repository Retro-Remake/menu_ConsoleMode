// Copyright (C) 2026 Retro-Remake
// SPDX-License-Identifier: GPL-3.0-or-later

// Native video timing, single ~27 MHz clock, mode = status[24:22]

module native_video_timing
(
	input  wire       clk,
	input  wire       ce_pix,
	input  wire       reset,

	input  wire [2:0] mode,              // 0=NTSC 240p, 1=480i 640, 2=PAL 288p, 3=480i 720, 4=576i PAL

	// positive = shift right/down (FP shrinks, BP grows), firmware clamps to porch budget
	input  wire signed [5:0] h_offset,
	input  wire signed [5:0] v_offset,

	output reg        hsync,
	output reg        vsync,
	output reg        hblank,
	output reg        vblank,
	output reg        de,
	output reg [9:0]  hcount,
	output reg [8:0]  vcount,
	output reg        new_frame,
	output reg        new_line,
	output reg        field               // interlace field (always 0 progressive)
);

localparam [2:0] MODE_NTSC    = 3'd0;
localparam [2:0] MODE_480I    = 3'd1;   // 640x480 (square pixel, CRT)
localparam [2:0] MODE_PAL     = 3'd2;
localparam [2:0] MODE_480I_D1 = 3'd3;   // 720x480 (broadcast D1, HDMI)
localparam [2:0] MODE_576I    = 3'd4;   // 720x576i @ 50Hz (PAL interlaced)

wire is_interlaced = (mode == MODE_480I) || (mode == MODE_480I_D1) || (mode == MODE_576I);

reg [9:0] H_ACTIVE, H_FP, H_BP, H_TOTAL;
reg [6:0] H_SYNC;
reg [8:0] V_ACTIVE, V_FP, V_BP, V_TOTAL;
reg [4:0] V_SYNC;

always @* begin
	case(mode)
	MODE_480I: begin
		// 2x the NTSC 320x240 mode (square-pixel CRT)
		H_ACTIVE = 10'd640; H_FP = 10'd28; H_SYNC = 7'd64; H_BP = 10'd126; H_TOTAL = 10'd858;
		V_ACTIVE = 9'd240;  V_FP = 9'd10; V_SYNC = 5'd3;
		V_BP     = field ? 9'd10 : 9'd9;     // odd field carries the extra (525 -> 263/262)
		V_TOTAL  = field ? 9'd263 : 9'd262;
	end
	MODE_480I_D1: begin
		// broadcast D1 non-square pixels, same timing as MODE_480I
		H_ACTIVE = 10'd720; H_FP = 10'd38; H_SYNC = 7'd62; H_BP = 10'd38; H_TOTAL = 10'd858;
		V_ACTIVE = 9'd240;  V_FP = 9'd10; V_SYNC = 5'd3;
		V_BP     = field ? 9'd10 : 9'd9;
		V_TOTAL  = field ? 9'd263 : 9'd262;
	end
	MODE_PAL: begin
		H_ACTIVE = 10'd352; H_FP = 10'd24; H_SYNC = 7'd32; H_BP = 10'd24; H_TOTAL = 10'd432;
		V_ACTIVE = 9'd288;  V_FP = 9'd11; V_SYNC = 5'd3; V_BP = 9'd10; V_TOTAL = 9'd312;
	end
	MODE_576I: begin
		// 720x576i PAL: ce_pix = CLK_VIDEO/2, H_TOTAL 864 (15.625 kHz), 625 lines / 50 fields.
		H_ACTIVE = 10'd720; H_FP = 10'd40; H_SYNC = 7'd64; H_BP = 10'd40; H_TOTAL = 10'd864;
		V_ACTIVE = 9'd288;  V_FP = 9'd10; V_SYNC = 5'd3;
		V_BP     = field ? 9'd12 : 9'd11;    // odd field carries the extra (625 -> 313/312)
		V_TOTAL  = field ? 9'd313 : 9'd312;
	end
	default: begin // MODE_NTSC: tuned calibration, do not change
		H_ACTIVE = 10'd320; H_FP = 10'd14; H_SYNC = 7'd32; H_BP = 10'd63; H_TOTAL = 10'd429;
		V_ACTIVE = 9'd240;  V_FP = 9'd8;  V_SYNC = 5'd3; V_BP = 9'd11; V_TOTAL = 9'd262;
	end
	endcase
end

// Sync window position, shifted by the centering offset.
wire [9:0] H_SYNC_START = H_ACTIVE + (H_FP - {{4{h_offset[5]}}, h_offset});
wire [9:0] H_SYNC_END   = H_SYNC_START + {3'd0, H_SYNC};
wire [8:0] V_SYNC_START = V_ACTIVE + (V_FP - {{3{v_offset[5]}}, v_offset});
wire [8:0] V_SYNC_END   = V_SYNC_START + {4'd0, V_SYNC};

// Interlace: odd field starts vsync a half line early for the 0.5-line offset.
wire       vs_step = field ? (hcount == (H_TOTAL >> 1) - 10'd1) : (hcount == H_TOTAL - 10'd1);
wire [8:0] vs_line = field ? vcount : (vcount + 9'd1);

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
		field     <= 1'b0;
	end
	else if(ce_pix) begin
		reg next_hblank;
		reg next_vblank;
		reg line_wrap;

		new_frame <= 1'b0;
		new_line  <= 1'b0;
		line_wrap = (hcount == H_TOTAL - 10'd1);

		if(line_wrap) begin
			hcount <= 10'd0;
			if(vcount == V_TOTAL - 9'd1) vcount <= 9'd0;
				else vcount <= vcount + 9'd1;
		end
		else begin
			hcount <= hcount + 10'd1;
		end

		if(hcount == H_ACTIVE - 10'd1) hblank <= 1'b1;
			else if(line_wrap) hblank <= 1'b0;

		if(hcount == H_SYNC_START - 10'd1) hsync <= 1'b1;
			else if(hcount == H_SYNC_END - 10'd1) hsync <= 1'b0;

		if(line_wrap) begin
			if(vcount == V_ACTIVE - 9'd1) vblank <= 1'b1;
				else if(vcount == V_TOTAL - 9'd1) vblank <= 1'b0;
		end

		// vsync, field-aware for interlace
		if(vs_step) begin
			if(vs_line == V_SYNC_START) vsync <= 1'b1;
				else if(vs_line == V_SYNC_END) vsync <= 1'b0;
		end

		if(hcount == H_ACTIVE - 10'd1) new_line <= 1'b1;
		if(line_wrap && vcount == V_ACTIVE - 9'd1) begin
			new_frame <= 1'b1;
			field     <= is_interlaced ? ~field : 1'b0;
		end

		next_hblank = hblank;
		if(hcount == H_ACTIVE - 10'd1) next_hblank = 1'b1;
			else if(line_wrap) next_hblank = 1'b0;

		next_vblank = vblank;
		if(line_wrap) begin
			if(vcount == V_ACTIVE - 9'd1) next_vblank = 1'b1;
				else if(vcount == V_TOTAL - 9'd1) next_vblank = 1'b0;
		end

		de <= ~next_hblank & ~next_vblank;
	end
end

endmodule
