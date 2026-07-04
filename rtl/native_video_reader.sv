// Copyright (C) 2026 Retro-Remake
// SPDX-License-Identifier: GPL-3.0-or-later

// Native video DDR reader. Ctrl word = (frame<<2)|active_buffer, pixels RGBX8888

module native_video_reader
(
	input  wire        ddr_clk,
	input  wire        ddr_busy,
	output reg   [7:0] ddr_burstcnt,
	output reg  [28:0] ddr_addr,
	input  wire [63:0] ddr_dout,
	input  wire        ddr_dout_ready,
	output reg         ddr_rd,
	output wire [63:0] ddr_din,
	output wire  [7:0] ddr_be,
	output wire        ddr_we,

	input  wire        clk_vid,
	input  wire        ce_pix,
	input  wire        reset,
	input  wire        de,
	input  wire        vblank,
	input  wire        new_frame,
	input  wire        new_line,
	input  wire  [8:0] vcount,

	output reg   [7:0] r_out,
	output reg   [7:0] g_out,
	output reg   [7:0] b_out,
	input  wire        enable,
	output wire        frame_ready
);

assign ddr_din = 64'd0;
assign ddr_be  = 8'hFF;
assign ddr_we  = 1'b0;

localparam [28:0] CTRL_ADDR   = 29'h07400000;
localparam [28:0] BUF0_ADDR   = 29'h07400020;
localparam [28:0] BUF1_ADDR   = 29'h07409620;
localparam [7:0]  LINE_BURST  = 8'd160;
localparam [28:0] LINE_STRIDE = 29'd160;
localparam [8:0]  V_ACTIVE    = 9'd240;
localparam [19:0] TIMEOUT_MAX = 20'hF_FFFF;

reg [1:0] enable_sync;
always @(posedge ddr_clk) begin
	if(reset) enable_sync <= 2'b0;
		else enable_sync <= {enable_sync[0], enable};
end
wire enable_ddr = enable_sync[1];

reg [1:0] new_frame_sync;
always @(posedge ddr_clk) begin
	if(reset) new_frame_sync <= 2'b0;
		else new_frame_sync <= {new_frame_sync[0], new_frame};
end
wire new_frame_ddr = ~new_frame_sync[1] & new_frame_sync[0];

reg [1:0] new_line_sync;
always @(posedge ddr_clk) begin
	if(reset) new_line_sync <= 2'b0;
		else new_line_sync <= {new_line_sync[0], new_line};
end
wire new_line_ddr = ~new_line_sync[1] & new_line_sync[0];

reg [1:0] vblank_sync;
always @(posedge ddr_clk) begin
	if(reset) vblank_sync <= 2'b0;
		else vblank_sync <= {vblank_sync[0], vblank};
end
wire vblank_ddr = vblank_sync[1];

