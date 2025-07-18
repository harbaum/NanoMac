/*
    top.sv - NanoMac on tang nano 20k toplevel

    openFPGALoader --external-flash -o 0x480000 plusrom.bin
*/ 
 
module top(
  input			clk,

  input			reset, // button S2
  input			user, // button S1

  output [5:0]	leds_n,
  output		ws2812,

  // spi flash interface
  output		mspi_cs,
  output		mspi_clk,
  inout			mspi_di,
  inout			mspi_hold,
  inout			mspi_wp,
  inout			mspi_do,

  // "Magic" port names that the gowin compiler connects to the on-chip SDRAM
  output		O_sdram_clk,
  output		O_sdram_cke,
  output		O_sdram_cs_n, // chip select
  output		O_sdram_cas_n, // columns address select
  output		O_sdram_ras_n, // row address select
  output		O_sdram_wen_n, // write enable
  inout [31:0]	IO_sdram_dq, // 32 bit bidirectional data bus
  output [10:0]	O_sdram_addr, // 11 bit multiplexed address bus
  output [1:0]	O_sdram_ba, // two banks
  output [3:0]	O_sdram_dqm, // 32/4

  // generic IO, used for mouse/joystick/...
  input [7:0]	io,

  // interface to external BL616/M0S
  inout [5:0]	m0s,

  // SD card slot
  output		sd_clk,
  inout			sd_cmd, // MOSI
  inout [3:0]	sd_dat, // 0: MISO

  output		midi_out,
  input	        midi_in,
		   
  // hdmi/tdms
  output		tmds_clk_n,
  output		tmds_clk_p,
  output [2:0]	tmds_d_n,
  output [2:0]	tmds_d_p
);

// The mac actually runs at 78 Mhz HDMI clock (sould be 78.32).
// The resulting pixel clock is thus 15.6 MHz and the CPU clock
// 7.8 MHz

`define PIXEL_CLOCK 15600000

wire clk_pixel_x5;   
wire pll_lock;   
pll_80m pll_hdmi (
    .clkout(clk_pixel_x5),
    .lock(pll_lock),
    .clkin(clk)
);

wire clk_pixel;
Gowin_CLKDIV clk_div_5 (
    .hclkin(clk_pixel_x5), // input hclkin
    .resetn(pll_lock),     // input resetn
    .clkout(clk_pixel)     // output clkout
);
   
// control signals generated by the user via the OSD
wire       osd_reset;   
wire       osd_widescreen;      // 0=normal, 1=wide   
wire       osd_serial_ext;      // 0=WiFi, 1=external   
wire [1:0] osd_memory;          // 0=128k, 1=512k, 2=1M, 3=4M
wire [1:0] osd_floppy_wprot;    // 0=int, 1=ext
wire       osd_hdd_wprot;       // 0=rw, 1=ro

// busphase 0..7 of mac. Used to synchronize sdram to video and cpu
wire [2:0] phase;
   
wire flash_ready;
wire ram_ready;      

// generate a reset for some time after rom has been initialized
reg [15:0] reset_cnt;
always @(negedge clk_pixel) begin
    if(!pll_lock || reset || !ram_ready || !flash_ready || osd_reset)
        reset_cnt <= 16'hfff;
    else if(reset_cnt != 0)
        reset_cnt = reset_cnt - 16'd1;
end

// this is the reset that goes into the nanomig itself
wire cpu_reset = |reset_cnt;

// -------------------------- M0S MCU interface -----------------------

// connect to ws2812 led
wire [23:0] ws2812_color;
ws2812 #(.CLK_FRE(`PIXEL_CLOCK)) ws2812_inst (
    .clk(clk_pixel),
    .reset(!pll_lock),
    .color(ws2812_color),
    .data(ws2812)
);

// interface to M0S MCU
wire       mcu_sys_strobe;        // mcu message byte valid for sysctrl
wire       mcu_hid_strobe;        // -"- hid
wire       mcu_osd_strobe;        // -"- osd
wire       mcu_sdc_strobe;        // -"- sdc
wire       mcu_start;             // first byte of MCU message

wire [7:0] mcu_data_out;  

wire [7:0] sys_data_out;  
wire [7:0] hid_data_out;  
wire [7:0] osd_data_out = 8'h55;  // OSD actually has no data output
wire [7:0] sdc_data_out;

