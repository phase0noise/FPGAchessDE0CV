library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.chess_pkg.all;
entity tb_chess_search_memory is end;
architecture test of tb_chess_search_memory is
  signal clk : std_logic := '0';
  signal qw,cw,hw : std_logic := '0';
  signal qa,qr : natural range 0 to SEARCH_LEVELS*SEARCH_MOVES-1 := 0;
  signal ca,cr : natural range 0 to CACHE_ENTRIES-1 := 0;
  signal ha,hr : natural range 0 to 4095 := 0;
  signal qd,qq : std_logic_vector(31 downto 0) := (others=>'0');
  signal cd,cq : std_logic_vector(127 downto 0) := (others=>'0');
  signal hd,hq : unsigned(12 downto 0) := (others=>'0');
  signal piece : piece_t := x"0";
  signal square : natural range 0 to 63 := 0;
  signal hash : hash_t;
  signal hash_pieces : pieces4_t := (others=>x"0");
  signal hash_group : natural range 0 to 15 := 0;
  signal hash_keys : hashes4_t;
  signal queue_words : words4_t;
begin
  clk<=not clk after 10 ns;
  dut : entity work.chess_search_memory port map(clk,qw,qa,qr,qd,qq,cw,ca,cr,cd,cq,hw,ha,hr,hd,hq,piece,square,hash,hash_pieces,hash_group,hash_keys,queue_words);
  process
    variable old_hash : hash_t;
  begin
    wait until falling_edge(clk);
    for level in 0 to SEARCH_LEVELS-1 loop
      qw<='1';qa<=level*SEARCH_MOVES+SEARCH_MOVES-1;qd<=std_logic_vector(to_unsigned(level+123,32));
      wait until falling_edge(clk);
    end loop;
    qw<='0';
    for level in 0 to SEARCH_LEVELS-1 loop
      qr<=level*SEARCH_MOVES+SEARCH_MOVES-1;wait until falling_edge(clk);
      assert unsigned(qq)=level+123 report "Search move levels alias in RAM" severity failure;
    end loop;
    cw<='1';ca<=CACHE_ENTRIES-1;cd<=(others=>'1');hw<='1';ha<=4095;hd<=to_unsigned(8191,13);
    wait until falling_edge(clk);cw<='0';hw<='0';cr<=CACHE_ENTRIES-1;hr<=4095;
    wait until falling_edge(clk);
    assert cq=(cq'range=>'1') and hq=8191 report "Cache/history RAM readback failed" severity failure;
    cr<=0;hr<=0;wait until falling_edge(clk);
    assert cq=(cq'range=>'0') and hq=0 report "RAM endpoints alias or initial contents are invalid" severity failure;
    piece<=x"1";square<=8;wait until falling_edge(clk);old_hash:=hash;
    piece<=x"9";wait until falling_edge(clk);assert hash/=old_hash report "Piece colors have the same position key" severity failure;
    piece<=x"1";square<=9;wait until falling_edge(clk);assert hash/=old_hash report "Squares have the same position key" severity failure;
    piece<=x"0";wait until falling_edge(clk);assert hash=0 report "Empty squares change the position hash" severity failure;
    assert position_salt('0',"1111",64)/=position_salt('1',"1111",64) severity failure;
    assert position_salt('0',"1111",64)/=position_salt('0',"1110",64) severity failure;
    assert position_salt('0',"1111",64)/=position_salt('0',"1111",20) severity failure;
    for level in 0 to SEARCH_LEVELS-1 loop
      for lane in 0 to 3 loop
        qw<='1';qa<=level*SEARCH_MOVES+SEARCH_MOVES-4+lane;qd<=std_logic_vector(to_unsigned(level*100+lane,32));wait until falling_edge(clk);
      end loop;
      qw<='0';qr<=level*SEARCH_MOVES+SEARCH_MOVES-4;wait until falling_edge(clk);
      for lane in 0 to 3 loop assert unsigned(queue_words(lane))=level*100+lane report "Four-bank queue data/level mismatch" severity failure;end loop;
    end loop;
    for code in 0 to 15 loop
      hash_pieces<=(others=>std_logic_vector(to_unsigned(code,4)));piece<=std_logic_vector(to_unsigned(code,4));
      for group_index in 0 to 15 loop
        hash_group<=group_index;wait until falling_edge(clk);
        for lane in 0 to 3 loop
          square<=group_index*4+lane;wait until falling_edge(clk);
          assert hash_keys(lane)=hash report "Banked hash key differs from scalar lookup" severity failure;
        end loop;
      end loop;
    end loop;
    report "PASS: all search RAM levels, cache/history endpoints, initial state and position-key metadata";
    finish;
  end process;
end;
