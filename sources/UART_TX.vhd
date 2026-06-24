library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity UART_TX is
    Generic(
        clk_freq: integer := 100000000;
        baud_rate: integer := 230400;
        data_bits: integer := 8;  -- ilosc bitow danych w ramce
        sb_tick: integer := 16    -- ilosc zliczen bitow stop 
    );
    Port( 
        clk, rst: in std_logic;
        tx_start: in std_logic;
        din: in std_logic_vector(7 downto 0);        
        tx_done_tick: out std_logic;
        tx_output: out std_logic
    );
end UART_TX;

architecture Behavioral of UART_TX is

    -- Stany dla pojedynczego bajtu
    type state_type is (idle, start, data, stop);
    signal state_reg, state_next: state_type;
    signal s_reg, s_next: unsigned(3 downto 0); -- licznik próbek (0-15)
    signal n_reg, n_next: unsigned(2 downto 0); -- licznik bitów danych (0-7)
    signal b_reg, b_next: std_logic_vector(7 downto 0); -- rejestr przesuwny
    signal tx_reg, tx_next: std_logic;
    
    -- Generator baud rate
    signal baud_tick: std_logic := '0';
    constant baud_divider: integer := clk_freq / (16 * baud_rate);

begin

    tx_output <= tx_reg;

    Baud_rate_gen: process(clk, rst) -- nadpróbkowanie 16*baud
        variable baud_counter : integer := 0;
    begin
        if rst = '1' then
            baud_tick <= '0';
            baud_counter := 0;
        elsif rising_edge(clk) then
            if baud_counter = baud_divider - 1 then
                baud_tick <= '1';
                baud_counter := 0;
            else
                baud_counter := baud_counter + 1;
                baud_tick <= '0';
            end if;
        end if;
    end process Baud_rate_gen;

    FSMD: process(clk, rst) 
    begin
        if rst = '1' then
            state_reg <= idle;
            s_reg     <= (others => '0');
            n_reg     <= (others => '0');
            b_reg     <= (others => '0');
            tx_reg    <= '1';
        elsif rising_edge(clk) then
            state_reg <= state_next;
            s_reg     <= s_next;
            n_reg     <= n_next;
            b_reg     <= b_next;
            tx_reg    <= tx_next;
        end if;
    end process FSMD;
    
    main: process(state_reg, s_reg, n_reg, b_reg, baud_tick, tx_reg, tx_start, din)
    begin
        state_next <= state_reg;
        s_next     <= s_reg;
        n_next     <= n_reg;
        b_next     <= b_reg;
        tx_next    <= tx_reg;
        tx_done_tick <= '0';
        
        case state_reg is
            when idle =>
                tx_next <= '1';
                if tx_start = '1' then
                    state_next <= start;
                    s_next <= (others => '0');
                    b_next <= din;
                end if;
                
            when start =>
                tx_next <= '0';
                if baud_tick = '1' then
                    if s_reg = 15 then
                        state_next <= data;
                        s_next <= (others => '0');
                        n_next <= (others => '0');
                    else
                        s_next <= s_reg + 1;
                    end if;
                end if;
                
            when data => 
                tx_next <= b_reg(0);
                if baud_tick = '1' then
                    if s_reg = 15 then
                        s_next <= (others => '0'); 
                        b_next <= '0' & b_reg(7 downto 1);
                        if n_reg = (data_bits - 1) then
                            state_next <= stop;
                        else 
                            n_next <= n_reg + 1;
                        end if;
                    else
                        s_next <= s_reg + 1;
                    end if; 
                end if;     
                
            when stop =>
                tx_next <= '1';
                if baud_tick = '1' then
                    if s_reg = (sb_tick - 1) then 
                        state_next <= idle;
                        tx_done_tick <= '1';
                    else
                        s_next <= s_reg + 1;
                    end if;
                end if;
        end case;
    end process main;
    
end Behavioral;