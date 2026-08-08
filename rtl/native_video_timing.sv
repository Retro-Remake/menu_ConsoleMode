// Copyright (C) 2026 Retro-Remake
// SPDX-License-Identifier: GPL-3.0-or-later

// Native video timing. 15kHz modes run a CLK_VIDEO/2 grid, 480p runs full rate at 858

module native_video_timing
(
	input  wire       clk,
	input  wire       ce_pix,
	input  wire       reset,

	input  wire [2:0] mode,              // 0=NTSC 240p, 1=480i 640, 2=PAL 288p, 3=480i 720, 4=576i PAL, 5=480p, 6=576p, 7=480p 640
	// positive = shift right/down (FP shrinks, BP grows), firmware clamps to porch budget
	input  wire signed [5:0] h_offset,
	input  wire signed [5:0] v_offset,

	output reg        hsync,
	output reg        vsync,
	output reg        hblank,
	output reg        vblank,
	output reg        de,
	output reg [9:0]  hcount,
	output reg [9:0]  vcount,          // 10-bit: 480p counts 525 lines per frame
	output reg        new_frame,
	output reg        new_line,
	output reg        field               // interlace field (always 0 progressive)
);

localparam [2:0] MODE_NTSC    = 3'd0;
localparam [2:0] MODE_480I    = 3'd1;   // 640x480 source
localparam [2:0] MODE_PAL     = 3'd2;
localparam [2:0] MODE_480I_D1 = 3'd3;   // 720x480 D1
localparam [2:0] MODE_576I    = 3'd4;   // 720x576 D1
localparam [2:0] MODE_480P    = 3'd5;   // 720x480 progressive, 31kHz
localparam [2:0] MODE_576P    = 3'd6;   // 720x576 progressive, 31kHz
localparam [2:0] MODE_480P_SQ = 3'd7;   // 640x480 progressive, 31kHz

wire is_interlaced = (mode == MODE_480I) ||
                     (mode == MODE_480I_D1) ||
                     (mode == MODE_576I);

reg [9:0] H_ACTIVE, H_FP, H_BP;
reg [6:0] H_SYNC;
reg [9:0] V_ACTIVE, V_FP, V_BP;
reg [4:0] V_SYNC;

always @* begin
	case(mode)
	MODE_480I: begin
		// 640 active samples centered in the 859-sample NTSC line.
		H_ACTIVE = 10'd640; H_FP = 10'd56; H_SYNC = 7'd62; H_BP = 10'd101;
		V_ACTIVE = 10'd240; V_FP = 10'd10; V_SYNC = 5'd3;
		V_BP     = field ? 10'd10 : 10'd9;   // 525 total lines: 263/262
	end

	MODE_480I_D1: begin
		// 720x480: standard 16/62/60 split plus one sample in back porch.
		H_ACTIVE = 10'd720; H_FP = 10'd16; H_SYNC = 7'd62; H_BP = 10'd61;
		V_ACTIVE = 10'd240; V_FP = 10'd10; V_SYNC = 5'd3;
		V_BP     = field ? 10'd10 : 10'd9;
	end

	MODE_PAL: begin
		// 352 source pixels are doubled to 704 active timing samples.
		H_ACTIVE = 10'd704; H_FP = 10'd20; H_SYNC = 7'd64; H_BP = 10'd77;
		V_ACTIVE = 10'd288; V_FP = 10'd11; V_SYNC = 5'd3; V_BP = 10'd10;
	end

	MODE_576I: begin
		// 720x576: standard 12/64/68 split plus one sample in back porch.
		H_ACTIVE = 10'd720; H_FP = 10'd12; H_SYNC = 7'd64; H_BP = 10'd69;
		V_ACTIVE = 10'd288; V_FP = 10'd10; V_SYNC = 5'd3;
		V_BP     = field ? 10'd12 : 10'd11;  // 625 total lines: 313/312
	end

	MODE_480P: begin
		// CEA-861 720x480p: 858 samples and 525 lines at the full 27.027MHz rate
		H_ACTIVE = 10'd720; H_FP = 10'd16; H_SYNC = 7'd62; H_BP = 10'd60;
		V_ACTIVE = 10'd480; V_FP = 10'd9;  V_SYNC = 5'd6; V_BP = 10'd30;
	end

	MODE_576P: begin
		// BT.1358 720x576p: 864 samples and 625 lines at the full 27MHz rate
		H_ACTIVE = 10'd720; H_FP = 10'd12; H_SYNC = 7'd64; H_BP = 10'd68;
		V_ACTIVE = 10'd576; V_FP = 10'd5;  V_SYNC = 5'd5; V_BP = 10'd39;
	end

	MODE_480P_SQ: begin
		// 640 active centered in the same 858-sample 480p line
		H_ACTIVE = 10'd640; H_FP = 10'd56; H_SYNC = 7'd62; H_BP = 10'd100;
		V_ACTIVE = 10'd480; V_FP = 10'd9;  V_SYNC = 5'd6; V_BP = 10'd30;
	end

	default: begin // MODE_NTSC
		// 320 source pixels are doubled to 640 active timing samples.
		H_ACTIVE = 10'd640; H_FP = 10'd56; H_SYNC = 7'd62; H_BP = 10'd101;
		V_ACTIVE = 10'd240; V_FP = 10'd8;  V_SYNC = 5'd3; V_BP = 10'd11;
	end
	endcase
