//============================================================================
//
//  Menu for MiSTer.
//  Copyright (C) 2017-2020 Sorgelig
//
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign DDRAM_CLK = clk_sys;
assign CE_PIXEL  = ce_timing;

assign VGA_SL = 0;
// 480i interlace field (held 0 by native_video_timing in progressive modes).
wire native_field;
assign VGA_F1 = native_field;
assign VIDEO_ARX = 0;
assign VIDEO_ARY = 0;
assign VGA_SCALER= 0;
assign VGA_DISABLE = 0;

assign AUDIO_MIX = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;

assign LED_DISK = 0;
assign LED_POWER[1]= 1;
assign BUTTONS = 0;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1; 
assign LED_USER    = FB ? led[0] : act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];

wire [26:0] act_cnt2 = {~act_cnt[26],act_cnt[25:0]};
assign LED_POWER[0]= FB ? led[2] : act_cnt2[26] ? act_cnt2[25:18] > act_cnt2[7:0] : act_cnt2[25:18] <= act_cnt2[7:0];


`include "build_id.v"
// Centering offsets, signed: H status[15:10], V status[21:16]
localparam CONF_STR = {
	"MENU;UART31250,MIDI;",
	"-;",
	"O[24:22],Video Mode,NTSC 240p,480i 640,PAL 288p,480i 720,576i PAL;",
	"-;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire [31:0] status;

// SNAC always enabled, status[9] is the native-FB mode not SNAC
wire [15:0] snac_buttons_wire;
wire        snac_valid;
wire        snac_enable = 1'b1;
wire [7:0]  snac_debug_byte1;
wire [7:0]  snac_debug_byte2;
wire [3:0]  snac_debug_state;
wire [15:0] snac_debug_word = {snac_debug_state, snac_valid, USER_IN[4], USER_IN[3],
                               |snac_buttons_wire, snac_buttons_wire[7:4], 4'b0};

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.forced_scandoubler(forced_scandoubler),
	.status(status),
	.status_menumask(cfg),
	.snac_buttons(snac_buttons_wire),
	.snac_debug(snac_debug_word)
);

////////////////////   CLOCKS   ///////////////////
wire locked, clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(CLK_VIDEO),
	.locked(locked)
);


/////////////////////   SDRAM   ///////////////////
//
// Helper functionality:
//    SDRAM and DDR3 RAM are being cleared while this core is working.
//    some cores behave incorrectly if started with non-clean RAM.

sdram sdr
(
	.*,
	.init(~locked),
	.clk(clk_sys),
	.addr(sdram_addr),
	.wtbt(3),
	.dout(sdram_dout),
	.din(sdram_din),
	.rd(sdram_rd),
	.we(sdram_we),
	.ready(sdram_ready)
);

reg  [26:0] sdram_addr;
wire        sdram_ready;
wire [15:0] sdram_dout;
reg  [15:0] sdram_din;
reg         sdram_we;
reg         sdram_rd;
reg  [15:0] cfg = 0;

always @(posedge clk_sys) begin
	reg [4:0] state = 0;

	sdram_rd <= 0;
	sdram_we <= 0;

	if(RESET) begin
		state <= 0;
		cfg <= 0;
	end
	else begin
		case(state)
			0: if(sdram_ready) begin
					cfg <= 0;
					state      <= state+1'd1;
				end
			1: begin
					sdram_addr <= 'h4000000;
					sdram_din  <= 3128;
					sdram_we   <= 1;
					state      <= state+1'd1;
				end
			2: state <= state+1'd1;
			3: if(sdram_ready) begin
					sdram_addr <= 'h2000000;
					sdram_din  <= 2064;
					sdram_we   <= 1;
					state      <= state+1'd1;
				end
			4: state <= state+1'd1;
			5: if(sdram_ready) begin
					sdram_addr <= 'h0000000;
					sdram_din  <= 1032;
					sdram_we   <= 1;
					state      <= state+1'd1;
				end
			6: state <= state+1'd1;
			7: if(sdram_ready) begin
					sdram_addr <= 'h1000000;
					sdram_din  <= 12345;
					sdram_we   <= 1;
					state      <= state+1'd1;
				end
			8: state <= state+1'd1;
			9: if(sdram_ready) begin
					sdram_addr <= 'h4000000;
					sdram_rd   <= 1;
					state      <= state+1'd1;
				end
			10: state <= state+1'd1;
			11: if(sdram_ready) begin
					cfg[2]     <= (sdram_dout == 3128);
					sdram_addr <= 'h2000000;
					sdram_rd   <= 1;
					state      <= state+1'd1;
				end
			12: state <= state+1'd1;
			13: if(sdram_ready) begin
					cfg[1]     <= (sdram_dout == 2064);
					sdram_addr <= 'h0000000;
					sdram_rd   <= 1;
					state      <= state+1'd1;
				end
			14: state <= state+1'd1;
			15: if(sdram_ready) begin
					cfg[0]     <= (sdram_dout == 1032);
					cfg[15]    <= 1;
					state      <= state+1'd1;
				end
			16: begin
					sdram_we <= 0;
				end
		endcase
	end
end

// native_video_reader owns the DDRAM_* signals

////////////////////////////  MT32pi  ////////////////////////////////// 

//
// Pin | USB Name | Signal
// ----+----------+--------------
// 0   | D+       | I/O I2C_SDA / RX (midi in)
// 1   | D-       | O   TX (midi out)
// 2   | TX-      | I   I2S_WS (1 == right)
// 3   | GND_d    | I   I2C_SCL
// 4   | RX+      | I   I2S_BCLK
// 5   | RX-      | I   I2S_DAT
// 6   | TX+      | -   none
//

reg [15:0] mt32_i2s_r, mt32_i2s_l;
wire midi_rx;

assign AUDIO_L = snac_enable ? 16'd0 : mt32_i2s_l;
assign AUDIO_R = snac_enable ? 16'd0 : mt32_i2s_r;
assign AUDIO_S = 1;

wire [6:0] snac_user_out;
assign USER_OUT = snac_enable ? snac_user_out : {5'b11111, UART_RXD, 1'b1};
assign UART_TXD = snac_enable ? 1'b1 : midi_rx;

ps1_snac_controller ps1_snac_inst (
	.clk_sys(clk_sys),
	.reset(RESET),
	.USER_IN(USER_IN),
	.USER_OUT(snac_user_out),
	.snac_enable(snac_enable),
	.buttons(snac_buttons_wire),
	.controller_valid(snac_valid),
	.debug_rx_byte1(snac_debug_byte1),
	.debug_rx_byte2(snac_debug_byte2),
	.debug_state(snac_debug_state),
	.btn_select(), .btn_l3(), .btn_r3(), .btn_start(),
	.btn_up(), .btn_right(), .btn_down(), .btn_left(),
	.btn_l2(), .btn_r2(), .btn_l1(), .btn_r1(),
	.btn_triangle(), .btn_circle(), .btn_cross(), .btn_square()
);


//
// crossed/straight cable selection
//

generate
genvar i;
for(i = 0; i<2; i++) begin : clk_rate
	wire clk_in = i ? USER_IN[6] : USER_IN[4];
	reg [4:0] cnt;
	always @(posedge CLK_AUDIO) begin : clkr
		reg       clk_sr, clk, old_clk;
		reg [4:0] cnt_tmp;

		clk_sr <= clk_in;
		if (clk_sr == clk_in) clk <= clk_sr;

		if(~&cnt_tmp) cnt_tmp <= cnt_tmp + 1'd1;
		else cnt <= '1;

		old_clk <= clk;
		if(~old_clk & clk) begin
			cnt <= cnt_tmp;
			cnt_tmp <= 0;
		end
	end
end

reg crossed;
always @(posedge CLK_AUDIO) crossed <= (clk_rate[0].cnt <= clk_rate[1].cnt);
endgenerate

wire   i2s_ws   = crossed ? USER_IN[2] : USER_IN[5];
wire   i2s_data = crossed ? USER_IN[5] : USER_IN[2];
wire   i2s_bclk = crossed ? USER_IN[4] : USER_IN[6];
assign midi_rx  = crossed ? USER_IN[6] : USER_IN[4];

always @(posedge CLK_AUDIO) begin : i2s_proc
	reg [15:0] i2s_buf = 0;
	reg  [4:0] i2s_cnt = 0;
	reg        clk_sr;
	reg        i2s_clk = 0;
	reg        old_clk, old_ws;
	reg        i2s_next = 0;

	// Debounce clock
	clk_sr <= i2s_bclk;
	if (clk_sr == i2s_bclk) i2s_clk <= clk_sr;

	// Latch data and ws on rising edge
	old_clk <= i2s_clk;
	if (i2s_clk && ~old_clk) begin

		if (~i2s_cnt[4]) begin
			i2s_cnt <= i2s_cnt + 1'd1;
			i2s_buf[~i2s_cnt[3:0]] <= i2s_data;
		end

		// Word Select will change 1 clock before the new word starts
		old_ws <= i2s_ws;
		if (old_ws != i2s_ws) i2s_next <= 1;
	end

	if (i2s_next) begin
		i2s_next <= 0;
		i2s_cnt <= 0;
		i2s_buf <= 0;

		if (i2s_ws) mt32_i2s_l <= i2s_buf;
		else        mt32_i2s_r <= i2s_buf;
	end
	
	if (RESET) begin
		i2s_buf    <= 0;
		mt32_i2s_l <= 0;
		mt32_i2s_r <= 0;
	end
end

/////////////////////   VIDEO   ///////////////////

localparam lfsr_n = 63;

wire PAL = status[4];
wire FB  = status[5];
wire [2:0] led = status[8:6];

// status[24:22]: 0=NTSC 240p, 1=480i 640, 2=PAL 288p, 3=480i 720, 4=576i PAL
wire [2:0] native_mode = status[24:22];

// one CLK_VIDEO/2 timing grid for every mode, low-res pixels doubled in native_video_top
reg ce_timing;
always @(posedge CLK_VIDEO) begin
	if(RESET) ce_timing <= 1'b0;
	else      ce_timing <= ~ce_timing;
end

// Native timing + DDR reader drive all VGA scanout.
wire native_fb_on = status[9];

wire [7:0] native_r;
wire [7:0] native_g;
wire [7:0] native_b;
wire       native_hs;
wire       native_vs;
wire       native_de;
wire [8:0] native_vcount;
wire       native_new_frame;
wire       native_active;

native_video_top native_video
(
	.clk_sys        (clk_sys),
	.clk_vid        (CLK_VIDEO),
	.ce_timing      (ce_timing),
	.reset          (RESET),

	.ddr_busy       (DDRAM_BUSY),
	.ddr_burstcnt   (DDRAM_BURSTCNT),
	.ddr_addr       (DDRAM_ADDR),
	.ddr_dout       (DDRAM_DOUT),
	.ddr_dout_ready (DDRAM_DOUT_READY),
	.ddr_rd         (DDRAM_RD),
	.ddr_din        (DDRAM_DIN),
	.ddr_be         (DDRAM_BE),
	.ddr_we         (DDRAM_WE),

	.vga_r          (native_r),
	.vga_g          (native_g),
	.vga_b          (native_b),
	.vga_hs         (native_hs),
	.vga_vs         (native_vs),
	.vga_de         (native_de),
	.vga_hblank     (),
	.vga_vblank     (),
	.vga_vcount     (native_vcount),
	.vga_new_frame  (native_new_frame),
	.vga_field      (native_field),
	.enable         (native_fb_on),
	.active         (native_active),

	.mode           (native_mode),
	.h_offset       ($signed(status[15:10])),
	.v_offset       ($signed(status[21:16]))
);

// Cosine + LFSR fallback pattern.
reg  [9:0] vvc;
reg  [lfsr_n:0] rnd_reg;
wire [lfsr_n:0] rnd;
wire  [5:0] rnd_c = {rnd_reg[0],rnd_reg[1],rnd_reg[2],rnd_reg[2],rnd_reg[2],rnd_reg[2]};

lfsr #(lfsr_n) random(rnd);

always @(posedge CLK_VIDEO) begin
	if (RESET) vvc <= 10'd0;
	else if (native_new_frame) vvc <= vvc + 10'd6;
	if (ce_timing) rnd_reg <= rnd;
end

reg  [7:0] cos_out;
wire [5:0] cos_g = cos_out[7:3] + 6'd32;
cos cos(vvc + {native_vcount, 2'b00}, cos_out);

wire [7:0] comp_v = (cos_g >= rnd_c) ? {cos_g - rnd_c, 2'b00} : 8'd0;

// status[9]=1 with a ready frame swaps DDR RGB in for the pattern.
wire use_native = native_fb_on & native_active;

assign VGA_DE  = native_de;
assign VGA_HS  = native_hs;
assign VGA_VS  = native_vs;
assign VGA_R   = use_native ? native_r : (native_de ? comp_v : 8'd0);
assign VGA_G   = use_native ? native_g : (native_de ? comp_v : 8'd0);
assign VGA_B   = use_native ? native_b : (native_de ? comp_v : 8'd0);

endmodule
