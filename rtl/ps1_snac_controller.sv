// Copyright (C) 2026 Retro-Remake
// SPDX-License-Identifier: GPL-3.0-or-later

// PS1 SNAC pad, SPI LSB first CLK idle high. USER_OUT [0]=~SEL2 [1]=~SEL1 [2]=CMD [5]=CLK, USER_IN [3]=ACK [4]=DAT

module ps1_snac_controller (
    input         clk_sys,
    input         reset,

    input   [6:0] USER_IN,
    output  [6:0] USER_OUT,

    input         snac_enable,

    output [15:0] buttons,            // active HIGH
    output        controller_valid,

    output [7:0]  debug_rx_byte1,
    output [7:0]  debug_rx_byte2,
    output [3:0]  debug_state,

    output        btn_select,
    output        btn_l3,
    output        btn_r3,
    output        btn_start,
    output        btn_up,
    output        btn_right,
    output        btn_down,
    output        btn_left,
    output        btn_l2,
    output        btn_r2,
    output        btn_l1,
    output        btn_r1,
    output        btn_triangle,
    output        btn_circle,
    output        btn_cross,
    output        btn_square
);

// constants assume 100MHz clk_sys, ~125kHz SPI
localparam CLK_HALF = 400;
localparam SELECT_SETUP = 5000;
localparam BYTE_GAP = 1000;
localparam ACK_TIMEOUT = 15000;
localparam POLL_INTERVAL = 1000000;

localparam [3:0] ST_IDLE       = 4'd0;
localparam [3:0] ST_SELECT     = 4'd1;
localparam [3:0] ST_WAIT_SEL   = 4'd2;
localparam [3:0] ST_SETUP_BIT  = 4'd3;
localparam [3:0] ST_CLK_FALL   = 4'd4;
localparam [3:0] ST_CLK_LOW    = 4'd5;
localparam [3:0] ST_CLK_RISE   = 4'd6;
localparam [3:0] ST_CLK_HIGH   = 4'd7;
localparam [3:0] ST_BYTE_DONE  = 4'd8;
localparam [3:0] ST_WAIT_ACK   = 4'd9;
localparam [3:0] ST_BYTE_GAP   = 4'd10;
localparam [3:0] ST_DESELECT   = 4'd11;
localparam [3:0] ST_DONE       = 4'd12;

reg [3:0] state;

reg [19:0] timer;
reg [3:0]  bit_cnt;
reg [2:0]  byte_cnt;
reg [7:0]  tx_shift;
reg [7:0]  rx_shift;
reg [7:0]  rx_buffer [0:4];
reg [15:0] buttons_reg;
reg        valid_reg;
reg [19:0] poll_timer;

// wait ~1s after reset so the pad boots before the first poll, else it wedges
localparam STARTUP_WAIT = 100000000;
reg [26:0] startup_timer;

reg        spi_clk;
reg        spi_cmd;
reg        spi_sel;

function [7:0] get_cmd_byte;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: get_cmd_byte = 8'h01;
            3'd1: get_cmd_byte = 8'h42;
            3'd2: get_cmd_byte = 8'h00;
            3'd3: get_cmd_byte = 8'h00;
            3'd4: get_cmd_byte = 8'h00;
            default: get_cmd_byte = 8'h00;
        endcase
    end
endfunction

reg [2:0] ack_sync;
reg [2:0] dat_sync;

always @(posedge clk_sys) begin
    ack_sync <= {ack_sync[1:0], USER_IN[3]};
    dat_sync <= {dat_sync[1:0], USER_IN[4]};
end

wire ack_active = ~ack_sync[2];        // ACK active low
wire dat_bit = dat_sync[2];

