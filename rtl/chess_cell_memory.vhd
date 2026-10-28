-- Two native-clock true dual-port M10K banks. Same-port writes return new data.
-- Cross-port collisions are not consumed by the neuron sequencer.
library ieee;
use ieee.std_logic_1164.all;
use work.chess_pkg.all;

entity chess_cell_memory is
  port(clk : in std_logic;
    policy_we,cell_we : in std_logic;
    policy_a,policy_b : in natural range 0 to 127;
    cell_a,cell_b : in natural range 0 to 63;
    policy_data,cell_data : in byte_t;
    policy_q_a,policy_q_b,cell_q_a,cell_q_b : out byte_t);
end;

architecture m9k of chess_cell_memory is
begin
  process(clk)
    variable policy_ram : bytes_t(0 to 127);
    variable cell_ram : bytes_t(0 to 63);
    attribute ramstyle : string;
    attribute ramstyle of policy_ram,cell_ram : variable is "M10K, no_rw_check";
  begin
    if rising_edge(clk) then
      if policy_we='1' then policy_ram(policy_a):=policy_data; end if;
      policy_q_a<=policy_ram(policy_a);
      policy_q_b<=policy_ram(policy_b);
      if cell_we='1' then cell_ram(cell_b):=cell_data; end if;
      cell_q_a<=cell_ram(cell_a);
      cell_q_b<=cell_ram(cell_b);
    end if;
  end process;
end;
