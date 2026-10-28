library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- SPI mode-0 target with an 8-bit auto-incrementing register pointer.
-- A frame is COMMAND, ADDRESS, DATA... . COMMAND x"00" writes the following
-- data bytes and COMMAND x"80" returns register data during following bytes.
entity spi_target is
  port (
    clk_i           : in  std_logic;
    reset_n_i       : in  std_logic;
    sclk_i          : in  std_logic;
    cs_n_i          : in  std_logic;
    mosi_i          : in  std_logic;
    miso_o          : out std_logic;

    reg_addr_o      : out std_logic_vector(7 downto 0);
    reg_write_addr_o: out std_logic_vector(7 downto 0);
    reg_read_data_i : in  std_logic_vector(7 downto 0);
    reg_write_data_o: out std_logic_vector(7 downto 0);
    reg_write_o     : out std_logic;
    reg_read_o      : out std_logic;
    busy_o          : out std_logic;
    activity_o      : out std_logic;
    frame_o         : out std_logic;
    frame_error_o   : out std_logic
  );
end entity;

architecture rtl of spi_target is
  type state_t is (COMMAND_BYTE, ADDRESS_BYTE, DATA_BYTES, IGNORE_FRAME);

  signal state            : state_t := COMMAND_BYTE;
  signal sclk_meta        : std_logic := '0';
  signal sclk_sync        : std_logic := '0';
  signal sclk_previous    : std_logic := '0';
  signal cs_meta          : std_logic := '1';
  signal cs_sync          : std_logic := '1';
  signal cs_previous      : std_logic := '1';
  signal mosi_meta        : std_logic := '0';
  signal mosi_sync        : std_logic := '0';
  signal sclk_rising      : std_logic;
  signal sclk_falling     : std_logic;
  signal cs_falling       : std_logic;
  signal cs_rising        : std_logic;

  signal bit_count        : unsigned(2 downto 0) := (others => '0');
  signal receive_shift    : std_logic_vector(7 downto 0) := (others => '0');
  signal transmit_data    : std_logic_vector(7 downto 0) := (others => '0');
  signal register_pointer : unsigned(7 downto 0) := (others => '0');
  signal write_address    : std_logic_vector(7 downto 0) := (others => '0');
  signal read_direction   : std_logic := '0';
  signal miso_data        : std_logic := '0';
  signal bus_busy         : std_logic := '0';
  signal data_seen        : std_logic := '0';
  signal frame_invalid    : std_logic := '0';
begin
  reg_addr_o       <= std_logic_vector(register_pointer);
  reg_write_addr_o <= write_address;
  miso_o           <= miso_data;
  busy_o           <= bus_busy;

  sclk_rising  <= '1' when sclk_sync = '1' and sclk_previous = '0' else '0';
  sclk_falling <= '1' when sclk_sync = '0' and sclk_previous = '1' else '0';
  cs_falling    <= '1' when cs_sync = '0' and cs_previous = '1' else '0';
  cs_rising     <= '1' when cs_sync = '1' and cs_previous = '0' else '0';

  -- The board clock oversamples the SPI pins. Two flip-flops on each input
  -- contain metastability; the validated 5 MHz bus rate leaves ample margin.
  input_synchronizer : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if reset_n_i = '0' then
        sclk_meta <= '0';
        sclk_sync <= '0';
        cs_meta   <= '1';
        cs_sync   <= '1';
        mosi_meta <= '0';
        mosi_sync <= '0';
      else
        sclk_meta <= sclk_i;
        sclk_sync <= sclk_meta;
        cs_meta   <= cs_n_i;
        cs_sync   <= cs_meta;
        mosi_meta <= mosi_i;
        mosi_sync <= mosi_meta;
      end if;
    end if;
  end process;

  protocol : process(clk_i)
    variable received_byte : std_logic_vector(7 downto 0);
    variable bit_index     : integer range 0 to 7;
  begin
    if rising_edge(clk_i) then
      if reset_n_i = '0' then
        state              <= COMMAND_BYTE;
        sclk_previous      <= '0';
        cs_previous        <= '1';
        bit_count          <= (others => '0');
        receive_shift      <= (others => '0');
        transmit_data      <= (others => '0');
        register_pointer   <= (others => '0');
        write_address      <= (others => '0');
        read_direction     <= '0';
        miso_data          <= '0';
        bus_busy           <= '0';
        data_seen          <= '0';
        frame_invalid      <= '0';
        reg_write_data_o   <= (others => '0');
        reg_write_o        <= '0';
        reg_read_o         <= '0';
        activity_o         <= '0';
        frame_o            <= '0';
        frame_error_o      <= '0';
      else
        sclk_previous <= sclk_sync;
        cs_previous   <= cs_sync;
        reg_write_o   <= '0';
        reg_read_o    <= '0';
        activity_o    <= '0';
        frame_o       <= '0';
        frame_error_o <= '0';

        if cs_falling = '1' then
          state           <= COMMAND_BYTE;
          bit_count       <= (others => '0');
          receive_shift   <= (others => '0');
          read_direction  <= '0';
          data_seen       <= '0';
          frame_invalid   <= '0';
          miso_data       <= '0';
          bus_busy        <= '1';
          activity_o      <= '1';
        elsif cs_rising = '1' then
          state       <= COMMAND_BYTE;
          miso_data   <= '0';
          bus_busy    <= '0';
          activity_o  <= '1';
          frame_o     <= '1';
          if frame_invalid = '1' or state /= DATA_BYTES or
             data_seen = '0' or bit_count /= 0 then
            frame_error_o <= '1';
          end if;
        elsif cs_sync = '0' then
          if sclk_rising = '1' then
            received_byte := receive_shift(6 downto 0) & mosi_sync;
            receive_shift <= received_byte;

            if bit_count = 7 then
              bit_count <= (others => '0');
              activity_o <= '1';
              case state is
                when COMMAND_BYTE =>
                  if received_byte = x"00" then
                    read_direction <= '0';
                    state          <= ADDRESS_BYTE;
                  elsif received_byte = x"80" then
                    read_direction <= '1';
                    state          <= ADDRESS_BYTE;
                  else
                    state <= IGNORE_FRAME;
                    frame_invalid <= '1';
                  end if;

                when ADDRESS_BYTE =>
                  register_pointer <= unsigned(received_byte);
                  state            <= DATA_BYTES;

                when DATA_BYTES =>
                  data_seen <= '1';
                  if read_direction = '0' then
                    write_address    <= std_logic_vector(register_pointer);
                    reg_write_data_o <= received_byte;
                    reg_write_o      <= '1';
                  else
                    reg_read_o <= '1';
                  end if;
                  register_pointer <= register_pointer + 1;

                when IGNORE_FRAME =>
                  null;
              end case;
            else
              bit_count <= bit_count + 1;
            end if;
          end if;

          -- Mode 0 changes MISO on falling edges and samples MOSI on rising
          -- edges. Read data begins in the byte immediately after ADDRESS.
          if sclk_falling = '1' then
            if state = DATA_BYTES and read_direction = '1' then
              if bit_count = 0 then
                transmit_data <= reg_read_data_i;
                miso_data     <= reg_read_data_i(7);
              else
                bit_index := 7 - to_integer(bit_count);
                miso_data <= transmit_data(bit_index);
              end if;
            else
              miso_data <= '0';
            end if;
          end if;
        else
          miso_data <= '0';
          bus_busy  <= '0';
        end if;
      end if;
    end if;
  end process;
end architecture;