mcu_spi mcu (
	 .clk(clk_pixel),
	 .reset(!pll_lock),

     // SPI interface to FPGA Companion
     .spi_io_ss(m0s[2]),
     .spi_io_clk(m0s[3]),
     .spi_io_din(m0s[1]),
     .spi_io_dout(m0s[0]),

     // byte wide data in/out to the submodules
     .mcu_sys_strobe(mcu_sys_strobe),
     .mcu_hid_strobe(mcu_hid_strobe),
     .mcu_osd_strobe(mcu_osd_strobe),
     .mcu_sdc_strobe(mcu_sdc_strobe),
     .mcu_start(mcu_start),
     .mcu_dout(mcu_data_out),
     .mcu_sys_din(sys_data_out),
     .mcu_hid_din(hid_data_out),
     .mcu_osd_din(osd_data_out),
     .mcu_sdc_din(sdc_data_out)
);

// decode SPI/MCU data received for human input devices (HID) and
// convert into Amiga compatible mouse and keyboard signals
wire [7:0] int_ack;
wire hid_int;
wire hid_iack = int_ack[1];
wire sdc_iack = int_ack[3];
wire sdc_int;
   
// keyboard and mouse interface to Mac
wire [4:0] mouse;  
wire	   kbd_strobe;
wire [9:0] kbd_data;   
   
hid hid (
        .clk(clk_pixel),
        .reset(!pll_lock),

         // interface to receive user data from MCU (mouse, kbd, ...)
        .data_in_strobe(mcu_hid_strobe),
        .data_in_start(mcu_start),
        .data_in(mcu_data_out),
        .data_out(hid_data_out),

        // input local db9 port events to be sent to MCU. Changes also trigger
        // an interrupt, so the MCU doesn't have to poll for joystick events
        .db9_port( db9_joy ),
        .irq( hid_int ),
        .iack( hid_iack ),

        // keyboard & mouse                             
        .mouse(mouse),
        .kbd_strobe(kbd_strobe),
        .kbd_data(kbd_data),
                 
        .joystick0(),
        .joystick1()
         );

// switch between internal wifi and external (midi)   
wire uart_rxd, uart_txd;
wire wifi_rxd, wifi_txd;

assign midi_out = osd_serial_ext?uart_txd:1'b1;
assign wifi_txd = osd_serial_ext?1'b1:uart_txd;
assign uart_rxd = osd_serial_ext?midi_in:wifi_rxd;
   
