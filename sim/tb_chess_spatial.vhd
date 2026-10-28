library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;
use work.chess_pkg.all;
entity tb_chess_spatial is
  generic(VECTOR_FILE : string := ".cache/chess_vectors.txt");
end;
architecture test of tb_chess_spatial is
  signal board : board_t := initial_board;
  signal source : natural range 0 to 63 := 0;
  signal ww,wb,wr,fw,fb,fr : std_logic_vector(63 downto 0);
begin
  wires : entity work.chess_spatial(wires) port map(board,source,ww,wb,wr);
  model : entity work.chess_spatial(search_model) port map(board,source,fw,fb,fr);
  process
    file vectors : text open read_mode is VECTOR_FILE;
    variable row : line;
    variable n,count : natural := 0;
  begin
    while not endfile(vectors) loop
      readline(vectors,row);
      for s in 0 to 63 loop read(row,n); board(s)<=std_logic_vector(to_unsigned(n,4)); end loop;
      for s in 0 to 63 loop
        source<=s; wait for 1 ns;
        assert ww=fw and wb=fb and wr=fr report "Search spatial model differs from wired RTL" severity failure;
      end loop;
      count:=count+1;
    end loop;
    report "PASS: wired and search-model attack/reach planes agree for all 64 sources in "&integer'image(count)&" positions";
    finish;
  end process;
end;
