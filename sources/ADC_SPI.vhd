library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ADC_SPI is
    Port ( clk : in STD_LOGIC;
           NCS : out STD_LOGIC;
           sck : out STD_LOGIC;
           reset : in STD_LOGIC;
           ADC_DATA : out std_logic_vector(15 downto 0);
           --debug_out : out std_logic_vector(3 downto 0);
           DOUT : in STD_LOGIC);
end ADC_SPI;

architecture Behavioral of ADC_SPI is
signal sck_proc, sck_en, ncs_sig : std_logic;
signal data_in : std_logic_vector(15 downto 0);
signal data_in_temp : std_logic_vector(15 downto 0);
begin

prescaler: process(clk)
variable cnt_presc: integer:= 0;
begin
    if rising_edge(clk) then
        if (cnt_presc = 4) then
            sck_proc <= not sck_proc;
            sck_en <= '1';
            cnt_presc := 0;
        else
            sck_en <= '0';
            cnt_presc := cnt_presc + 1;
        end if;
        
    end if;
end process;

adc_spi : process(clk)
variable spi_cnt : integer := 0; 
begin
if rising_edge(clk) then
    if (sck_en = '1' and sck_proc = '0') then
        if spi_cnt > 18 then
            ncs_sig <= '1';
            data_in <= data_in_temp and x"0FFF";
            spi_cnt := 0;
        elsif spi_cnt > 2 then
            ncs_sig <= '0';
            data_in_temp <= data_in_temp(14 downto 0) & DOUT; 
        else 
            ncs_sig <= '1';
            data_in <= data_in_temp and x"0FFF";
        end if;
        spi_cnt := spi_cnt +1;
    end if;
end if;
end process;

NCS <= ncs_sig;
sck <= sck_proc when ncs_sig = '0' else '1';
ADC_DATA <= data_in;

--debug_out(3) <= ncs_sig;
--debug_out(2) <= DOUT;
--debug_out(1) <= sck_en;
--debug_out(0) <= sck_proc;

end Behavioral;
