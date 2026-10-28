-- SPI register mailbox for the protocol-5 chess command API. The mode-0 target
-- is copied from spirpi; complete commands are CRC checked before dispatch.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.chess_pkg.all;

entity chess_spi_bridge is
  generic(CLOCK_HZ : positive := 50000000; CHESS_DIVIDE : positive := 4);
  port(clk,reset : in std_logic;
    reg_address,reg_write_address : in byte_t;
    reg_write_data : in byte_t; reg_write,frame_done,frame_error : in std_logic;
    reg_read_data : out byte_t; reply_ready : out std_logic;
    keys : in std_logic_vector(3 downto 0);
    panel : out std_logic_vector(31 downto 0);
    activity : out std_logic_vector(17 downto 0));
end;

architecture rtl of chess_spi_bridge is
  type state_t is (IDLE,VERIFY_REQUEST,CHECK_CRC,COPY_REQUEST,ISSUE,EXECUTE,
    REPLY_HEADER,SNAP_ADDRESS,SNAP_WAIT1,SNAP_WAIT2,SNAP_STORE,COMPLETE);
  signal state : state_t := IDLE;
  signal request : bytes_t(0 to 80);
  signal seen : std_logic_vector(80 downto 0) := (others=>'0');
  signal staged_seq,active_seq,reply_seq : std_logic_vector(31 downto 0) := (others=>'0');
  signal staged_length : natural range 0 to 255 := 0;
  signal active_length : natural range 0 to 81 := 0;
  signal staged_crc,request_crc,cached_crc : unsigned(15 downto 0) := (others=>'0');
  signal cached_length : natural range 0 to 81 := 0;
  signal cache_valid,ready : std_logic := '0';
  signal control_pending : std_logic := '0';
  signal control : byte_t := x"00";
  signal reply_status : natural range 0 to 6 := 0;
  signal reply_length : natural range 0 to 1024 := 0;
  signal reply_crc,crc : unsigned(15 downto 0) := (others=>'1');
  signal reply_page : natural range 0 to 7 := 0;
  signal reply_address : natural range 0 to 1023 := 0;
  signal reply_q : byte_t;
  signal reply : bytes_t(0 to 1023);
  attribute ramstyle : string;
  attribute ramstyle of reply : signal is "M10K, no_rw_check";
  signal index_i : natural range 0 to 1023 := 0;
  signal header_index : natural range 0 to 7 := 0;
  signal watchdog : natural range 0 to CLOCK_HZ/10 := 0;
  signal engine_we,engine_command,engine_done : std_logic := '0';
  signal engine_rx_address : natural range 0 to 80 := 0;
  signal engine_rx_data,engine_read_data : byte_t := x"00";
  signal engine_read_address : natural range 0 to 1023 := 0;
  signal engine_status : natural range 0 to 3;
  signal engine_length : natural range 0 to 1024;
  function crc_byte(c : unsigned(15 downto 0); b : byte_t) return unsigned is
    variable v : unsigned(15 downto 0) := c xor shift_left(resize(unsigned(b),16),8);
  begin
    for n in 0 to 7 loop
      if v(15)='1' then v:=shift_left(v,1) xor x"1021";else v:=shift_left(v,1);end if;
    end loop;return v;
  end;
