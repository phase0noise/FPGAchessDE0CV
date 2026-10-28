library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package chess_pkg is
  subtype piece_t is std_logic_vector(3 downto 0);
  subtype byte_t is std_logic_vector(7 downto 0);
  type board_t is array(0 to 63) of piece_t;
  type bytes_t is array(natural range <>) of byte_t;
  type field_t is array(0 to 63) of integer range -127 to 127;
  type seeds_t is array(0 to 63) of unsigned(15 downto 0);
  constant MAX_SEARCH_DEPTH : positive := 8;
  constant MAX_QUIESCENCE : positive := 4;
  constant SEARCH_LEVELS : positive := MAX_SEARCH_DEPTH+MAX_QUIESCENCE+2;
  constant SEARCH_MOVES : positive := 512;
  constant CACHE_INDEX_BITS : positive := 12;
  constant CACHE_ENTRIES : positive := 2**CACHE_INDEX_BITS;
  subtype hash_t is unsigned(63 downto 0);
  type pieces4_t is array(0 to 3) of piece_t;
  type hashes4_t is array(0 to 3) of hash_t;
  type words4_t is array(0 to 3) of std_logic_vector(31 downto 0);
  subtype third_product_t is unsigned(40 downto 0);
  function third_product(n : unsigned(20 downto 0)) return third_product_t;
  function popcount64(bits : std_logic_vector(63 downto 0)) return natural;
  function position_salt(turn : std_logic; rights : std_logic_vector(3 downto 0); ep : natural) return hash_t;
  type offsets_t is array(0 to 7) of integer;
  constant DX : offsets_t := (1,-1,0,0,1,-1,1,-1);
  constant DY : offsets_t := (0,0,1,-1,1,1,-1,-1);
  function kind(p : piece_t) return natural;
  function value(p : piece_t) return integer;
  function oct(n : integer) return byte_t;
  function sat(n : integer) return integer;
  function clip16(n : integer) return integer;
  function centrality(s : natural) return integer;
  function square_wisdom(p : piece_t; s : natural; ending : boolean) return integer;
  function updated_rights(r : std_logic_vector(3 downto 0); src,dst : natural) return std_logic_vector;
  function move_position_delta(p,c : piece_t; src,dst,prom : natural;
    ep_capture,castle : std_logic; ending : boolean; material_weight,position_weight : natural) return integer;
  function policy_defaults return bytes_t;
  function initial_board return board_t;
end package;

