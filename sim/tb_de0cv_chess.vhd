library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.chess_pkg.all;
use std.env.all;

entity tb_de0cv_chess is
  generic(SPI_HALF_NS : positive := 100);
end;
architecture test of tb_de0cv_chess is
  constant HALF : time := SPI_HALF_NS*1 ns;
  signal clk : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal sclk,mosi : std_logic := '0';
  signal cs_n : std_logic := '1';
  signal miso : std_logic;
  signal irq_n : std_logic := 'H';
  signal leds : std_logic_vector(9 downto 0);
  signal hex0,hex1,hex2,hex3,hex4,hex5 : std_logic_vector(6 downto 0);
  function crc_byte(c : unsigned(15 downto 0); b : byte_t) return unsigned is
    variable v : unsigned(15 downto 0) := c xor shift_left(resize(unsigned(b),16),8);
  begin
    for i in 0 to 7 loop
      if v(15)='1' then v:=shift_left(v,1) xor x"1021";else v:=shift_left(v,1);end if;
    end loop;return v;
  end;
begin
  clk<=not clk after 10 ns;
  dut : entity work.de0cv_chess port map(CLOCK_50=>clk,RESET_N=>reset_n,KEY=>"11",
    SPI_SCLK=>sclk,SPI_CS_N=>cs_n,SPI_MOSI=>mosi,SPI_MISO=>miso,IRQ_N=>irq_n,
    LEDR=>leds,HEX0=>hex0,HEX1=>hex1,HEX2=>hex2,HEX3=>hex3,HEX4=>hex4,HEX5=>hex5);
  process
    variable packet : bytes_t(0 to 80) := (others=>x"00");
    variable data : bytes_t(0 to 1023);
    variable meta : bytes_t(0 to 6);
    variable token,length_reply,status,gen,best,n : natural := 1;
    variable c : unsigned(15 downto 0);
    variable b : byte_t;
    type seen_t is array(0 to 4095) of boolean;
    variable expected : seen_t := (others=>false);
    variable board : board_t := initial_board;
    procedure transfer(constant tx : byte_t;variable rx : out byte_t) is
    begin
      for i in 7 downto 0 loop
        mosi<=tx(i);wait for HALF;sclk<='1';wait for 1 ns;
        rx(i):=miso;wait for HALF-1 ns;sclk<='0';
      end loop;
    end;
    procedure begin_frame is
    begin sclk<='0';cs_n<='0';wait for 2*HALF;end;
    procedure end_frame is
    begin sclk<='0';wait for HALF;cs_n<='1';wait for 2*HALF;end;
    procedure write_regs(constant addr : natural;constant values : bytes_t) is
      variable ignored : byte_t;
    begin
      begin_frame;transfer(x"00",ignored);transfer(oct(addr),ignored);
      for i in values'range loop transfer(values(i),ignored);end loop;
      end_frame;
    end;
    procedure read_regs(constant addr : natural;variable values : out bytes_t) is
      variable ignored : byte_t;
    begin
      begin_frame;transfer(x"80",ignored);transfer(oct(addr),ignored);
      for i in values'range loop transfer(x"00",values(i));end loop;
      end_frame;
    end;
    procedure submit(constant count : positive;constant bad_crc : boolean := false;constant missing : boolean := false) is
      variable header : bytes_t(0 to 6);
      variable c : unsigned(15 downto 0) := x"FFFF";
    begin
      for i in 0 to 3 loop header(i):=oct(token/(256**(3-i)));end loop;
      header(4):=oct(count);c:=crc_byte(c,x"01");
      for i in 0 to 4 loop c:=crc_byte(c,header(i));end loop;
      for i in 0 to count-1 loop c:=crc_byte(c,packet(i));end loop;
      if bad_crc then c:=c xor x"0001";end if;
      header(5):=std_logic_vector(c(15 downto 8));header(6):=std_logic_vector(c(7 downto 0));
      write_regs(16#10#,header);
      if missing then
        if count>1 then write_regs(16#20#,packet(0 to count-2));end if;
      else write_regs(16#20#,packet(0 to count-1));end if;
      write_regs(16#0F#,(0=>x"A5"));
    end;
    procedure receive(constant expected_status : natural := 0) is
      variable flag : bytes_t(0 to 0);
      variable checksum : bytes_t(0 to 1);
      variable c : unsigned(15 downto 0) := x"FFFF";
    begin
      for poll in 0 to 1000 loop
        read_regs(3,flag);exit when flag(0)(1 downto 0)="10";
      end loop;
      assert flag(0)(1 downto 0)="10" report "SPI mailbox did not complete" severity failure;
      assert irq_n='0' report "reply IRQ not asserted" severity failure;
      read_regs(8,meta);status:=to_integer(unsigned(meta(4)));
      assert status=expected_status report "unexpected mailbox status: "&integer'image(status) severity failure;
      for i in 0 to 3 loop assert meta(i)=oct(token/(256**(3-i))) report "reply sequence mismatch" severity failure;end loop;
      length_reply:=to_integer(unsigned(meta(5)))*256+to_integer(unsigned(meta(6)));
      assert length_reply<=1024 report "oversized reply" severity failure;
      c:=crc_byte(c,x"01");for i in meta'range loop c:=crc_byte(c,meta(i));end loop;
      if length_reply>0 then
        for page in 0 to (length_reply+127)/128-1 loop
          write_regs(16#18#,(0=>oct(page)));
          n:=length_reply-page*128;if n>128 then n:=128;end if;
          read_regs(16#80#,data(page*128 to page*128+n-1));
        end loop;
        for i in 0 to length_reply-1 loop c:=crc_byte(c,data(i));end loop;
      end if;
      read_regs(16#1A#,checksum);
      assert checksum(0)=std_logic_vector(c(15 downto 8)) and checksum(1)=std_logic_vector(c(7 downto 0)) report "SPI reply CRC/read pipeline mismatch" severity failure;
      write_regs(16#0F#,(0=>x"5A"));
      assert irq_n/='0' report "acknowledgement did not release IRQ" severity failure;
    end;
    procedure command(constant count : positive;constant expected_status : natural := 0) is
    begin token:=token+1;submit(count);receive(expected_status);end;
    procedure get_status is
    begin packet(0):=x"00";command(1);assert length_reply=40 report "bad status length" severity failure;end;
  begin
    wait for 200 ns;reset_n<='1';wait for 20 us;
    assert miso='Z' report "deselected MISO was not released" severity failure;
    read_regs(0,data(0 to 7));
    assert data(0)=x"C5" and data(1)=x"03" and data(4)=x"43" and data(7)=x"33" report "wrong SPI identity" severity failure;
    get_status;
    assert data(0)=x"53" and data(1)=x"43" and data(2)=x"46" and data(3)=x"32" and data(15)=x"05" report "corrupt engine status" severity failure;
    assert data(36)=x"02" and data(37)=x"FA" and data(38)=x"F0" and data(39)=x"80"
      report "wrong reported engine clock" severity failure;
    packet(0):=x"12";command(1);
    assert length_reply=128 and data(24)=x"08" and data(26)=x"04" and data(27)=x"04" and data(126)=x"04"
      report "advanced engine capabilities were lost in SPI port" severity failure;
    assert data(20)=x"02" and data(21)=x"FA" and data(22)=x"F0" and data(23)=x"80"
      report "wrong telemetry clock" severity failure;
    packet(0):=x"0A";command(1);submit(1);receive;
    get_status;assert data(23)=x"01" report "retried mutation executed twice" severity failure;
    packet(0):=x"0A";token:=token+1;submit(1,true);receive(5);
    get_status;assert data(23)=x"01" report "bad CRC changed the board" severity failure;
    packet(0):=x"09";packet(1):=x"01";packet(2):=x"02";packet(3):=x"03";packet(4):=x"04";
    token:=token+1;submit(5,false,true);receive(5);

    -- A partial execute frame contains a complete A5 byte followed by an
    -- aborted data byte. Its write strobe must not trigger an engine command.
    packet(0):=x"0A";token:=token+1;
    c:=crc_byte(x"FFFF",x"01");
    for i in 0 to 3 loop c:=crc_byte(c,oct(token/(256**(3-i))));end loop;
    c:=crc_byte(c,x"01");c:=crc_byte(c,x"0A");
    write_regs(16#10#,(x"00",x"00",x"00",oct(token),x"01",std_logic_vector(c(15 downto 8)),std_logic_vector(c(7 downto 0))));
    write_regs(16#20#,(0=>x"0A"));
    begin_frame;transfer(x"00",b);transfer(x"0F",b);transfer(x"A5",b);
    mosi<='1';wait for HALF;sclk<='1';wait for HALF;sclk<='0';end_frame;
    get_status;assert data(23)=x"01" report "partial SPI frame executed" severity failure;

    packet(0):=x"08";for i in 1 to 80 loop packet(i):=oct(i);end loop;
    packet(1):=x"00";packet(5):=x"00";command(81);
    packet(0):=x"06";command(1);assert length_reply=80 report "wrong config length" severity failure;
    for i in 0 to 79 loop
      if i=0 or i=4 then n:=0;else n:=i+1;end if;
      assert data(i)=oct(n) report "config RAM readback mismatch" severity failure;
    end loop;
    packet(0):=x"0D";packet(1):=x"00";
    for i in 0 to 63 loop packet(i+2):=policy_defaults(i);end loop;
    packet(12):=x"08";packet(42):=x"0A";command(66);
    packet(0):=x"0C";packet(1):=x"00";command(2);
    assert length_reply=64 and data(10)=x"08" and data(40)=x"0A"
      report "eight-ply depth or think budget did not survive SPI policy upload" severity failure;
    packet(0):=x"0D";packet(1):=x"00";
    for i in 0 to 63 loop packet(i+2):=policy_defaults(i);end loop;
    packet(12):=x"00";command(66);
    packet(0):=x"02";command(1);
    for poll in 0 to 1000 loop get_status;exit when data(4)=x"00" and data(5)=x"01";end loop;
    assert data(5)=x"01" report "SPI-started evaluation did not finish" severity failure;
    assert data(8)=x"00" and data(9)=x"14" report "wrong opening legal count" severity failure;
    best:=to_integer(unsigned(data(10)))*256+to_integer(unsigned(data(11)));gen:=to_integer(unsigned(data(23)));
    expected(1+16*64):=true;expected(1+18*64):=true;expected(6+21*64):=true;expected(6+23*64):=true;
    for s in 8 to 15 loop expected(s+(s+8)*64):=true;expected(s+(s+16)*64):=true;end loop;
    assert expected(best) report "hardware selection was illegal" severity failure;
    for page in 0 to 1 loop
      packet(0):=x"07";packet(1):=oct(page);command(2);
      for i in 0 to 15 loop
        if page*16+i<20 then
          n:=to_integer(unsigned(data(i*4)))*256+to_integer(unsigned(data(i*4+1)));
          assert n<4096 and expected(n) report "illegal/duplicate move over SPI" severity failure;expected(n):=false;
        end if;
      end loop;
    end loop;
    packet(0):=x"13";packet(1):=x"00";command(2);
    assert length_reply=16 report "candidate metadata command missing" severity failure;
    packet(0):=x"0B";packet(1):=x"00";packet(2):=x"00";packet(3):=x"00";packet(4):=oct(gen);
    packet(5):=oct(best/256);packet(6):=oct(best);command(7);
    packet(0):=x"05";command(1);
    board(best/64 mod 64):=board(best mod 64);board(best mod 64):=x"0";
    for s in 0 to 63 loop assert data(s)=x"0"&board(s) report "committed SPI board mismatch" severity failure;end loop;
    assert data(64)=x"01" and data(65)=x"0F" report "commit metadata mismatch" severity failure;
    packet(0):=x"0B";command(7,3);
    assert miso='Z' report "MISO not tri-stated after command" severity failure;
    report "PASS: DE0-CV SPI pins, protocol-5 status/telemetry, eight-ply policy, CRC, retry, partial frame, legal set, guarded commit, IRQ and MISO" severity note;
    finish;
  end process;
end;