always @(posedge clk_sys or posedge reset) begin
    if (reset) begin
        state       <= ST_IDLE;
        timer       <= 0;
        bit_cnt     <= 0;
        byte_cnt    <= 0;
        tx_shift    <= 8'hFF;
        rx_shift    <= 8'hFF;
        spi_clk     <= 1'b1;
        spi_cmd     <= 1'b1;
        spi_sel     <= 1'b0;
        buttons_reg <= 16'h0000;
        valid_reg   <= 1'b0;
        poll_timer  <= 0;
        startup_timer <= 0;

        for (int i = 0; i < 5; i++)
            rx_buffer[i] <= 8'hFF;
    end
    else begin
        case (state)
            ST_IDLE: begin
                spi_clk <= 1'b1;
                spi_sel <= 1'b0;
                spi_cmd <= 1'b1;

                if (snac_enable) begin
                    if (startup_timer < STARTUP_WAIT) begin
                        startup_timer <= startup_timer + 1'd1;
                    end
                    else if (poll_timer >= POLL_INTERVAL) begin
                        poll_timer <= 0;
                        state      <= ST_SELECT;
                    end
                    else begin
                        poll_timer <= poll_timer + 1'd1;
                    end
                end
                else begin
                    poll_timer <= 0;
                    valid_reg  <= 1'b0;
                end
            end

            ST_SELECT: begin
                spi_sel  <= 1'b1;
                spi_clk  <= 1'b1;
                spi_cmd  <= 1'b1;
                byte_cnt <= 0;
                timer    <= 0;

                for (int i = 0; i < 5; i++)
                    rx_buffer[i] <= 8'hFF;

                state <= ST_WAIT_SEL;
            end

            ST_WAIT_SEL: begin
                timer <= timer + 1'd1;
                if (timer >= SELECT_SETUP) begin
                    tx_shift <= get_cmd_byte(0);
                    rx_shift <= 8'hFF;
                    bit_cnt  <= 0;
                    timer    <= 0;
                    state    <= ST_SETUP_BIT;
                end
            end

            // CMD changes on the falling edge, so set it up while CLK is high
            ST_SETUP_BIT: begin
                spi_clk <= 1'b1;
                timer   <= timer + 1'd1;
                if (timer >= 10) begin
                    timer   <= 0;
                    state   <= ST_CLK_FALL;
                end
            end

            ST_CLK_FALL: begin
                spi_clk <= 1'b0;
                spi_cmd <= tx_shift[0];
                timer   <= 0;
                state   <= ST_CLK_LOW;
            end

            ST_CLK_LOW: begin
                timer <= timer + 1'd1;
                if (timer >= CLK_HALF) begin
                    timer <= 0;
                    state <= ST_CLK_RISE;
                end
            end

            ST_CLK_RISE: begin
                spi_clk <= 1'b1;
                rx_shift <= {dat_bit, rx_shift[7:1]};    // sample on rising edge
                timer <= 0;
                state <= ST_CLK_HIGH;
            end

            ST_CLK_HIGH: begin
                timer <= timer + 1'd1;
                if (timer >= CLK_HALF) begin
                    tx_shift <= {1'b1, tx_shift[7:1]};
                    bit_cnt  <= bit_cnt + 1'd1;
                    timer    <= 0;

                    if (bit_cnt >= 7) begin
                        state <= ST_BYTE_DONE;
                    end
                    else begin
                        state <= ST_SETUP_BIT;
                    end
                end
            end

            ST_BYTE_DONE: begin
                rx_buffer[byte_cnt] <= rx_shift;
                timer <= 0;
                state <= ST_WAIT_ACK;
            end

            ST_WAIT_ACK: begin
                timer <= timer + 1'd1;
                if (ack_active || timer >= ACK_TIMEOUT) begin
                    byte_cnt <= byte_cnt + 1'd1;

                    if (byte_cnt >= 4) begin
                        timer <= 0;
                        state <= ST_DESELECT;
                    end
                    else begin
                        tx_shift <= get_cmd_byte(byte_cnt + 1'd1);
                        rx_shift <= 8'hFF;
                        bit_cnt  <= 0;
                        timer    <= 0;
                        state    <= ST_BYTE_GAP;
                    end
                end
            end

            ST_BYTE_GAP: begin
                timer <= timer + 1'd1;
                if (timer >= BYTE_GAP) begin
                    timer <= 0;
                    state <= ST_SETUP_BIT;
                end
            end

            ST_DESELECT: begin
                spi_sel <= 1'b0;
                spi_clk <= 1'b1;
                spi_cmd <= 1'b1;
                timer   <= 0;
                state   <= ST_DONE;
            end

            // Response: rx_buffer[1]=ID (0x41 digital), [2]=0x5A ready, [3:4]=buttons (active low)
            ST_DONE: begin
                if (rx_buffer[2] == 8'h5A) begin
                    buttons_reg <= ~{rx_buffer[4], rx_buffer[3]};
                    valid_reg   <= 1'b1;
                end
                else if (rx_buffer[1] == 8'h5A) begin
                    buttons_reg <= ~{rx_buffer[3], rx_buffer[2]};
                    valid_reg   <= 1'b1;
                end
                else begin
                    valid_reg <= 1'b0;
                end

                state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

assign USER_OUT[0] = 1'b1;
assign USER_OUT[1] = ~spi_sel;         // SEL1 active low
assign USER_OUT[2] = spi_cmd;
assign USER_OUT[3] = 1'b1;
assign USER_OUT[4] = 1'b1;
assign USER_OUT[5] = spi_clk;
assign USER_OUT[6] = 1'b1;

assign buttons = buttons_reg;
assign controller_valid = valid_reg;

assign debug_rx_byte1 = rx_buffer[1];
assign debug_rx_byte2 = rx_buffer[2];
assign debug_state = state;

assign btn_select   = buttons_reg[0];
assign btn_l3       = buttons_reg[1];
assign btn_r3       = buttons_reg[2];
assign btn_start    = buttons_reg[3];
assign btn_up       = buttons_reg[4];
assign btn_right    = buttons_reg[5];
assign btn_down     = buttons_reg[6];
assign btn_left     = buttons_reg[7];
assign btn_l2       = buttons_reg[8];
assign btn_r2       = buttons_reg[9];
assign btn_l1       = buttons_reg[10];
assign btn_r1       = buttons_reg[11];
assign btn_triangle = buttons_reg[12];
assign btn_circle   = buttons_reg[13];
assign btn_cross    = buttons_reg[14];
assign btn_square   = buttons_reg[15];

endmodule
