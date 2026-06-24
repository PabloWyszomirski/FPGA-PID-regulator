library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity DEBOUNCER is
Generic(
            debounce_time: integer := 20 -- opóźnienie [ms]
);
Port ( 
       signal clk: in std_logic; --100MHz
       signal rst: in std_logic;
       signal btn_in: in std_logic;
       signal db_out: out std_logic );
end DEBOUNCER;

architecture Behavioral of DEBOUNCER is

    constant debounce_count: integer := debounce_time*100000; 
    signal counter_trigger: std_logic;
    signal ff: std_logic_vector(1 downto 0) := "00";

begin
 
    counter_trigger <= ff(0) xor ff(1);
    
Debounce: process(clk)

    variable counter: integer range 0 to debounce_count := 0;
    
    begin   
    if (rst='1') then
        counter := 0;
        ff <= "00";
    elsif rising_edge (clk) then
    ff(0)<=btn_in;
    ff(1)<=ff(0);
        if (counter_trigger='1')then
            counter :=  0;
        elsif(counter<debounce_count)then
            counter := counter + 1;
        else
            db_out<=ff(1);
        end if;
    
    end if;
    
end process Debounce;

end Behavioral;