package body chess_pkg is
  function third_product(n : unsigned(20 downto 0)) return third_product_t is
  begin
    -- ceil(2**21 / 3). For every 21-bit n, product(40 downto 21)
    -- equals n/3 exactly: reciprocal error is strictly below 1/3.
    return n*to_unsigned(699051,20);
  end;
  function popcount64(bits : std_logic_vector(63 downto 0)) return natural is
    type counts_t is array(0 to 7) of natural range 0 to 64;
    variable a : counts_t := (others=>0);
  begin
    for g in 0 to 7 loop
      for j in 0 to 7 loop
        if bits(g*8+j)='1' then a(g):=a(g)+1; end if;
      end loop;
    end loop;
    return ((a(0)+a(1))+(a(2)+a(3)))+((a(4)+a(5))+(a(6)+a(7)));
  end;
  function position_salt(turn : std_logic; rights : std_logic_vector(3 downto 0); ep : natural) return hash_t is
    type salts_t is array(0 to 11) of hash_t;
    constant salts : salts_t := (x"9E3779B97F4A7C15",x"BF58476D1CE4E5B9",x"94D049BB133111EB",
      x"D6E8FEB86659FD93",x"A0761D6478BD642F",x"E7037ED1A0B428DB",x"8EBC6AF09C88C6E3",
      x"589965CC75374CC3",x"1D8E4E27C47D124F",x"EB44ACCAB455D165",x"C6BC279692B5CC83",x"DB4F0B9175AE2165");
    variable result : hash_t := x"243F6A8885A308D3";
    variable ep_bits : unsigned(6 downto 0);
  begin
    if turn='1' then result:=result xor salts(0); end if;
    for i in 0 to 3 loop if rights(i)='1' then result:=result xor salts(i+1); end if; end loop;
    ep_bits:=to_unsigned(ep,7);
    for i in 0 to 6 loop if ep_bits(i)='1' then result:=result xor salts(i+5); end if; end loop;
    return result;
  end;
  function clip16(n : integer) return integer is
  begin
    if n>32767 then return 32767; elsif n< -32768 then return -32768; else return n; end if;
  end;
  function centrality(s : natural) return integer is
    variable x,y : integer;
  begin
    x:=s mod 8; y:=s/8;
    if x>3 then x:=7-x; end if;
    if y>3 then y:=7-y; end if;
    return x+y;
  end;
  function square_wisdom(p : piece_t; s : natural; ending : boolean) return integer is
    variable rank,col,c : integer;
  begin
    rank:=s/8; col:=s mod 8; c:=centrality(s);
    if p(3)='1' then rank:=7-rank; end if;
    case kind(p) is
      when 1 => return rank*8+c*2+rank*rank*2;
      when 2 | 3 =>
        if rank=0 then return c*8-28; else return c*8+12; end if;
      when 4 =>
        if rank=6 then return 40+c*2; else return c*2; end if;
      when 5 => return c*2;
      when 6 =>
        if ending then return c*12;
        elsif rank=0 and (col=1 or col=2 or col=6 or col=7) then return 55;
        else return -rank*20-c*3; end if;
      when others => return 0;
    end case;
  end;
  function updated_rights(r : std_logic_vector(3 downto 0); src,dst : natural) return std_logic_vector is
    variable result : std_logic_vector(3 downto 0) := r;
  begin
    if src=4 then result(1 downto 0):="00"; end if;
    if src=60 then result(3 downto 2):="00"; end if;
    if src=0 or dst=0 then result(1):='0'; end if;
    if src=7 or dst=7 then result(0):='0'; end if;
    if src=56 or dst=56 then result(3):='0'; end if;
    if src=63 or dst=63 then result(2):='0'; end if;
    return result;
  end;
  function move_position_delta(p,c : piece_t; src,dst,prom : natural;
    ep_capture,castle : std_logic; ending : boolean; material_weight,position_weight : natural) return integer is
    variable moved,rook : piece_t;
    variable material,position,capture_square,rook_src,rook_dst : integer;
  begin
    moved:=p; material:=value(c); capture_square:=dst;
    if prom/=0 then moved:=p(3)&std_logic_vector(to_unsigned(prom,3)); material:=material+value(moved)-100; end if;
    if ep_capture='1' then
      if p(3)='0' then capture_square:=dst-8; else capture_square:=dst+8; end if;
    end if;
    position:=square_wisdom(moved,dst,ending)-square_wisdom(p,src,ending)+square_wisdom(c,capture_square,ending);
    if castle='1' then
      rook:=p(3)&"100";
      if dst mod 8=6 then rook_src:=dst+1; rook_dst:=dst-1;
      else rook_src:=dst-2; rook_dst:=dst+1; end if;
      position:=position+square_wisdom(rook,rook_dst,ending)-square_wisdom(rook,rook_src,ending);
    end if;
    return material*material_weight/16+position*position_weight/16;
  end;
  function policy_defaults return bytes_t is
    variable p : bytes_t(0 to 127) := (others=>x"00");
  begin
    p(0):=x"20"; p(1):=x"04"; p(2):=x"08";
    p(3):=x"A0"; p(4):=x"50"; p(5):=x"18";
    p(6):=x"50"; p(7):=x"20"; p(8):=x"02"; p(9):=x"10";
    p(10):=x"05"; p(12):=x"10"; p(13):=x"08"; p(15):=x"01";
    p(40):=x"0A"; p(41):=x"04"; p(42):=x"01";
    p(43):=x"10"; p(44):=x"08";
    p(14):=x"02";
    for d in 16 to 23 loop p(d):=x"08"; end loop;
    for i in 0 to 15 loop p(24+i):=std_logic_vector(to_signed(i*16-120,8)); end loop;
    return p;
  end;
  function kind(p : piece_t) return natural is
  begin return to_integer(unsigned(p(2 downto 0))); end;
  function value(p : piece_t) return integer is
  begin
    case kind(p) is
      when 1 => return 100; when 2 => return 320; when 3 => return 335;
      when 4 => return 500; when 5 => return 900; when 6 => return 2000;
      when others => return 0;
    end case;
  end;
  function oct(n : integer) return byte_t is
  begin return std_logic_vector(to_unsigned(n mod 256,8)); end;
  function sat(n : integer) return integer is
  begin
    if n > 127 then return 127; elsif n < -127 then return -127; else return n; end if;
  end;
  function initial_board return board_t is
    variable b : board_t := (others => x"0");
    type back_t is array(0 to 7) of natural;
    constant back : back_t := (4,2,3,5,6,3,2,4);
  begin
    for i in 0 to 7 loop
      b(i) := std_logic_vector(to_unsigned(back(i),4)); b(i+8) := x"1";
      b(i+48) := x"9"; b(i+56) := std_logic_vector(to_unsigned(back(i)+8,4));
    end loop;
    return b;
  end;
end package body;
