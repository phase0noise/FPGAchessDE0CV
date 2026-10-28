-- Synchronous Cyclone V block RAM: ordered moves, transpositions, quiet history
-- and a constant Zobrist ROM. No RAM contents are reset through logic.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.chess_pkg.all;

entity chess_search_memory is
  port(clk : in std_logic;
    queue_we : in std_logic;
    queue_write_address,queue_read_address : in natural range 0 to SEARCH_LEVELS*SEARCH_MOVES-1;
    queue_write_data : in std_logic_vector(31 downto 0);
    queue_data : out std_logic_vector(31 downto 0);
    cache_we : in std_logic;
    cache_write_address,cache_read_address : in natural range 0 to CACHE_ENTRIES-1;
    cache_write_data : in std_logic_vector(127 downto 0);
    cache_data : out std_logic_vector(127 downto 0);
    history_we : in std_logic;
    history_write_address,history_read_address : in natural range 0 to 4095;
    history_write_data : in unsigned(12 downto 0);
    history_data : out unsigned(12 downto 0);
    hash_piece : in piece_t; hash_square : in natural range 0 to 63;
    hash_data : out hash_t;
    hash_pieces : in pieces4_t := (others=>x"0");
    hash_group : in natural range 0 to 15 := 0;
    hash_keys : out hashes4_t := (others=>(others=>'0'));
    queue_words : out words4_t := (others=>(others=>'0')));
end;

architecture ram of chess_search_memory is
  type queue_ram_t is array(0 to SEARCH_LEVELS*SEARCH_MOVES/4-1) of std_logic_vector(31 downto 0);
  type cache_ram_t is array(0 to CACHE_ENTRIES-1) of std_logic_vector(127 downto 0);
  type history_ram_t is array(0 to 4095) of unsigned(12 downto 0);
  type hash_rom_t is array(0 to 255) of hash_t;
  function make_hash_rom(bank : natural) return hash_rom_t is
    variable result : hash_rom_t := (others=>(others=>'0'));
    variable seed,z : hash_t := x"6A09E667F3BCC909";
  begin
    for i in 0 to 1023 loop
      -- SplitMix64 is evaluated at elaboration, not synthesized as multipliers.
      seed:=seed+x"9E3779B97F4A7C15";
      z:=resize((seed xor shift_right(seed,30))*unsigned'(x"BF58476D1CE4E5B9"),64);
      z:=resize((z xor shift_right(z,27))*unsigned'(x"94D049BB133111EB"),64);
      if i mod 4=bank then
        result(i/4):=z xor shift_right(z,31);
        if i/64=0 then result(i/4):=(others=>'0'); end if;
      end if;
    end loop;
    return result;
  end;
  signal move_words : words4_t;
  signal cache : cache_ram_t := (others=>(others=>'0'));
  signal history : history_ram_t := (others=>(others=>'0'));
  signal legacy_keys : hashes4_t;
  attribute ramstyle : string;
  attribute ramstyle of cache,history : signal is "M10K, no_rw_check";
begin
  move_banks : for lane in 0 to 3 generate
    signal moves : queue_ram_t;
    attribute ramstyle of moves : signal is "M10K, no_rw_check";
  begin
    process(clk) begin
      if rising_edge(clk) then
        move_words(lane)<=moves(queue_read_address/4);
        if queue_we='1' and queue_write_address mod 4=lane then moves(queue_write_address/4)<=queue_write_data; end if;
      end if;
    end process;
  end generate;
  queue_words<=move_words;
  queue_data<=move_words(queue_read_address mod 4);
  banks : for lane in 0 to 3 generate
    signal hashes : hash_rom_t := make_hash_rom(lane);
    attribute ramstyle of hashes : signal is "M10K";
    attribute romstyle : string;
    attribute romstyle of hashes : signal is "M10K";
  begin
    process(clk) begin
      if rising_edge(clk) then
        hash_keys(lane)<=hashes(to_integer(unsigned(hash_pieces(lane)))*16+hash_group);
        legacy_keys(lane)<=hashes(to_integer(unsigned(hash_piece))*16+hash_square/4);
      end if;
    end process;
  end generate;
  hash_data<=legacy_keys(hash_square mod 4);
  process(clk) begin
    if rising_edge(clk) then
      cache_data<=cache(cache_read_address);
      if cache_we='1' then cache(cache_write_address)<=cache_write_data; end if;
      history_data<=history(history_read_address);
      if history_we='1' then history(history_write_address)<=history_write_data; end if;
    end if;
  end process;
end;
