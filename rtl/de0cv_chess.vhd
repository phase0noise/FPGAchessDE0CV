library ieee;
use ieee.std_logic_1164.all;

entity de0cv_chess is
  port(CLOCK_50,RESET_N : in std_logic;KEY : in std_logic_vector(1 downto 0);
    SPI_SCLK,SPI_CS_N,SPI_MOSI : in std_logic;SPI_MISO : out std_logic;IRQ_N : inout std_logic;
    LEDR : out std_logic_vector(9 downto 0);
    HEX0,HEX1,HEX2,HEX3,HEX4,HEX5 : out std_logic_vector(6 downto 0));
end;
architecture rtl of de0cv_chess is
  signal reset_pipe : std_logic_vector(3 downto 0) := (others=>'1');
  signal reset,key_meta,key_sync : std_logic := '1';
  signal read_address,write_address,read_data,write_data : std_logic_vector(7 downto 0);
  signal reg_write,frame_done,frame_error,miso,ready : std_logic;
  signal panel : std_logic_vector(31 downto 0);
  signal activity : std_logic_vector(17 downto 0);
  function digit(n : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable v : std_logic_vector(7 downto 0);
  begin
    case n is
      when x"0"=>v:=x"C0";when x"1"=>v:=x"F9";when x"2"=>v:=x"A4";when x"3"=>v:=x"B0";
      when x"4"=>v:=x"99";when x"5"=>v:=x"92";when x"6"=>v:=x"82";when x"7"=>v:=x"F8";
      when x"8"=>v:=x"80";when x"9"=>v:=x"90";when x"A"=>v:=x"88";when x"B"=>v:=x"83";
      when x"C"=>v:=x"C6";when x"D"=>v:=x"A1";when x"E"=>v:=x"86";when others=>v:=x"8E";
    end case;return v(6 downto 0);
  end;
begin
  process(CLOCK_50,RESET_N,KEY(0)) begin
    if RESET_N='0' or KEY(0)='0' then reset_pipe<=(others=>'1');
    elsif rising_edge(CLOCK_50) then reset_pipe<=reset_pipe(2 downto 0)&'0';end if;
  end process;
  reset<=reset_pipe(3);
  process(CLOCK_50) begin
    if rising_edge(CLOCK_50) then key_meta<=KEY(1);key_sync<=key_meta;end if;
  end process;
  SPI_MISO<=miso when SPI_CS_N='0' else 'Z';
  IRQ_N<='0' when ready='1' else 'Z';
  spi : entity work.spi_target port map(clk_i=>CLOCK_50,reset_n_i=>not reset,
    sclk_i=>SPI_SCLK,cs_n_i=>SPI_CS_N,mosi_i=>SPI_MOSI,miso_o=>miso,
    reg_addr_o=>read_address,reg_write_addr_o=>write_address,reg_read_data_i=>read_data,
    reg_write_data_o=>write_data,reg_write_o=>reg_write,reg_read_o=>open,
    busy_o=>open,activity_o=>open,frame_o=>frame_done,frame_error_o=>frame_error);
  link : entity work.chess_spi_bridge generic map(CLOCK_HZ=>50000000) port map(clk=>CLOCK_50,reset=>reset,
    reg_address=>read_address,reg_write_address=>write_address,
    reg_write_data=>write_data,reg_write=>reg_write,frame_done=>frame_done,frame_error=>frame_error,
    reg_read_data=>read_data,reply_ready=>ready,keys=>(1=>not key_sync,others=>'0'),
    panel=>panel,activity=>activity);
  LEDR(7 downto 0)<=activity(7 downto 0);LEDR(8)<=activity(16);LEDR(9)<=activity(17);
  HEX0<=digit(panel(19 downto 16));HEX1<=digit(panel(23 downto 20));
  HEX2<=digit(panel(27 downto 24));HEX3<=digit(panel(31 downto 28));
  HEX4<=digit(panel(11 downto 8));HEX5<=digit(panel(3 downto 0));
end;
