library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity SEG_DISP is
  Port (clk: in std_logic; 
        reset: in std_logic;
        --[28] -> [0] --kropki(inverted)[4bit] DP[5bit]    1 cyfa[5bit]     2 cyfra[5bit]    3 cyfra[5bit]    4 cyfra[5bit]  
        d_data: in std_logic_vector(28 downto 0);
        d_digit: out std_logic_vector(4 downto 0); --cyfra
        d_character: out std_logic_vector(7 downto 0) --segmenty       
         );
end SEG_DISP;

architecture Behavioral of SEG_DISP is

    signal refresh_counter: integer range 0 to 100000 := 0;
    signal active_digit: unsigned(2 downto 0):= "000";
    signal active_char: std_logic_vector (4 downto 0):="00000";
    signal dot: std_logic:='1';

begin

counter_proc: process(clk)
begin
    if(reset='1')then
        refresh_counter <= 0;
        active_digit <= "000";
    elsif rising_edge(clk) then
        if refresh_counter >= 100000 then
            refresh_counter <= 0;
                    
        if active_digit >= "100" then 
            active_digit <= "000";
        else
            active_digit <= active_digit + 1;
        end if;
    else                  
        refresh_counter <= refresh_counter + 1;
    end if;  
    end if;
end process counter_proc;

    bits_to_char: process(active_char)
    begin
      case(active_char) is  --> A B C D E F G    & .  0-ON 1-OFF
        when "00000" => d_character <= "0000001" & dot; --0 --DP - dwukropek i st
        when "00001" => d_character <= "1001111" & dot; --1 --DP dolna kropka i st
        when "00010" => d_character <= "0010010" & dot; --2 --Dp dwukropek
        when "00011" => d_character <= "0000110" & dot; --3 
        when "00100" => d_character <= "1001100" & dot; --4 --DP dolna kropka i st
        when "00101" => d_character <= "0100100" & dot; --5 --DP gorna kropka i st
        when "00110" => d_character <= "0100000" & dot; --6 
        when "00111" => d_character <= "0001111" & dot; --7
        when "01000" => d_character <= "0000000" & dot; --8
        when "01001" => d_character <= "0000100" & dot; --9 
        
        when "10000" => d_character <= "0001000" & dot; --A        
        when "10001" => d_character <= "1100000" & dot; --b  --STOPIEŃ       
        when "10010" => d_character <= "0110001" & dot; --C --gorna (dwu)kropka
        when "10011" => d_character <= "1000010" & dot; --d  --dolna(dwu)kropka+stopien    
        when "10100" => d_character <= "0110000" & dot; --E 
        when "10101" => d_character <= "0111000" & dot; --F 
        when "10110" => d_character <= "0110000" & dot; --g
        when "10111" => d_character <= "0110000" & dot; --h 
        when "11000" => d_character <= "1111001" & dot; --I 
               
        when "11001" => d_character <= "0011000" & dot; --P
        when "11010" => d_character <= "0100100" & dot; --S 
        when "11011" => d_character <= "1110001" & dot; --L 
        when "11100" => d_character <= "1100011" & dot; --u  --stopien

        when "11101" => d_character <= "1001000" & dot; --H
        when "11110" => d_character <= "1110110" & dot; --"z"

        when "11111" => d_character <= "1111111" & dot; --.
        when others  => d_character <= "11111111"; -- puste
        end case; 
  end process bits_to_char;  
  
draw_proc: process(clk)
 begin
    if rising_edge(clk) then
        case(active_digit) is
            when "000" => 
            d_digit<="11101";
            active_char<= d_data(4 downto 0);
            dot<=d_data(25);
            
            when "001" => 
            d_digit<="11011";
            active_char<= d_data(9 downto 5);
            dot<=d_data(26);
            
            when "010" => 
            d_digit<="10111"; 
            active_char<= d_data(14 downto 10);
            dot<=d_data(27);
            
            when "011" => 
            d_digit<="01111"; 
            active_char<= d_data(19 downto 15);
            dot<=d_data(28);
            
            when "100" => 
            d_digit<="11110"; -- DP
            active_char<= d_data(24 downto 20);
            dot<='1';
            
            when others =>
            d_digit<="11111";
            active_char <= "00000";
        end case;
    end if;
 end process draw_proc;
end Behavioral;