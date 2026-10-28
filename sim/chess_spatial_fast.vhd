-- Algorithmic combinational model for long search simulations only. The
-- production QSF uses the wired architecture. tb_chess_spatial compares both
-- architectures on every source square of the independent rules fixtures.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.chess_pkg.all;

architecture search_model of chess_spatial is
  constant KX : offsets_t := (1,2,2,1,-1,-2,-2,-1);
  constant KY : offsets_t := (2,1,-1,-2,-2,-1,1,2);
  function attacks(pieces : board_t; from_square : natural) return std_logic_vector is
    variable result : std_logic_vector(63 downto 0) := (others=>'0');
    variable k,x,y,q : integer;
  begin
    k:=kind(pieces(from_square));
    if k=1 then
      y:=from_square/8+1; if pieces(from_square)(3)='1' then y:=from_square/8-1; end if;
      for side in 0 to 1 loop
        x:=from_square mod 8+side*2-1;
        if x>=0 and x<8 and y>=0 and y<8 then result(y*8+x):='1'; end if;
      end loop;
    elsif k=2 or k=6 then
      for d in 0 to 7 loop
        if k=2 then x:=from_square mod 8+KX(d); y:=from_square/8+KY(d);
        else x:=from_square mod 8+DX(d); y:=from_square/8+DY(d); end if;
        if x>=0 and x<8 and y>=0 and y<8 then result(y*8+x):='1'; end if;
      end loop;
    elsif k>=3 and k<=5 then
      for d in 0 to 7 loop
        if k=5 or (k=4 and d<4) or (k=3 and d>=4) then
          for distance in 1 to 7 loop
            x:=from_square mod 8+DX(d)*distance; y:=from_square/8+DY(d)*distance;
            exit when x<0 or x>=8 or y<0 or y>=8;
            q:=y*8+x; result(q):='1'; exit when kind(pieces(q))/=0;
          end loop;
        end if;
      end loop;
    end if;
    return result;
  end;
begin
  process(board)
    variable w,b : std_logic_vector(63 downto 0);
  begin
    w:=(others=>'0'); b:=(others=>'0');
    for s in 0 to 63 loop
      if kind(board(s))/=0 then
        if board(s)(3)='0' then w:=w or attacks(board,s); else b:=b or attacks(board,s); end if;
      end if;
    end loop;
    white_attack<=w; black_attack<=b;
  end process;
  reachable<=attacks(board,source);
end;