sysctrl sysctrl (
        .clk(clk_pixel),
        .reset(!pll_lock),

         // interface to send and receive generic system control
        .data_in_strobe(mcu_sys_strobe),
        .data_in_start(mcu_start),
        .data_in(mcu_data_out),
        .data_out(sys_data_out),

        // values controlled by the OSD
        .system_reset(osd_reset),
        .system_widescreen(osd_widescreen),
        .system_serial_ext(osd_serial_ext),
        .system_memory(osd_memory),
		.system_floppy_wprot(osd_floppy_wprot),
		.system_hdd_wprot(osd_hdd_wprot),
                                 
        .int_out_n(m0s[4]),
        .int_in( { 4'b0000, sdc_int, 1'b0, hid_int, 1'b0 }),
        .int_ack( int_ack ),

		// syscontrol for nanomac implements a 9600 bit/s 8n1 uart for the
		// wifi at interface
		.uart_rxd( wifi_rxd ),   // into core
		.uart_txd( wifi_txd ),   // from core
				 
        .buttons( {user, reset} ),
        .leds(),
        .color(ws2812_color)
);
   
// -------------------------- SD card -------------------------------

wire [31:0] sdc_lba;
wire [3:0]  sdc_rd;
wire [3:0]  sdc_wr;
wire        sdc_busy;
wire        sdc_done;
wire [8:0]  sdc_addr;
wire [7:0]  sdc_data_read;
wire [7:0]  sdc_data_write;
wire        sdc_data_read_en;

//assign sdc_rd[7:4] = 4'b0000;
//assign sdc_wr[7:4] = 4'b0000;   

wire [31:0] sdc_image_size;
wire [7:0] sdc_image_mounted;   
   
sd_card #(
    .CLK_DIV(3'd1)                    // for 32 Mhz clock
) sd_card (
    .clk(clk_pixel),                  // clock
    .rstn(pll_lock),                  // rstn active-low, 1:working, 0:reset
  
    // SD card signals
    .sdclk(sd_clk),
    .sdcmd(sd_cmd),
    .sddat(sd_dat),
    
    // mcu interface
    .data_strobe(mcu_sdc_strobe),
    .data_start(mcu_start),
    .data_in(mcu_data_out),
    .data_out(sdc_data_out),

    // output file/image information. Image size is e.g. used by fdc to 
    // translate between sector/track/side and lba sector
    .image_size(sdc_image_size),           // length of image file
    .image_mounted(sdc_image_mounted),

    // interrupt to signal communication request
    .irq(sdc_int),
    .iack(sdc_iack),

    // user read sector command interface (sync with clk)
    .rstart( {4'b0000, sdc_rd} ),
    .wstart( {4'b0000, sdc_wr} ), 
    .rsector( sdc_lba ),
    .inbyte( sdc_data_write ),

    .rbusy(sdc_busy),
    .rdone(sdc_done),
                   
    // sector data output interface (sync with clk)
    .outen(sdc_data_read_en), // a byte of sector content is read out from outbyte
    .outaddr(sdc_addr),       // outaddr from 0 to 511, because the sector size is 512
    .outbyte(sdc_data_read)   // a byte of sector content
);

// mac plus bw video
wire hs_n, vs_n;
wire pix;

wire [5:0]	video_red;
wire [5:0] video_green;
wire [5:0] video_blue;   

osd_u8g2  #(.H_OFFSET(86)) osd_u8g2 (
        .clk(clk_pixel),
        .reset(!pll_lock),

        .data_in_strobe(mcu_osd_strobe),
        .data_in_start(mcu_start),
        .data_in(mcu_data_out),

        .hs(hs_n),
        .vs(vs_n),

        .r_in({6{pix}}),
        .g_in({6{pix}}),
        .b_in({6{pix}}),

        .r_out(video_red),
        .g_out(video_green),
        .b_out(video_blue)
);   

/* -------------------- Tang Nano 20k SDRAM -------------------- */
wire [15:0] sdram_dout;
wire [15:0] sdram_din;   
wire		sdram_oe;   
wire		sdram_we;
wire [1:0]  sdram_ds;
wire [20:0] ram_addr;

// `define INT_RAM

`ifdef INT_RAM
// this implements some small 2k FPGA internal RAM which is mapped to
// the begin of the video memory. If SDRAM is assumed to not work
// properly, then this can help identify the problem. The first RAM
// access MacOS does is to erase the screen memory. This shoiuld have
// a visible effect and should work equally well for the first
// internal 2k and the remaining SDRAM.
reg [15:0] int_ram [1024];   
   
wire [15:0] sdram_dout_x;
wire		int_ram_sel = (ram_addr >= 21'hd380 && ram_addr < 21'hd380+21'd1024);
assign sdram_dout = int_ram_sel?int_ram[ram_addr - 21'hd380]^16'hc3c3:sdram_dout_x;   
   
always @(posedge clk_pixel) begin
   if(int_ram_sel && sdram_we && phase == 5)
	 int_ram[ram_addr - 21'hd380] <= sdram_din;   
end
`endif   

sdram sdram (
             .clk(clk_pixel),        // sdram is accessed at 16MHz
             .reset_n(pll_lock),     // init signal after FPGA config to initialize RAM
			 
             .sd_clk(O_sdram_clk),   // sd clock
             .sd_cke(O_sdram_cke),   // clock enable
             .sd_data(IO_sdram_dq),  // 32 bit bidirectional data bus
             .sd_addr(O_sdram_addr), // 11 bit multiplexed address bus
             .sd_dqm(O_sdram_dqm),   // two byte masks
             .sd_ba(O_sdram_ba),     // two banks
             .sd_cs(O_sdram_cs_n),   // a single chip select
             .sd_we(O_sdram_wen_n),  // write enable
             .sd_ras(O_sdram_ras_n), // row address select
             .sd_cas(O_sdram_cas_n), // columns address select

             // cpu/chipset interface
             .ready(ram_ready), // ram is ready and has been initialized
             .phase(phase), // ram is ready and has been initialized
             .din(sdram_din), // data input from chipset/cpu
`ifdef FLASH_TEST
			 // for flash testing the flash is being used as ram replacement and
			 // the sdram is actually disconnected
             .dout(),
`else
`ifdef INT_RAM
             .dout(sdram_dout_x),
`else
             .dout(sdram_dout),
`endif
`endif // !`ifdef FLASH_TEST
			 // scramble ram with memory mapping to force ram test on change
             .addr({1'b0, ram_addr[20:2], ram_addr[1:0] ^ osd_memory}), // 22 bit word address
             .ds(~sdram_ds),          // upper/lower data strobe, active low
             .oe(sdram_oe),           // cpu/chipset requests read/wrie
             .we(sdram_we)            // cpu/chipset requests write
);
   
/* -------------------- Tang Nano spi flash -------------------- */
wire [17:0] rom_addr;
wire rom_oe_n;
wire [15:0]	rom_data;   

// `define INT_ROM

`ifdef INT_ROM
// some small 2k FPGA internal ROM   
// xxd -c2 -p plusrom.bin > plusrom.hex

wire [15:0]	rom_data_X;   

reg [15:0] int_rom [8192];
initial $readmemh("plusrom.hex", int_rom);  

reg [15:0] rom_data_I;
wire int_rom_sel = rom_addr[17:13] == 5'b00000;   

assign rom_data = int_rom_sel?rom_data_I:rom_data_X;   
   
always @(posedge clk_pixel)
   if(phase == 5 && !rom_oe_n)
	 rom_data_I <= int_rom[rom_addr];
`endif
   
assign mspi_clk = ~clk_pixel_x5;   

// If FLASH_TEST is defined, then the flash rom is connected to the
// ram interface instead of the sdram. Then an image can be loaded into
// flash rom which will become visible on screen. The image is
// converted and flashed like so:
   
// convert mac_test.png -negate -depth 1 GRAY:mac_test.raw
// openFPGALoader --external-flash -o 0x480000 mac_test.raw

flash flash ( 
			  .clk(clk_pixel_x5),  // 80 MHz
			  .resetn(pll_lock),
			  .ready(flash_ready), 
			  
			  // chipset read interface
`ifdef FLASH_TEST
			  // flash/video test using flash as ram. This should display the image
			  // stored in flash at offset $480000 on the max screen
			  .address({4'b1001, ram_addr[17:0] - 18'hd380 }), // 16 bit word address
			  .cs(sdram_oe && phase == 2), 
			  .dout(sdram_dout),
`else
			  // regular operation with flash at address $480000 being used as rom
			  .address({4'b1001, rom_addr }), // 16 bit word address
			  .cs(/*!rom_oe_n && */ phase == 1), 
`ifdef INT_ROM
			  .dout( rom_data_X ),
`else
			  .dout( rom_data ),
`endif
`endif
			  
			  // interface to the chip
			  .mspi_cs(mspi_cs),
			  .mspi_di(mspi_di), // data in into flash chip
			  .mspi_hold(mspi_hold),
			  .mspi_wp(mspi_wp),
			  .mspi_do(mspi_do), // data out from flash chip
			  .busy()
			  );   
   
/* -------------------- the MacPlus itself -------------------- */
wire [11:0] audio;  
   
macplus macplus (
    //Master input clock
    .CLKIN(clk_pixel),

    //Async reset from top-level module.
    //Can be used as initial reset.
    .RESET(cpu_reset),

    .pixelOut(pix),
    .hsync(hs_n),
    .vsync(vs_n),

    .audio(audio),

    .configROMSize(1'b1),       // 64k or 128K ROM
	.configRAMSize(osd_memory), // 128k, 512k, 1MB or 4MB
	.configMachineType(1'b0),   // Plus, SE
    .configFloppyWProt(osd_floppy_wprot), // floppy disk write protections
    .configSCSIWProt(osd_hdd_wprot), // hdd/scsi disk write protection
 
    // interface to sd card
    .sdc_image_size ( sdc_image_size ),
    .sdc_image_mounted ( sdc_image_mounted[3:0] ),
    .sdc_lba     ( sdc_lba          ),
    .sdc_rd      ( sdc_rd           ),
    .sdc_wr      ( sdc_wr           ),
    .sdc_busy    ( sdc_busy         ),
    .sdc_done    ( sdc_done         ),
    .sdc_data_in ( sdc_data_read    ),
    .sdc_data_out( sdc_data_write   ),
    .sdc_data_en ( sdc_data_read_en ),
    .sdc_addr    ( sdc_addr         ),
 
    .leds( { leds[5], leds[3:0] } ),

	.MOUSE(mouse), // 1 button, 4 encoder
    .kbd_strobe(kbd_strobe),
    .kbd_data(kbd_data),
				 
    //ADC
    .ADC_BUS(),

    ._romOE(rom_oe_n),
    .romAddr(rom_addr),
    .romData(rom_data),
                 
    // interface to (sd)ram
    .busPhase(phase),
    .ram_addr(ram_addr),
    .sdram_din(sdram_din),  // data to sdram
    .sdram_ds(sdram_ds),
    .sdram_we(sdram_we),
    .sdram_oe(sdram_oe),
    .sdram_do(sdram_dout),

    .UART_CTS( 1'b1 ),
	.UART_RTS(),
    .UART_RXD( uart_rxd ),
    .UART_TXD( uart_txd )
);

wire [5:0] leds;
assign leds[4] = !midi_out;
assign leds_n = ~leds;   
					
/* -------------------- HDMI video and audio -------------------- */

// latch audio, so it's stable during 48khz transfer
reg [15:0] audio_reg [2];  

// expand from 12 to 16 bits and reduce volume a little bit
wire [15:0] audio16 = { {3{audio[11]}}, audio, 1'b0 };   

`define AUDIO_RATE 22159
   
// generate audio clock
reg clk_audio;
reg [8:0] aclk_cnt;
always @(posedge clk_pixel) begin
    if(aclk_cnt < `PIXEL_CLOCK / `AUDIO_RATE / 2 -1)
      aclk_cnt <= aclk_cnt + 9'd1;
    else begin
       aclk_cnt <= 9'd0;
       clk_audio <= ~clk_audio;
	   audio_reg <= { audio16, audio16 };	   
    end
end
   
wire [2:0] tmds;
wire tmds_clock;

`ifdef TEST_HDMI_VIDEO
// generate some dummy video pattern for HDMI testing
reg [9:0] xcnt;
reg [8:0] ycnt;

reg [7:0] ccnt;

wire de = xcnt <= 511 && ycnt <= 341;
wire border = xcnt == 0 || xcnt == 511 || ycnt == 0 || ycnt == 341;
always @(posedge clk_pixel) begin
   if(xcnt == 10'd703) begin
        xcnt <= 10'd0;
        if(ycnt == 9'd369) begin
            ycnt <= 9'd0;
            ccnt <= ccnt + 8'd1;
        end else
            ycnt <= ycnt + 9'd1;
    end else
        xcnt <= xcnt + 10'd1;

    if(cpu_reset) begin
        xcnt <= 10'd0;
        ycnt <= 9'd0;
    end
end

wire vreset;
video_analyzer video_analyzer (
    .clk(clk_pixel),
    .hs(xcnt == 600),
    .vs(ycnt == 360),
    .wide(1'b0),
    .vreset(vreset)
);

wire [5:0] video_red   = de?(ccnt[7]?6'h3f:6'h00):6'h00;
wire [5:0] video_green = de?(border?6'h3f:6'h00):6'h00;
wire [5:0] video_blue  = de?(ccnt[7]?6'h00:6'h3f):6'h00;  
`else // !`ifdef TEST_VIDEO
wire vreset;
video_analyzer video_analyzer (
    .clk(clk_pixel),
    .hs(hs_n),
    .vs(vs_n),
    .wide(osd_widescreen),
    .vreset(vreset)
);
`endif
   
hdmi #(
    .AUDIO_RATE(`AUDIO_RATE), .AUDIO_BIT_WIDTH(16),
    .VENDOR_NAME( { "MiST", 32'd0} ),
    .PRODUCT_DESCRIPTION( {"NanoMac", 72'd0} )
) hdmi(
  .clk_pixel_x5(clk_pixel_x5),
  .clk_pixel(clk_pixel),
  .clk_audio(clk_audio),
  .audio_sample_word( audio_reg ),
  .tmds(tmds),
  .tmds_clock(tmds_clock),

  .wide(osd_widescreen),
  .reset(vreset),    // signal to synchronize HDMI

  .rgb( { video_red, 2'b00, video_green, 2'b00, video_blue, 2'b00 } )
);

// differential output
ELVDS_OBUF tmds_bufds [3:0] (
        .I({tmds_clock, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
);
   
endmodule

// To match emacs with gw_ide default
// Local Variables:
// tab-width: 4
// End:

