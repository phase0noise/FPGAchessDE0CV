-- Three wired ray planes: white, black, and the selected move source.
-- Empty cells forward rays; occupied cells terminate them. Non-sliders have
-- fixed local links. No sequential ray tracing and no 64x64 move crossbar.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.chess_pkg.all;

entity chess_spatial is
  port(board : in board_t; source : in natural range 0 to 63;
    white_attack, black_attack, reachable : out std_logic_vector(63 downto 0));
end;
architecture wires of chess_spatial is
  type ray_board_t is array(0 to 63,0 to 7) of std_logic;
  type planes_t is array(0 to 2) of ray_board_t;
  type maps_t is array(0 to 2) of std_logic_vector(63 downto 0);
  signal ray : planes_t;
  signal maps : maps_t;
  constant KX : offsets_t := (1,2,2,1,-1,-2,-2,-1);
  constant KY : offsets_t := (2,1,-1,-2,-2,-1,1,2);
begin
  white_attack <= maps(0); black_attack <= maps(1); reachable <= maps(2);
  planes : for c in 0 to 2 generate
    squares : for s in 0 to 63 generate
      signal hits : std_logic_vector(25 downto 0);
    begin
      directions : for d in 0 to 7 generate
        constant x : integer := s mod 8 - DX(d);
        constant y : integer := s / 8 - DY(d);
        signal seed : std_logic;
      begin
        seed <= '1' when ((c=0 and board(s)(3)='0') or
          (c=1 and board(s)(3)='1') or (c=2 and source=s)) and
          (kind(board(s))=5 or (d<4 and kind(board(s))=4) or
           (d>=4 and kind(board(s))=3)) else '0';
        inside : if x>=0 and x<8 and y>=0 and y<8 generate
          ray(c)(s,d) <= seed or (ray(c)(y*8+x,d) and not
            (board(s)(0) or board(s)(1) or board(s)(2)));
        end generate;
        edge : if x<0 or x>=8 or y<0 or y>=8 generate
          ray(c)(s,d) <= seed;
        end generate;
      end generate;
      -- Static local wires avoid waking every square on every ray event in
      -- simulation, and expose the same shared decode logic to synthesis.
      arrivals : for d in 0 to 7 generate
        constant x : integer := s mod 8-DX(d);
        constant y : integer := s/8-DY(d);
      begin
        inside : if x>=0 and x<8 and y>=0 and y<8 generate
          hits(d)<=ray(c)(y*8+x,d);
        end generate;
        edge : if x<0 or x>=8 or y<0 or y>=8 generate hits(d)<='0'; end generate;
      end generate;
      kings : for d in 0 to 7 generate
        constant x : integer := s mod 8+DX(d);
        constant y : integer := s/8+DY(d);
        constant q : integer := y*8+x;
      begin
        inside : if x>=0 and x<8 and y>=0 and y<8 generate
          hits(8+d)<='1' when kind(board(q))=6 and
            ((c=0 and board(q)(3)='0') or (c=1 and board(q)(3)='1') or (c=2 and source=q)) else '0';
        end generate;
        edge : if x<0 or x>=8 or y<0 or y>=8 generate hits(8+d)<='0'; end generate;
      end generate;
      knights : for d in 0 to 7 generate
        constant x : integer := s mod 8+KX(d);
        constant y : integer := s/8+KY(d);
        constant q : integer := y*8+x;
      begin
        inside : if x>=0 and x<8 and y>=0 and y<8 generate
          hits(16+d)<='1' when kind(board(q))=2 and
            ((c=0 and board(q)(3)='0') or (c=1 and board(q)(3)='1') or (c=2 and source=q)) else '0';
        end generate;
        edge : if x<0 or x>=8 or y<0 or y>=8 generate hits(16+d)<='0'; end generate;
      end generate;
      pawns : for side in 0 to 1 generate
        constant x : integer := s mod 8+side*2-1;
        signal from_white,from_black : std_logic;
      begin
        white_inside : if x>=0 and x<8 and s/8>0 generate
          constant q : integer := (s/8-1)*8+x;
        begin
          from_white<='1' when board(q)=x"1" and (c=0 or (c=2 and source=q)) else '0';
        end generate;
        white_edge : if x<0 or x>=8 or s/8=0 generate from_white<='0'; end generate;
        black_inside : if x>=0 and x<8 and s/8<7 generate
          constant q : integer := (s/8+1)*8+x;
        begin
          from_black<='1' when board(q)=x"9" and (c=1 or (c=2 and source=q)) else '0';
        end generate;
        black_edge : if x<0 or x>=8 or s/8=7 generate from_black<='0'; end generate;
        hits(24+side)<=from_white or from_black;
      end generate;
      maps(c)(s)<='1' when hits/=(hits'range=>'0') else '0';
    end generate;
  end generate;
end architecture;