end

// totals derived so the declared back porch is the one the raster uses
wire [10:0] H_TOTAL_WIDE = {1'b0, H_ACTIVE}
                           + {1'b0, H_FP}
                           + {4'd0, H_SYNC}
                           + {1'b0, H_BP};
wire [9:0] H_TOTAL = H_TOTAL_WIDE[9:0];

wire [10:0] V_TOTAL_WIDE = {1'b0, V_ACTIVE}
                           + {1'b0, V_FP}
                           + {6'd0, V_SYNC}
                           + {1'b0, V_BP};
wire [9:0] V_TOTAL = V_TOTAL_WIDE[9:0];

// Sync window position, shifted by the centering offset.
wire [9:0] H_SYNC_START = H_ACTIVE + (H_FP - {{4{h_offset[5]}}, h_offset});
wire [9:0] H_SYNC_END   = H_SYNC_START + {3'd0, H_SYNC};
wire [9:0] V_SYNC_START = V_ACTIVE + (V_FP - {{4{v_offset[5]}}, v_offset});
wire [9:0] V_SYNC_END   = V_SYNC_START + {5'd0, V_SYNC};

// Interlace: odd field starts vsync near the half-line point.
wire       vs_step = field ? (hcount == (H_TOTAL >> 1) - 10'd1)
                           : (hcount == H_TOTAL - 10'd1);

// serrate vsync with half-line hsync so sync-on-green keeps H-PLL lock through vblank
wire       serrate    = (mode >= MODE_480P) && vsync;
wire [9:0] half_tot   = H_TOTAL >> 1;
wire [9:0] serr_start = (H_SYNC_START >= half_tot) ? (H_SYNC_START - half_tot)
                                                   : (H_SYNC_START + half_tot);
wire [9:0] serr_end   = serr_start + {3'd0, H_SYNC};
wire [9:0] vs_line = field ? vcount : (vcount + 10'd1);

always @(posedge clk) begin
	if(reset) begin
		hcount    <= 10'd0;
		vcount    <= 10'd0;
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
			if(vcount == V_TOTAL - 10'd1) vcount <= 10'd0;
			else                          vcount <= vcount + 10'd1;
		end
		else begin
			hcount <= hcount + 10'd1;
		end

		if(hcount == H_ACTIVE - 10'd1) hblank <= 1'b1;
		else if(line_wrap)              hblank <= 1'b0;

		if(hcount == H_SYNC_START - 10'd1) hsync <= 1'b1;
		else if(hcount == H_SYNC_END - 10'd1) hsync <= 1'b0;
		else if(serrate && hcount == serr_start - 10'd1) hsync <= 1'b1;
		else if(serrate && hcount == serr_end - 10'd1) hsync <= 1'b0;

		if(line_wrap) begin
			if(vcount == V_ACTIVE - 10'd1) vblank <= 1'b1;
			else if(vcount == V_TOTAL - 10'd1) vblank <= 1'b0;
		end

		if(vs_step) begin
			if(vs_line == V_SYNC_START)      vsync <= 1'b1;
			else if(vs_line == V_SYNC_END)   vsync <= 1'b0;
		end

		if(hcount == H_ACTIVE - 10'd1) new_line <= 1'b1;
		if(line_wrap && vcount == V_ACTIVE - 10'd1) begin
			new_frame <= 1'b1;
			field     <= is_interlaced ? ~field : 1'b0;
		end

		next_hblank = hblank;
		if(hcount == H_ACTIVE - 10'd1) next_hblank = 1'b1;
		else if(line_wrap)              next_hblank = 1'b0;

		next_vblank = vblank;
		if(line_wrap) begin
			if(vcount == V_ACTIVE - 10'd1) next_vblank = 1'b1;
			else if(vcount == V_TOTAL - 10'd1) next_vblank = 1'b0;
		end

		de <= ~next_hblank & ~next_vblank;
	end
end

endmodule