reg [1:0] reset_vid_sync;
always @(posedge clk_vid or posedge reset) begin
	if(reset) reset_vid_sync <= 2'b11;
		else reset_vid_sync <= {reset_vid_sync[0], 1'b0};
end
wire reset_vid = reset_vid_sync[1];

reg frame_ready_reg;
reg [1:0] frame_ready_sync;
always @(posedge clk_vid) begin
	if(reset_vid) frame_ready_sync <= 2'b0;
		else frame_ready_sync <= {frame_ready_sync[0], frame_ready_reg};
end
wire frame_ready_vid = frame_ready_sync[1];
assign frame_ready = frame_ready_vid;

localparam [3:0] ST_IDLE         = 4'd0;
localparam [3:0] ST_POLL_CTRL    = 4'd1;
localparam [3:0] ST_WAIT_CTRL    = 4'd2;
localparam [3:0] ST_CHECK_CTRL   = 4'd3;
localparam [3:0] ST_READ_LINE    = 4'd4;
localparam [3:0] ST_WAIT_LINE    = 4'd5;
localparam [3:0] ST_LINE_DONE    = 4'd6;
localparam [3:0] ST_WAIT_DISPLAY = 4'd7;

reg  [3:0]  state;
reg  [31:0] ctrl_word;
reg  [29:0] prev_frame_counter;
reg  [28:0] buf_base_addr;
reg  [8:0]  cur_line;
reg  [7:0]  beat_count;
reg         first_frame_loaded;
reg         preloading;
reg  [19:0] timeout_cnt;
reg         fifo_wr;
reg  [63:0] fifo_wr_data;
wire        fifo_full;

reg [3:0] fifo_aclr_cnt;
wire fifo_aclr_ddr_active = (fifo_aclr_cnt != 4'd0);
wire fifo_aclr = reset | fifo_aclr_ddr_active;

always @(posedge ddr_clk) begin
	if(reset) begin
		state              <= ST_IDLE;
		ddr_rd             <= 1'b0;
		ddr_burstcnt       <= 8'd1;
		ddr_addr           <= 29'd0;
		ctrl_word          <= 32'd0;
		prev_frame_counter <= 30'd0;
		buf_base_addr      <= BUF0_ADDR;
		cur_line           <= 9'd0;
		beat_count         <= 8'd0;
		first_frame_loaded <= 1'b0;
		frame_ready_reg    <= 1'b0;
		preloading         <= 1'b0;
		timeout_cnt        <= 20'd0;
		fifo_wr            <= 1'b0;
		fifo_wr_data       <= 64'd0;
		fifo_aclr_cnt      <= 4'd0;
	end
	else begin
		fifo_wr <= 1'b0;
		if(fifo_aclr_cnt != 4'd0) fifo_aclr_cnt <= fifo_aclr_cnt - 4'd1;
		if(!ddr_busy) ddr_rd <= 1'b0;

		if(state == ST_WAIT_LINE && ddr_dout_ready) begin
			fifo_wr      <= 1'b1;
			fifo_wr_data <= ddr_dout;
			beat_count   <= beat_count + 8'd1;
			timeout_cnt  <= 20'd0;
		end

		case(state)
			ST_IDLE: begin
				if(enable_ddr && new_frame_ddr) state <= ST_POLL_CTRL;
			end

			ST_POLL_CTRL: begin
				if(!ddr_busy) begin
					ddr_addr     <= CTRL_ADDR;
					ddr_burstcnt <= 8'd1;
					ddr_rd       <= 1'b1;
					timeout_cnt  <= 20'd0;
					state        <= ST_WAIT_CTRL;
				end
			end

			ST_WAIT_CTRL: begin
				if(ddr_dout_ready) begin
					ctrl_word   <= ddr_dout[31:0];
					timeout_cnt <= 20'd0;
					state       <= ST_CHECK_CTRL;
				end
				else if(timeout_cnt == TIMEOUT_MAX) state <= ST_IDLE;
				else timeout_cnt <= timeout_cnt + 20'd1;
			end

			ST_CHECK_CTRL: begin
				if(ctrl_word[31:2] != prev_frame_counter) begin
					prev_frame_counter <= ctrl_word[31:2];
					buf_base_addr      <= ctrl_word[0] ? BUF1_ADDR : BUF0_ADDR;
					cur_line           <= 9'd0;
					preloading         <= 1'b1;
					fifo_aclr_cnt      <= 4'd8;
					if(first_frame_loaded) frame_ready_reg <= 1'b1;
					state              <= ST_READ_LINE;
				end
				else if(first_frame_loaded) begin
					cur_line      <= 9'd0;
					preloading    <= 1'b1;
					fifo_aclr_cnt <= 4'd8;
					state         <= ST_READ_LINE;
				end
				else begin
					state <= ST_IDLE;
				end
			end

			ST_READ_LINE: begin
				if(!ddr_busy && !fifo_aclr_ddr_active) begin
					ddr_addr     <= buf_base_addr + (cur_line * LINE_STRIDE);
					ddr_burstcnt <= LINE_BURST;
					ddr_rd       <= 1'b1;
					beat_count   <= 8'd0;
					timeout_cnt  <= 20'd0;
					state        <= ST_WAIT_LINE;
				end
			end

			ST_WAIT_LINE: begin
				if(beat_count == LINE_BURST) state <= ST_LINE_DONE;
				else if(timeout_cnt == TIMEOUT_MAX) state <= ST_IDLE;
				else if(!ddr_dout_ready) timeout_cnt <= timeout_cnt + 20'd1;
			end

			ST_LINE_DONE: begin
				cur_line <= cur_line + 9'd1;
				if(cur_line == V_ACTIVE - 9'd1) begin
					first_frame_loaded <= 1'b1;
					frame_ready_reg    <= 1'b1;
					preloading         <= 1'b0;
					state              <= ST_IDLE;
				end
				else if(preloading && cur_line < 9'd1) begin
					state <= ST_READ_LINE;
				end
				else begin
					preloading <= 1'b0;
					state      <= ST_WAIT_DISPLAY;
				end
			end

			ST_WAIT_DISPLAY: begin
				if(cur_line < V_ACTIVE && new_line_ddr && !vblank_ddr) state <= ST_READ_LINE;
			end

			default: state <= ST_IDLE;
		endcase
	end
end

wire [63:0] fifo_rd_data;
wire        fifo_empty;
reg         fifo_rd;

dcfifo #(
	.intended_device_family ("Cyclone V"),
	.lpm_numwords           (512),
	.lpm_showahead          ("ON"),
	.lpm_type               ("dcfifo"),
	.lpm_width              (64),
	.lpm_widthu             (9),
	.overflow_checking      ("ON"),
	.rdsync_delaypipe       (4),
	.underflow_checking     ("ON"),
	.use_eab                ("ON"),
	.wrsync_delaypipe       (4)
) line_fifo (
	.aclr     (fifo_aclr),
	.data     (fifo_wr_data),
	.rdclk    (clk_vid),
	.rdreq    (fifo_rd),
	.wrclk    (ddr_clk),
	.wrreq    (fifo_wr),
	.q        (fifo_rd_data),
	.rdempty  (fifo_empty),
	.wrfull   (fifo_full),
	.eccstatus(),
	.rdfull   (),
	.rdusedw  (),
	.wrempty  (),
	.wrusedw  ()
);

reg [63:0] pixel_word;
reg        pixel_high;
reg        pixel_word_valid;

wire [31:0] pixel_low  = pixel_word[31:0];
wire [31:0] pixel_high_word = pixel_word[63:32];

task automatic output_pixel;
	input [31:0] pixel;
	begin
		// DDR pixels land as B,G,R,X (linuxfb order)
		r_out <= pixel[23:16];
		g_out <= pixel[15:8];
		b_out <= pixel[7:0];
	end
endtask

always @(posedge clk_vid) begin
	if(reset_vid) begin
		fifo_rd          <= 1'b0;
		r_out            <= 8'd0;
		g_out            <= 8'd0;
		b_out            <= 8'd0;
		pixel_word       <= 64'd0;
		pixel_high       <= 1'b0;
		pixel_word_valid <= 1'b0;
	end
	else begin
		fifo_rd <= 1'b0;

		if(ce_pix) begin
			if(de && frame_ready_vid) begin
				if(pixel_word_valid) begin
					if(pixel_high) begin
						output_pixel(pixel_high_word);
						pixel_word_valid <= 1'b0;
						pixel_high       <= 1'b0;
					end
					else begin
						output_pixel(pixel_low);
						pixel_high <= 1'b1;
					end
				end
				else if(!fifo_empty) begin
					pixel_word       <= fifo_rd_data;
					pixel_word_valid <= 1'b1;
					pixel_high       <= 1'b1;
					fifo_rd          <= 1'b1;
					output_pixel(fifo_rd_data[31:0]);
				end
				else begin
					r_out <= 8'd0;
					g_out <= 8'd0;
					b_out <= 8'd0;
				end
			end
			else begin
				r_out            <= 8'd0;
				g_out            <= 8'd0;
				b_out            <= 8'd0;
				pixel_high       <= 1'b0;
				pixel_word_valid <= 1'b0;
			end
		end
	end
end

endmodule
