library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.chess_pkg.all;
entity tb_chess_see is end;
architecture test of tb_chess_see is
  signal clk : std_logic := '0';
  signal reset,cancel,start,done : std_logic := '0';
  signal board : board_t := (others=>x"0");
  signal source,destination : natural range 0 to 63 := 0;
  signal promotion : natural range 0 to 6 := 0;
  signal ep : std_logic := '0';
  signal result : integer range -32000 to 32000;
begin
  clk<=not clk after 10 ns;
  dut : entity work.chess_see port map(clk,reset,cancel,start,board,source,destination,promotion,ep,done,result);
  process
    variable b : board_t;
    procedure check(constant s,d : natural; constant expected : integer; constant prom : natural := 0; constant enpassant : std_logic := '0') is
    begin
      board<=b;source<=s;destination<=d;promotion<=prom;ep<=enpassant;
      wait until falling_edge(clk);start<='1';wait until falling_edge(clk);start<='0';
      for i in 0 to 3000 loop wait until falling_edge(clk);exit when done='1';end loop;
      assert done='1' and result=expected report "SEE mismatch: "&integer'image(result)&" expected "&integer'image(expected) severity failure;
      cancel<='1';wait until falling_edge(clk);cancel<='0';
    end;
  begin
    reset<='1';wait until falling_edge(clk);reset<='0';
    b:=(others=>x"0");b(0):=x"4";b(48):=x"9";b(56):=x"C";check(0,48,-400);
    b:=(others=>x"0");b(27):=x"5";b(35):=x"9";b(59):=x"C";b(14):=x"3";check(27,35,-300);
    b:=(others=>x"0");b(36):=x"9";b(27):=x"5";check(36,27,900);
    b:=(others=>x"0");b(36):=x"1";b(35):=x"9";b(59):=x"C";check(36,43,0,0,'1');
    b:=(others=>x"0");b(48):=x"1";b(57):=x"C";b(58):=x"E";check(48,57,400,5);
    b(1):=x"4";check(48,57,1300,5);
    board<=b;start<='1';wait until falling_edge(clk);start<='0';cancel<='1';wait until falling_edge(clk);
    assert done='0' report "Canceled SEE leaked an old result" severity failure;
    report "PASS: exchange chains, x-rays, colors, en passant, promotion, king recapture and cancellation";finish;
  end process;
end;
