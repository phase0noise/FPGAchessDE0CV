library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.chess_pkg.all;

entity tb_chess_arithmetic is end;
architecture test of tb_chess_arithmetic is
begin
  process
    variable product : third_product_t;
    variable sample : unsigned(20 downto 0) := to_unsigned(1234567,21);
    procedure check(n : natural) is
    begin
      product:=third_product(to_unsigned(n,21));
      assert to_integer(product(40 downto 21))=n/3
        report "Reciprocal quotient differs from integer division" severity failure;
    end;
  begin
    -- Check every residue near both range limits and deterministic samples
    -- across the whole datapath against the language's independent divider.
    for n in 0 to 65535 loop
      check(n); check(2**21-1-n);
    end loop;
    for n in 0 to 16383 loop
      sample:=sample(19 downto 0)&(sample(20) xor sample(18));
      check(to_integer(sample));
    end loop;
    report "PASS: exact reciprocal quotient, limits and all three remainders" severity note;
    std.env.finish;
    wait;
  end process;
end;
