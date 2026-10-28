library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_spi_target is
end entity;

architecture test of tb_spi_target is
  constant CLOCK_PERIOD : time := 20 ns;
  constant SPI_HALF     : time := 100 ns; -- 5 MHz SPI clock

  type memory_t is array (0 to 255) of std_logic_vector(7 downto 0);

  signal clk               : std_logic := '0';
  signal reset_n           : std_logic := '0';
  signal spi_sclk          : std_logic := '0';
  signal spi_cs_n          : std_logic := '1';
  signal spi_mosi          : std_logic := '0';
  signal spi_miso          : std_logic;
  signal reg_address       : std_logic_vector(7 downto 0);
  signal reg_write_address : std_logic_vector(7 downto 0);
  signal reg_read_data     : std_logic_vector(7 downto 0);
  signal reg_write_data    : std_logic_vector(7 downto 0);
  signal reg_write         : std_logic;
  signal reg_read          : std_logic;
  signal busy              : std_logic;
  signal activity          : std_logic;
  signal frame_done        : std_logic;
  signal frame_error       : std_logic;
  signal memory            : memory_t := (others => (others => '0'));
  signal write_count       : natural := 0;
  signal read_count        : natural := 0;
  signal frame_count       : natural := 0;
  signal error_count       : natural := 0;
begin
  clk <= not clk after CLOCK_PERIOD / 2;

  dut : entity work.spi_target
    port map (
      clk_i             => clk,
      reset_n_i         => reset_n,
      sclk_i            => spi_sclk,
      cs_n_i            => spi_cs_n,
      mosi_i            => spi_mosi,
      miso_o            => spi_miso,
      reg_addr_o        => reg_address,
      reg_write_addr_o  => reg_write_address,
      reg_read_data_i   => reg_read_data,
      reg_write_data_o  => reg_write_data,
      reg_write_o       => reg_write,
      reg_read_o        => reg_read,
      busy_o            => busy,
      activity_o        => activity,
      frame_o           => frame_done,
      frame_error_o     => frame_error
    );

  reg_read_data <= memory(to_integer(unsigned(reg_address)));

  register_model : process(clk)
  begin
    if rising_edge(clk) then
      if reg_write = '1' then
        memory(to_integer(unsigned(reg_write_address))) <= reg_write_data;
        write_count <= write_count + 1;
      end if;
      if reg_read = '1' then
        read_count <= read_count + 1;
      end if;
      if frame_done = '1' then
        frame_count <= frame_count + 1;
      end if;
      if frame_error = '1' then
        error_count <= error_count + 1;
      end if;
    end if;
  end process;

  stimulus : process
    procedure begin_frame is
    begin
      spi_sclk <= '0';
      spi_cs_n <= '0';
      wait for 2 * SPI_HALF;
      assert busy = '1' report "target did not become busy" severity failure;
    end procedure;

    procedure end_frame is
    begin
      spi_sclk <= '0';
      wait for SPI_HALF;
      spi_cs_n <= '1';
      wait for 2 * SPI_HALF;
      assert busy = '0' report "target remained busy after CS" severity failure;
    end procedure;

    procedure transfer_byte(
      constant tx : in std_logic_vector(7 downto 0);
      variable rx : out std_logic_vector(7 downto 0)
    ) is
    begin
      for bit_index in 7 downto 0 loop
        spi_mosi <= tx(bit_index);
        wait for SPI_HALF;
        spi_sclk <= '1';
        wait for SPI_HALF / 2;
        rx(bit_index) := spi_miso;
        wait for SPI_HALF / 2;
        spi_sclk <= '0';
      end loop;
    end procedure;

    variable reply : std_logic_vector(7 downto 0);
  begin
    wait for 10 * CLOCK_PERIOD;
    reset_n <= '1';
    wait for 10 * CLOCK_PERIOD;

    -- Two sequential writes beginning at register 0x30.
    begin_frame;
    transfer_byte(x"00", reply);
    transfer_byte(x"30", reply);
    transfer_byte(x"A5", reply);
    transfer_byte(x"5A", reply);
    end_frame;
    wait for 5 * CLOCK_PERIOD;
    assert memory(16#30#) = x"A5" report "first SPI write failed" severity failure;
    assert memory(16#31#) = x"5A" report "write auto-increment failed" severity failure;
    assert write_count = 2 report "incorrect write strobe count" severity failure;

    -- Read the same registers. The first returned byte follows the address.
    begin_frame;
    transfer_byte(x"80", reply);
    assert reply = x"00" report "MISO should be zero during command" severity failure;
    transfer_byte(x"30", reply);
    assert reply = x"00" report "MISO should be zero during address" severity failure;
    transfer_byte(x"00", reply);
    assert reply = x"A5" report "first SPI read failed" severity failure;
    transfer_byte(x"00", reply);
    assert reply = x"5A" report "read auto-increment failed" severity failure;
    end_frame;
    wait for 5 * CLOCK_PERIOD;
    assert read_count = 2 report "incorrect read strobe count" severity failure;

    -- Unsupported commands must ignore the rest of their frame.
    begin_frame;
    transfer_byte(x"55", reply);
    transfer_byte(x"30", reply);
    transfer_byte(x"FF", reply);
    end_frame;
    wait for 5 * CLOCK_PERIOD;
    assert memory(16#30#) = x"A5" report "invalid command changed memory" severity failure;
    assert write_count = 2 report "invalid command produced a write" severity failure;

    -- A fresh CS assertion must recover from an incomplete frame.
    begin_frame;
    transfer_byte(x"00", reply);
    end_frame;
    begin_frame;
    transfer_byte(x"00", reply);
    transfer_byte(x"40", reply);
    transfer_byte(x"C3", reply);
    end_frame;
    wait for 5 * CLOCK_PERIOD;
    assert memory(16#40#) = x"C3" report "CS frame reset failed" severity failure;
    assert frame_count = 5 report "incorrect completed-frame count" severity failure;
    assert error_count = 2 report "malformed frames were not counted" severity failure;

    report "TEST PASSED" severity note;
    wait;
  end process;
end architecture;