begin
  engine : entity work.chess_engine generic map(CLOCK_DIVIDE=>CHESS_DIVIDE,CLOCK_HZ=>CLOCK_HZ,PAWN_LANES=>1)
    port map(clk=>clk,reset=>reset,rx_we=>engine_we,rx_address=>engine_rx_address,
      rx_data=>engine_rx_data,command=>engine_command,request_length=>active_length,
      request_token=>x"444530535049" & active_seq,
      response_done=>engine_done,response_status=>engine_status,response_length=>engine_length,
      read_address=>engine_read_address,read_data=>engine_read_data,
      switches=>(others=>'0'),keys=>keys,panel=>panel,activity=>activity);
  reply_ready<=ready;
  reply_address<=reply_page*128+to_integer(unsigned(reg_address(6 downto 0)));
  process(clk) begin
    if rising_edge(clk) then
      reply_q<=reply(reply_address);
      if state=SNAP_STORE then reply(index_i)<=engine_read_data;end if;
    end if;
  end process;
  process(all)
    variable address : natural;
  begin
    address:=to_integer(unsigned(reg_address));reg_read_data<=x"00";
    case address is
      when 16#00#=>reg_read_data<=x"C5";
      when 16#01#=>reg_read_data<=x"03";
      when 16#02#=>reg_read_data<=x"07";
      when 16#03#=>
        if state/=IDLE then reg_read_data(0)<='1';end if;
        reg_read_data(1)<=ready;
        if reply_status/=0 then reg_read_data(2)<='1';end if;
      when 16#04#=>reg_read_data<=x"43";
      when 16#05#=>reg_read_data<=x"48";
      when 16#06#=>reg_read_data<=x"53";
      when 16#07#=>reg_read_data<=x"33";
      when 16#08# to 16#0B#=>reg_read_data<=reply_seq(31-(address-8)*8 downto 24-(address-8)*8);
      when 16#0C#=>reg_read_data<=oct(reply_status);
      when 16#0D#=>reg_read_data<=oct(reply_length/256);
      when 16#0E#=>reg_read_data<=oct(reply_length);
      when 16#10# to 16#13#=>reg_read_data<=staged_seq(31-(address-16)*8 downto 24-(address-16)*8);
      when 16#14#=>reg_read_data<=oct(staged_length);
      when 16#15#=>reg_read_data<=std_logic_vector(staged_crc(15 downto 8));
      when 16#16#=>reg_read_data<=std_logic_vector(staged_crc(7 downto 0));
      when 16#18#=>reg_read_data<=oct(reply_page);
      when 16#1A#=>reg_read_data<=std_logic_vector(reply_crc(15 downto 8));
      when 16#1B#=>reg_read_data<=std_logic_vector(reply_crc(7 downto 0));
      when 16#20# to 16#70#=>reg_read_data<=request(address-16#20#);
      when 16#80# to 16#FF#=>reg_read_data<=reply_q;
      when others=>null;
    end case;
  end process;

  process(clk)
    variable address : natural;
    variable b : byte_t;
    variable complete_request : boolean;
  begin
    if rising_edge(clk) then
      engine_we<='0';
      if reset='1' then
        state<=IDLE;ready<='0';cache_valid<='0';control_pending<='0';
        engine_command<='0';seen<=(others=>'0');staged_length<=0;
        staged_seq<=(others=>'0');active_seq<=(others=>'0');reply_seq<=(others=>'0');
        reply_length<=0;reply_status<=0;reply_page<=0;watchdog<=0;
      else
        if reg_write='1' then
          address:=to_integer(unsigned(reg_write_address));
          if address=16#18# then reply_page<=to_integer(unsigned(reg_write_data(2 downto 0)));end if;
          if state=IDLE then
            case address is
              when 16#0F#=>control<=reg_write_data;control_pending<='1';
              when 16#10# to 16#13#=>staged_seq(31-(address-16)*8 downto 24-(address-16)*8)<=reg_write_data;
              when 16#14#=>staged_length<=to_integer(unsigned(reg_write_data));seen<=(others=>'0');
              when 16#15#=>staged_crc(15 downto 8)<=unsigned(reg_write_data);
              when 16#16#=>staged_crc(7 downto 0)<=unsigned(reg_write_data);
              when 16#20# to 16#70#=>request(address-16#20#)<=reg_write_data;seen(address-16#20#)<='1';
              when others=>null;
            end case;
          end if;
        end if;
        -- A command strobe is accepted only when its complete SPI frame ends
        -- cleanly. An aborted/partial frame cannot execute a chess command.
        if frame_done='1' then
          control_pending<='0';
          if control_pending='1' and frame_error='0' and state=IDLE then
            if control=x"5A" then ready<='0';
            elsif control=x"A5" then
              ready<='0';active_seq<=staged_seq;index_i<=0;crc<=(others=>'1');
              complete_request:=staged_length>=1 and staged_length<=81;
              for i in 0 to 80 loop
                if i<staged_length and seen(i)='0' then complete_request:=false;end if;
              end loop;
              if not complete_request then
                reply_seq<=staged_seq;reply_status<=5;reply_length<=0;cache_valid<='0';
                header_index<=0;state<=REPLY_HEADER;
              else active_length<=staged_length;state<=VERIFY_REQUEST;end if;
            end if;
          end if;
        end if;
        case state is
          when IDLE=>null;
          when VERIFY_REQUEST=>
            case index_i is
              when 0=>b:=x"01";
              when 1 to 4=>b:=active_seq(31-(index_i-1)*8 downto 24-(index_i-1)*8);
              when 5=>b:=oct(active_length);
              when others=>b:=request(index_i-6);
            end case;
            crc<=crc_byte(crc,b);
            if index_i=active_length+5 then state<=CHECK_CRC;else index_i<=index_i+1;end if;
          when CHECK_CRC=>
            if crc/=staged_crc then
              reply_seq<=active_seq;reply_status<=5;reply_length<=0;cache_valid<='0';
              crc<=(others=>'1');header_index<=0;state<=REPLY_HEADER;
            elsif cache_valid='1' and active_seq=reply_seq then
              if crc=cached_crc and active_length=cached_length then ready<='1';state<=IDLE;
              else
                reply_status<=6;reply_length<=0;cache_valid<='0';
                crc<=(others=>'1');header_index<=0;state<=REPLY_HEADER;
              end if;
            else
              request_crc<=crc;cache_valid<='0';index_i<=0;state<=COPY_REQUEST;
            end if;
          when COPY_REQUEST=>
            engine_we<='1';engine_rx_address<=index_i;engine_rx_data<=request(index_i);
            if index_i=active_length-1 then state<=ISSUE;else index_i<=index_i+1;end if;
          when ISSUE=>engine_command<='1';watchdog<=0;state<=EXECUTE;
          when EXECUTE=>
            if engine_done='1' then
              engine_command<='0';reply_seq<=active_seq;
              reply_status<=engine_status;reply_length<=engine_length;
              crc<=(others=>'1');header_index<=0;cache_valid<='1';
              cached_crc<=request_crc;cached_length<=active_length;state<=REPLY_HEADER;
            elsif watchdog=CLOCK_HZ/10 then
              engine_command<='0';reply_seq<=active_seq;reply_status<=4;reply_length<=0;
              crc<=(others=>'1');header_index<=0;state<=REPLY_HEADER;
            else watchdog<=watchdog+1;end if;
          when REPLY_HEADER=>
            case header_index is
              when 0=>b:=x"01";
              when 1 to 4=>b:=reply_seq(31-(header_index-1)*8 downto 24-(header_index-1)*8);
              when 5=>b:=oct(reply_status);
              when 6=>b:=oct(reply_length/256);
              when others=>b:=oct(reply_length);
            end case;
            crc<=crc_byte(crc,b);
            if header_index=7 then
              index_i<=0;
              if reply_length=0 then state<=COMPLETE;else state<=SNAP_ADDRESS;end if;
            else header_index<=header_index+1;end if;
          when SNAP_ADDRESS=>engine_read_address<=index_i;state<=SNAP_WAIT1;
          when SNAP_WAIT1=>state<=SNAP_WAIT2;
          when SNAP_WAIT2=>state<=SNAP_STORE;
          when SNAP_STORE=>
            crc<=crc_byte(crc,engine_read_data);
            if index_i=reply_length-1 then state<=COMPLETE;else index_i<=index_i+1;state<=SNAP_ADDRESS;end if;
          when COMPLETE=>reply_crc<=crc;ready<='1';state<=IDLE;
        end case;
      end if;
    end if;
  end process;
end;
