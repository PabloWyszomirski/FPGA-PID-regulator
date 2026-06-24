library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity PID is
    Generic(
            clk_freq: integer:= 100000000;
            pwm_bit_depth: integer := 12; -- PWM resolution
            pwm_freq: integer := 50000; -- output PWM frequency [Hz]
            temp_max: integer := 180; -- maximum resistor temperature - safety output cutoff
            setpoint_default: integer := 250; -- default setpoint * 10 =   25 degrees C
            -- default K parametrs * 100
            -- K_i needs to be scaled k/freq 
            -- K_d scaled k*freq
            P_param: integer := 100;  
            I_param: integer := 90;
            D_param: integer := 100; 
            --anti-windup upper border
            integral_limit: integer := 4095; 
            -- PID frequency
            PID_default_freq:  integer := 100;
            default_pid_count: integer := 1000000
            );
    
    Port ( 
        clk: in std_logic; --100MHz
        rst: in std_logic;
                --ADC--
        spi_dout       : in  std_logic;
        spi_ncs        : out std_logic;
        spi_sck        : out std_logic;
        --spi_debug      : out std_logic_vector(3 downto 0);
                --LEDs--
        LED_G  : out std_logic_vector(3 downto 0);
        LED_RGB_0: out std_logic_vector(2 downto 0);
        LED_RGB_1: out std_logic_vector(2 downto 0);
        LED_RGB_2: out std_logic_vector(2 downto 0);
        LED_RGB_3: out std_logic_vector(2 downto 0);
              --7_SEG_DISPLAY--
        disp_digit_pin: out std_logic_vector(4 downto 0); 
        disp_character_pin: out std_logic_vector(7 downto 0);
                --BUTTONS--
        btn_raw: in std_logic_vector(3 downto 0); 
                --SWITCHES--
        switch: in std_logic_vector(3 downto 0);
                  --PWM--
        pwm_output: out std_logic;
        pwm_test: out std_logic;
                  --UART--
        tx: out std_logic
    );
end PID;

architecture Behavioral of PID is

            --PID--
    signal PID_freq,PID_freq_snap: integer := PID_default_freq;
    signal max_pid_count: integer := default_pid_count;
    signal pid_freq_state: integer range 0 to 9 := 4;
    signal pid_counter: integer := 0;
    signal pid_tick: boolean := false;
    
    signal pid_calc_state : integer range 0 to 8 := 0;  

    signal control_out: unsigned(11 downto 0):= (others =>'0');
    signal control_in: integer range 0 to 4096 := 0;
    signal setpoint: integer range 0 to 4096 := setpoint_default;
    signal setpoint_reg: integer range 0 to 4096 := setpoint_default;
    signal Kp, Kp_reg : integer range 0 to 100000 := P_param;
    signal Ki, Ki_reg : integer range 0 to 100000 := I_param;
    signal Kd, Kd_reg : integer range 0 to 100000 := D_param;
    signal error: integer range -4096 to 4096 := 0;
    signal error_prev: integer := 0;
    signal integral: integer := 0;
    signal differential : integer range -8192 to 8192 := 0;    
    signal p_term, i_term, d_term: integer range -4194304 to 4194304 := 0;
    signal total: integer := 0;
    
            --ADC DOUT--
    signal internal_measured_value : std_logic_vector(15 downto 0);
      
            --ADC->DISP_DATA       
    signal to_disp: std_logic_vector(28 downto 0):= (others =>'0');  --4 bity na dolne kropki + 5 bitow na DP + (4 cyfry x 5 bitow na char)
    signal vol_to_disp: std_logic_vector(28 downto 0):= (others =>'0');
    signal convert_step : integer range 0 to 9 := 0;
    
             --FSM--
    signal state_num: integer range 0 to 7;
    
            --BUTTONS--
    signal btn: std_logic_vector(3 downto 0):="0000";
    signal btn_prev: std_logic_vector(3 downto 0):="0000";
       
            --PWM--
    signal pwm_duty_cycle: std_logic_vector(pwm_bit_depth-1 downto 0 ):= (others => '0'); 
    constant pwm_period_cnt: integer := 100000000 / pwm_freq; 
    signal pwm_value: std_logic := '0'; -- PWM_OUT

    signal freq_count: integer range 0 to pwm_period_cnt := 0; 
    signal pwm_duty_val: integer range 0 to 2**pwm_bit_depth := 0;
    
            --TEMP--
    signal termistor_V_out: unsigned (12 downto 0) := (others => '0'); 
    signal degrees: integer range 0 to 1800 := 0; -- "real time" temperature value {0;179}
    signal temp_to_disp: std_logic_vector(28 downto 0):= (others =>'0'); --Voltage conversion from thermistor to 7seg
    signal temp_state:integer range 0 to 7 := 0; --pipeline temp conversion
    signal sel_temp: integer range 0 to 1800 := 200; -- setpoint selection val
    signal temp_ok: boolean := true; -- false after reaching max temp, declared in generic
    
            --PID_param -> DISP     
    signal sel_temp_0,sel_temp_1,sel_temp_2,sel_temp_3,p_param_0,p_param_1,p_param_2,p_param_3,p_param_4: std_logic_vector (4 downto 0) := (others=>'0'); 
    signal i_param_0,i_param_1,i_param_2,i_param_3,i_param_4,d_param_0,d_param_1,d_param_2,d_param_3,d_param_4: std_logic_vector (4 downto 0) := (others=>'0'); 
        
       -- UART -> PC
    signal tx_start_sig,tx_done_sig: std_logic := '0';
    signal din_sig: std_logic_vector(7 downto 0):=(others=>'0');
    signal uart_tick: std_logic:='0'; -- transmission flag
    
    type uart_state is( idle, transmit_data, done);
    signal uart_state_reg : uart_state := idle;
    
     -- max UART freq
    constant uart_min_interval: integer := clk_freq / 100; 
    signal uart_rate_counter: integer range 0 to clk_freq / 100 := 0;
    --UART snapshot for correct PID values
    signal p_term_snap, i_term_snap, d_term_snap: integer := 0;
    signal control_in_snap, setpoint_snap, error_snap: integer := 0;
    signal control_out_snap: unsigned(11 downto 0):= (others =>'0');
    signal Kp_snap,Ki_snap,Kd_snap: integer := 0;
    
begin

    ADC_SPI_unit: entity work.ADC_SPI
        port map (clk => clk, reset => rst,NCS => spi_ncs, sck => spi_sck,     
        DOUT => spi_dout, ADC_DATA  => internal_measured_value); --, debug_out => spi_debug);
    
    SEG_DISP_unit: entity work.SEG_DISP
        port map(clk => clk, reset=>rst, d_data => to_disp,
        d_character=>disp_character_pin, d_digit=> disp_digit_pin);
        
    DEBOUNCER_unit_0: entity work.DEBOUNCER
        port map(clk => clk, rst => rst, btn_in => btn_raw(0), db_out => btn(0));
    DEBOUNCER_unit_1: entity work.DEBOUNCER
        port map(clk => clk, rst => rst, btn_in => btn_raw(1), db_out => btn(1));
    DEBOUNCER_unit_2: entity work.DEBOUNCER
        port map(clk => clk, rst => rst, btn_in => btn_raw(2), db_out => btn(2));
    DEBOUNCER_unit_3: entity work.DEBOUNCER
        port map(clk => clk, rst => rst, btn_in => btn_raw(3), db_out => btn(3));
        
     
        UART_TRANSMITTER_unit: entity work.UART_TX
       generic map (
        data_bits => 8,
        sb_tick => 16
    )
    port map (clk => clk,rst => rst,
        tx_start => tx_start_sig,
        din => din_sig,
        tx_done_tick => tx_done_sig,
        tx_output => tx    
    );
       
control_in <= degrees; --temperature from ADC * 10

main: process(clk) 
  
      begin
          if(rst='1')then
            p_term <= 0; Kp <= 0; 
            i_term <= 0; Ki <= 0; 
            d_term <= 0; Kd <= 0; 
            pid_counter <= 0;
            pid_tick <= false;
            pid_calc_state <= 0;
            uart_tick <='0';
            error <= 0;
            total <= 0;
            uart_rate_counter <= 0;

          elsif rising_edge(clk) then
          
                      if(pid_counter < max_pid_count)then
                        pid_counter <= pid_counter+1;
                        pid_tick<=false;
                      else
                        pid_tick<=true;
                        pid_counter <= 0;
                      end if;
                      
                      --UART freq lock at 100Hz for higher PID freq
                      if uart_rate_counter < uart_min_interval then
                        uart_rate_counter <= uart_rate_counter + 1;
                      end if;
                                            

                        case(pid_calc_state)is 
                         
                        when 0 => 
                                                 
                         setpoint <= setpoint_reg;
                         
                         if(switch(3)='1')then Kp <= 0;
                         else Kp <= Kp_reg; 
                         end if;
     
                         if(switch(2)='1')then Ki <= 0; integral <= 0;
                         else Ki <= Ki_reg;
                         end if;
                      
                         if(switch(1)='1')then Kd <= 0; 
                         else Kd <= Kd_reg;
                         end if; 
                         
                         pid_calc_state <= 1;
                         
                         when 1 => 
                            uart_tick<='0'; 
                            if (pid_tick) then
                                error <= setpoint - control_in;
                                pid_calc_state <= 2; 
                            end if;
                          
                         when 2 =>

                            if switch(0) = '0' then -- saturation guard with I_term switch disabled
                                integral <= 0; 
                             elsif (integral + error > integral_limit) then --anti-saturation clamp (can behave like on-off switch)
                               integral <= integral_limit;
                             elsif (integral + error < 0) then --no active cooling, no negative accumulation
                                integral <= 0;
                             else
                            integral <= integral + error;
                              end if;
                             pid_calc_state <= 3;
         
                         when 3 => 
                             differential <= error - error_prev;  
                             pid_calc_state <= 4;
                          
                         when 4 =>
                            p_term <= to_integer( (to_signed(Kp * error, 32)     * to_signed(5243, 14)) / 524288 );
                            pid_calc_state <= 5;
                            
                        when 5 =>
                            i_term <= to_integer( (to_signed(Ki * integral, 32)  * to_signed(5243, 14)) / 524288 );
                            
                            pid_calc_state <= 6;
                            
                        when 6 =>
                            d_term <= to_integer( (to_signed(Kd * differential, 32) * to_signed(5243, 14)) / 524288 );
                            pid_calc_state <= 7;
                                                  
                          
                         when 7 => total <= p_term + i_term + d_term;   pid_calc_state <= 8;
                          
                         when 8 => 
                              if total < 0 then
                                  control_out <= (others => '0');
                                  pwm_duty_cycle <= (others => '0');
                              elsif total > 4095 then
                                  control_out <= to_unsigned(4095, 12); 
                                  pwm_duty_cycle <= (others => '1');
                              else
                                  control_out <= to_unsigned(total,12);
                                  pwm_duty_cycle <= std_logic_vector(to_unsigned(total, 12));
                              end if;
                              
                             if uart_state_reg = idle and uart_rate_counter >= uart_min_interval then --UART snapshot
                                p_term_snap<=p_term; i_term_snap<=i_term; d_term_snap<=d_term;
                                control_in_snap<=control_in; setpoint_snap<=setpoint;
                                control_out_snap<=control_out;
                                error_snap<=error; PID_freq_snap<=PID_freq;
                                Kp_snap<=Kp/100; Ki_snap<=Ki/100; Kd_snap<=Kd/100;
                                uart_tick<='1';
                                uart_rate_counter <= 0;   
                            end if;            
                               
                              error_prev <= error;
                              pid_calc_state <= 0;
                            
                         end case;
              end if;
  end process main;
    
Voltage_to_disp: process(clk) -- ADC 12-bit digital output to voltage converter
  
    variable voltage: integer range 0 to 4096 := 0; -- Raw data from ADC
    variable V_Ref: integer range 0 to 5000 := 4096; -- ADC reference voltage [mV]
    variable mV_temp:  unsigned (24 downto 0) := (others => '0'); -- 5000 * 4096 = 20 480 000 | max 33 554 432
    variable mV: unsigned (12 downto 0) := (others => '0'); -- real time voltage [mV]
    variable temp_mV: integer range 0 to 8191;
    
    variable Vol_1,Vol_2,Vol_3: std_logic_vector(4 downto 0):= (others => '0');
    variable mV_pom_1,mV_pom_2,mV_pom_3: integer range 0 to 9 := 0;

  begin
     if (rst='1') then
        convert_step <= 0;
     elsif rising_edge(clk) then
        case(convert_step) is 
                 when 0 => 
                     voltage := to_integer(unsigned(internal_measured_value(11 downto 0)));
                     convert_step <= 1;                    
                 when 1 =>
                     mV_temp := to_unsigned(voltage * V_Ref,25);
                     convert_step <= 2;
                 when 2 =>
                     mV:= mV_temp(24 downto 12); -- /4096 
                     termistor_V_out <= mV; --used in temp conversion
                     temp_mV := to_integer(mV); 
                     convert_step <= 3;                       
                 when 3 => 
                     if temp_mV >= 5000 then mV_pom_1 := 5; temp_mV := temp_mV - 5000;
                     elsif temp_mV >= 4000 then mV_pom_1 := 4; temp_mV := temp_mV - 4000;
                     elsif temp_mV >= 3000 then mV_pom_1 := 3; temp_mV := temp_mV - 3000;
                     elsif temp_mV >= 2000 then mV_pom_1 := 2; temp_mV := temp_mV - 2000;
                     elsif temp_mV >= 1000 then mV_pom_1 := 1; temp_mV := temp_mV - 1000;
                     else mV_pom_1 := 0;
                     end if;
                     convert_step <= 4; 

                  when 4 => 
                     if temp_mV >= 900 then mV_pom_2 := 9; temp_mV := temp_mV - 900;
                     elsif temp_mV >= 800 then mV_pom_2 := 8; temp_mV := temp_mV - 800;
                     elsif temp_mV >= 700 then mV_pom_2 := 7; temp_mV := temp_mV - 700;
                     elsif temp_mV >= 600 then mV_pom_2 := 6; temp_mV := temp_mV - 600;
                     elsif temp_mV >= 500 then mV_pom_2 := 5; temp_mV := temp_mV - 500;
                     elsif temp_mV >= 400 then mV_pom_2 := 4; temp_mV := temp_mV - 400;
                     elsif temp_mV >= 300 then mV_pom_2 := 3; temp_mV := temp_mV - 300;
                     elsif temp_mV >= 200 then mV_pom_2 := 2; temp_mV := temp_mV - 200;
                     elsif temp_mV >= 100 then mV_pom_2 := 1; temp_mV := temp_mV - 100;
                     else mV_pom_2 := 0;
                     end if;
                convert_step <= 5; 

                when 5 => 
                     if temp_mV >= 90 then mV_pom_3 := 9; 
                     elsif temp_mV >= 80 then mV_pom_3 := 8; 
                     elsif temp_mV >= 70 then mV_pom_3 := 7; 
                     elsif temp_mV >= 60 then mV_pom_3 := 6; 
                     elsif temp_mV >= 50 then mV_pom_3 := 5; 
                     elsif temp_mV >= 40 then mV_pom_3 := 4; 
                     elsif temp_mV >= 30 then mV_pom_3 := 3; 
                     elsif temp_mV >= 20 then mV_pom_3 := 2; 
                     elsif temp_mV >= 10 then mV_pom_3 := 1; 
                     else mV_pom_3 := 0;
                    end if;
                    convert_step <= 6;                     
                 when 6 => 
                     Vol_1 := std_logic_vector(to_unsigned(mV_pom_1,5));
                     convert_step <= 7;
                 when 7 => 
                     Vol_2 := std_logic_vector(to_unsigned(mV_pom_2,5)); 
                     convert_step <= 8; 
                 when 8 => 
                     Vol_3 := std_logic_vector(to_unsigned(mV_pom_3,5));
                     convert_step <= 9;
                 when 9 => 
                     vol_to_disp <= "0111" & "11111" & Vol_1 & Vol_2 & Vol_3 & "11100";
                     convert_step <= 0;
                     
                 when others => 
                     convert_step <= 0;
             end case;
      end if;
    -- end if;  
  end process Voltage_to_disp;
  
Temp_read: process(clk) -- MCP9701 Voltage to temperature conversion

variable termistor_output: integer := 0;
variable voltage_subtracted: integer := 0; -- voltage value [mV]
variable temp_0,temp_1,temp_2,temp_3: integer range 0 to 10 := 0; --hundreds, tens, ones, tenths, hundredths

begin
    if (rst='1')then
        temp_ok<=true;
        LED_RGB_0(0) <= '0'; LED_RGB_1(0) <= '0';
        LED_RGB_2(0) <= '0'; LED_RGB_3(0) <= '0'; 
    elsif rising_edge(clk)then 
        case(temp_state) is 
            when 0 => 
            termistor_output := to_integer(termistor_V_out); temp_state <=1; -- conversion t= Vout-500mV/20mV , degrees * 10 
            when 1 => if (termistor_output < 500) then
                    degrees <= 0;
                else
                    degrees <= (termistor_output - 500) / 2; 
                end if;
                temp_state <= 2; 
            when 2 => 
                if(degrees > temp_max * 10)then
                    temp_ok<=false; 
                    LED_RGB_0(0) <= '1'; LED_RGB_1(0) <= '1'; 
                    LED_RGB_2(0) <= '1'; LED_RGB_3(0) <= '1'; 
                else
                    temp_ok<=true;
                    LED_RGB_0(0) <= '0'; LED_RGB_1(0) <= '0'; 
                    LED_RGB_2(0) <= '0'; LED_RGB_3(0) <= '0'; 
                end if;      
            temp_state <= 3;
            when 3 => temp_0 := degrees / 1000; temp_state <= 4;
            when 4 => temp_1 := (degrees mod 1000) / 100; temp_state <= 5;
            when 5 => temp_2 := (degrees mod 100)/10; temp_state <= 6;
            when 6 => temp_3 := (degrees mod 10); temp_state <= 7; -- 0,1st C
            when 7 => 
                if(degrees<999)then
                    temp_to_disp <= "1011" & "10001" & std_logic_vector(to_unsigned(temp_1, 5)) & std_logic_vector(to_unsigned(temp_2,5))  & std_logic_vector(to_unsigned(temp_3,5)) & "10010";
                else
                    temp_to_disp <= "1101" & "10001" & std_logic_vector(to_unsigned(temp_0, 5)) & std_logic_vector(to_unsigned(temp_1,5))  & std_logic_vector(to_unsigned(temp_2,5)) & "10010";
                end if;
                temp_state<=0;
            when others => temp_state<=0;
        end case;
    end if;
end process Temp_read;

pwm_duty_val  <= to_integer(unsigned(pwm_duty_cycle));
pwm_output <= pwm_value;
pwm_test <= pwm_value; -- for testing output signal

PWM_heating: process(clk) --PWM output signal generator
begin
    if rising_edge(clk) then
        if(temp_ok)then 
            if (switch(0) = '1') then  --heating enabled for SW0 enabled
    
                if (freq_count < pwm_period_cnt - 1) then
                    freq_count <= freq_count + 1;
                else
                    freq_count <= 0;
                end if;
                
                if (freq_count < (pwm_duty_val  * pwm_period_cnt)/(2**pwm_bit_depth)) then
                    pwm_value <= '1';
                else
                    pwm_value <= '0';
                end if;
                
            else
                pwm_value <= '0';
                freq_count <= 0;
            end if;
            else
                pwm_value <= '0';
                freq_count <= 0;
        end if;
    end if;
end process PWM_heating;

FSM: process(clk) -- State machine for 7-seg display
begin
if(rst='1')then
LED_G<="0000"; 
elsif rising_edge(clk) then                        
      case(state_num) is 
          when 0 => -- Voltage from ADC
            LED_G<="0001"; 
            to_disp <= vol_to_disp;
       
          when 1 => -- Measured temperature
            LED_G<="0010";
            to_disp <= temp_to_disp;  
            
          when 2 => -- Setpoint selection
            LED_G<="0011";
            if(sel_temp <1000)then
            to_disp <= "1011" & "10001" & sel_temp_1 & sel_temp_2 & sel_temp_3 & "10010";   
            else        
            to_disp <= "1011" & "10001" & sel_temp_0 & sel_temp_1 & sel_temp_2 & "10010";  
            end if;
          when 3 => -- P parameter
            LED_G<="0100"; 
            if(Kp_reg<10000)then
                to_disp <= "1011" & "11111" & p_param_1 & p_param_2 & p_param_3 & p_param_4;
            else
                to_disp <= "1101" & "11111" & p_param_0 & p_param_1 & p_param_2 & p_param_3;
            end if;
            
          when 4 =>  -- I parameter
              LED_G<="0101";
              if(Ki_reg<9999)then
                to_disp <= "1011" & "11111" & i_param_1 & i_param_2 & i_param_3 & i_param_4;
              else
                to_disp <= "1101" & "11111" & i_param_0 & i_param_1 & i_param_2 & i_param_3;
              end if;
          when 5 =>  -- D parameter
              LED_G <= "0110"; 
              if(Kd_reg<9999)then
                to_disp <= "1011" & "11111" & d_param_1 & d_param_2 & d_param_3 & d_param_4;
              else
                to_disp <= "1101" & "11111" & d_param_0 & d_param_1 & d_param_2 & d_param_3;
              end if;

          when 6 => -- frequency display
            LED_G<="0111"; 
            case(pid_freq_state)is
            when 0 => to_disp <= "1111" & "11111" & "11111" & "00001" & "11101" & "11110"; --1Hz
            when 1 => to_disp <= "1111" & "11111" & "00001" & "00000" & "11101" & "11110"; --10Hz
            when 2 => to_disp <= "1111" & "11111" & "00010" & "00000" & "11101" & "11110"; --20Hz
            when 3 => to_disp <= "1111" & "11111" & "00101" & "00000" & "11101" & "11110"; --50Hz
            when 4 => to_disp <= "1111" & "11111" & "00001" & "00000" & "00000" & "11101"; --100H
            when 5 => to_disp <= "1111" & "11111" & "00001" & "10100" & "00011" & "11101"; --1E3H
            when 6 => to_disp <= "1111" & "11111" & "00101" & "10100" & "00011" & "11101"; --5E3H
            when 7 => to_disp <= "1111" & "11111" & "00001" & "10100" & "00100" & "11101"; --1E4H
            when 8 => to_disp <= "1111" & "11111" & "00010" & "10100" & "00100" & "11101"; --2E4H
            when 9 => to_disp <= "1111" & "11111" & "00011" & "10100" & "00100" & "11101"; --3E4H
            when others => to_disp <= "1111" & "11111" & "11111" & "11111" & "11111" & "11111"; --puste
        end case;
            
          when others=> LED_G<="1111";   
      end case;
   end if;
end process FSM; 

Button_0: process(clk)-- Change UI state     
begin
    if (rst = '1') then
        state_num <= 0;
        btn_prev(0) <= '0';
        
    elsif rising_edge(clk) then
        if btn(0) = '1' and btn_prev(0) = '0' then
            if state_num = 6 then state_num <= 0;
            else state_num <= state_num + 1;
            end if;
        end if;
        btn_prev(0) <= btn(0);
     end if;
end process Button_0;
        
Button_12: process(clk,rst)-- Parameter selection
begin
    if (rst = '1') then
        Kp_reg <= P_param;
        Ki_reg <= I_param;
        Kd_reg <= D_param;
        sel_temp <= setpoint_default;
        btn_prev(2 downto 1) <= "00";
        PID_freq_state <= 8;
    elsif rising_edge(clk)then                    
        if btn(1) = '1' and btn_prev(1) = '0' then
            case(state_num)is
            
                when 2 => 
                    if sel_temp < (temp_max * 10) then sel_temp <= sel_temp + 10;
                    else sel_temp <= 200; end if;
                    
                when 3 => 
                    if Kp_reg < 99900 then Kp_reg <= Kp_reg + 50;
                    else Kp_reg <= 0; end if;
                    
                 when 4 => 
                    if Ki_reg < 99900 then 
                        Ki_reg <= Ki_reg + 5;
                    else  
                        Ki_reg <= 0;
                    end if;
                    
                when 5 => 
                    if Kd_reg < 99900 then 
                        Kd_reg <= Kd_reg + 5;
                    else 
                        Kd_reg <= 0; end if;
                    
                when 6 => 
                    if PID_freq_state < 9 then PID_freq_state <= PID_freq_state + 1;
                    else PID_freq_state <= 9; end if;
                    
                when others =>NULL;
                end case;
        end if;
        btn_prev(1) <= btn(1);
        
        if btn(2) = '1' and btn_prev(2) = '0' then
            case(state_num)is
            
                when 2 => 
                    if sel_temp > 200 then sel_temp <= sel_temp - 10;
                    else sel_temp <= 200; end if;
                    
                when 3 => 
                    if Kp_reg > 50 then Kp_reg <= Kp_reg - 50;
                    else Kp_reg <= 0; end if;
                    
                when 4 => 
                    if Ki_reg > 5 then 
                        Ki_reg <= Ki_reg - 5;
                    else 
                        Ki_reg <= 0;
                    end if;
                    
                when 5 => 
                    if Kd_reg > 5 then Kd_reg <= Kd_reg - 5;
                    else Kd_reg <= 0; end if;
                    
                when 6 => 
                    if PID_freq_state > 1 then PID_freq_state <= PID_freq_state - 1;
                    else PID_freq_state <= 0; end if;
                    
                when others =>NULL;
                end case;
        end if;
        btn_prev(2) <= btn(2);
    end if;
      
end process Button_12;

Button_3: process(clk, rst) -- Confirm temperature setpoint 
    variable led_timer: integer range 0 to clk_freq := 0; 
begin
    if (rst = '1') then
        btn_prev(3) <= '0';
        setpoint_reg <= setpoint_default; 
        LED_RGB_0(1) <= '0';
        led_timer := 0;
        
    elsif rising_edge(clk) then
        
        if btn(3) = '1' and btn_prev(3) = '0' then
            if (state_num = 2) then
                setpoint_reg <= sel_temp;
                led_timer := 20000000; 
            end if;
        end if;
        
        if led_timer > 0 then
            LED_RGB_0(1) <= '1';       
            led_timer := led_timer - 1;
        else
            LED_RGB_0(1) <= '0';       
        end if;
        
        btn_prev(3) <= btn(3);
        
        if (state_num /= 2) then
             LED_RGB_0(1) <= '0'; 
             led_timer := 0;
        end if;                  
    end if;
end process Button_3;

Param_to_disp_0: process (clk) -- Displaying hundreds of parameters
begin
if(rst='1')then
    p_param_0 <= (others=>'0'); i_param_0 <= (others=>'0'); d_param_0 <= (others=>'0');
    sel_temp_0 <= (others=>'0'); 
elsif rising_edge(clk)then
    case(state_num) is 
        when 2 =>  sel_temp_0 <= std_logic_vector(to_unsigned(sel_temp / 1000, 5));
        when 3 =>  p_param_0 <= std_logic_vector(to_unsigned(Kp_reg / 10000, 5));
        when 4 =>  i_param_0 <= std_logic_vector(to_unsigned(Ki_reg / 10000, 5));
        when 5 =>  d_param_0 <= std_logic_vector(to_unsigned(Kd_reg / 10000, 5));
        when others => NULL;
    end case;            
  end if;                                                                                                                                                                             
  
end process Param_to_disp_0;

Param_to_disp_1: process (clk)-- Displaying tens of parameters
begin
if(rst='1')then
    p_param_1 <= (others=>'0'); i_param_1 <= (others=>'0'); d_param_1 <= (others=>'0');
    sel_temp_1 <= (others=>'0'); 
elsif rising_edge(clk)then

    case(state_num) is 
        when 2 => sel_temp_1 <= std_logic_vector(shift_right(to_unsigned(sel_temp/25,5),2));
        when 3 =>  p_param_1 <= std_logic_vector(to_unsigned(((Kp_reg mod 10000)/ 1000), 5));
        when 4 =>  i_param_1 <= std_logic_vector(to_unsigned(((Ki_reg mod 10000)/ 1000), 5));
        when 5 =>  d_param_1 <= std_logic_vector(to_unsigned(((Kd_reg mod 10000)/ 1000), 5));
        when others => NULL;
    end case;            
  end if;                                                                                                                                                                             
  
end process Param_to_disp_1;

Param_to_disp_2: process (clk)-- Displaying ones of parameters
begin
if(rst='1')then
    p_param_2 <= (others=>'0'); i_param_2 <= (others=>'0'); d_param_2 <= (others=>'0');
    sel_temp_2 <= (others=>'0'); 
elsif rising_edge(clk)then
    case(state_num) is 
        when 2 =>  sel_temp_2 <= std_logic_vector(to_unsigned((sel_temp mod 100)/10,5));
        when 3 =>  p_param_2 <= std_logic_vector(to_unsigned((Kp_reg mod 1000)/100,5));
        when 4 =>  i_param_2 <= std_logic_vector(to_unsigned((Ki_reg mod 1000)/100,5));
        when 5 =>  d_param_2 <= std_logic_vector(to_unsigned((Kd_reg mod 1000)/100,5));
        when others => NULL;
    end case;            
  end if;
  
end process Param_to_disp_2;

Param_to_disp_3: process (clk) -- Displaying tenths of parameters
begin
if(rst='1')then
    p_param_3 <= (others=>'0'); i_param_3 <= (others=>'0'); d_param_3 <= (others=>'0');
    sel_temp_3 <= (others=>'0'); 
elsif rising_edge(clk)then
    case(state_num) is 
        when 2 =>  sel_temp_3 <= std_logic_vector(to_unsigned((sel_temp mod 10),5));
        when 3 =>  p_param_3 <= std_logic_vector(to_unsigned((Kp_reg mod 100) / 10, 5));
        when 4 =>  i_param_3 <= std_logic_vector(to_unsigned((Ki_reg mod 100) / 10, 5));
        when 5 =>  d_param_3 <= std_logic_vector(to_unsigned((Kd_reg mod 100) / 10, 5));               
        when others => NULL;
    end case;            
  end if;
  
end process Param_to_disp_3;

Param_to_disp_4: process (clk) -- Displaying hundredths of parameters
begin
if(rst='1')then
    p_param_4 <= (others=>'0'); i_param_4 <= (others=>'0'); d_param_4 <= (others=>'0');
elsif rising_edge(clk)then

    case(state_num) is 
        when 3 =>  p_param_4 <= std_logic_vector(to_unsigned((Kp_reg mod 10),5));
        when 4 =>  i_param_4 <= std_logic_vector(to_unsigned((Ki_reg mod 10),5));
        when 5 =>  d_param_4 <= std_logic_vector(to_unsigned((Kd_reg mod 10),5));
        when others => NULL;
    end case;            
  end if;
  
end process Param_to_disp_4;

UART_ctrl: process(clk) --UART control process
    variable transmit_data_state: integer range 0 to 30 := 0;
begin
    if rst = '1' then
        uart_state_reg <= idle;
        tx_start_sig <= '0';
        din_sig <= (others => '0');
        transmit_data_state := 0;
        
    elsif rising_edge(clk) then

        tx_start_sig <= '0'; 
        
        case uart_state_reg is
            when idle =>
                if (uart_tick='1') then
                    din_sig <= x"AD";  
                    tx_start_sig <= '1';
                    transmit_data_state := 0;
                    uart_state_reg <= transmit_data;
                end if;
                
            when transmit_data => 
                if tx_done_sig = '1' then
                    if transmit_data_state < 27 then
                        
                        case transmit_data_state is
                            when 0 => din_sig <= std_logic_vector(to_signed(p_term_snap, 16)(15 downto 8));
                            when 1 => din_sig <= std_logic_vector(to_signed(p_term_snap, 16)(7 downto 0));
                            
                            when 2 => din_sig <= std_logic_vector(to_signed(i_term_snap, 32)(31 downto 24));
                            when 3 => din_sig <= std_logic_vector(to_signed(i_term_snap, 32)(23 downto 16));
                            when 4 => din_sig <= std_logic_vector(to_signed(i_term_snap, 32)(15 downto 8));
                            when 5 => din_sig <= std_logic_vector(to_signed(i_term_snap, 32)(7 downto 0));
                            
                            when 6 => din_sig <= std_logic_vector(to_signed(d_term_snap, 16)(15 downto 8));
                            when 7=> din_sig <= std_logic_vector(to_signed(d_term_snap, 16)(7 downto 0));
                            
                            when 8 => din_sig <= std_logic_vector(to_signed(control_in_snap, 16)(15 downto 8));
                            when 9 => din_sig <= std_logic_vector(to_signed(control_in_snap, 16)(7 downto 0));
                            
                            when 10 => din_sig <= std_logic_vector(resize(control_out_snap, 16)(15 downto 8));
                            when 11 => din_sig <= std_logic_vector(resize(control_out_snap, 16)(7 downto 0));
                            
                            when 12 => din_sig <= std_logic_vector(to_signed(setpoint_snap, 16)(15 downto 8));
                            when 13 => din_sig <= std_logic_vector(to_signed(setpoint_snap, 16)(7 downto 0));
                            
                            when 14 => din_sig <= std_logic_vector(to_signed(error_snap, 16)(15 downto 8));
                            when 15 => din_sig <= std_logic_vector(to_signed(error_snap, 16)(7 downto 0));
                            
                            when 16 => din_sig <= std_logic_vector(to_signed(PID_freq_snap, 16)(15 downto 8));
                            when 17 => din_sig <= std_logic_vector(to_signed(PID_freq_snap, 16)(7 downto 0));
                            
                            when 18 => din_sig <= "00000000";
                            when 19 => din_sig <= "0000000" & switch(0);
                            
                            when 20 => din_sig <= std_logic_vector(to_signed(Kp_snap, 16)(15 downto 8));
                            when 21 => din_sig <= std_logic_vector(to_signed(Kp_snap, 16)(7 downto 0));
                            
                            when 22 => din_sig <= std_logic_vector(to_signed(Ki_snap, 16)(15 downto 8));
                            when 23 => din_sig <= std_logic_vector(to_signed(Ki_snap, 16)(7 downto 0));
                            
                            when 24 => din_sig <= std_logic_vector(to_signed(Kd_snap, 16)(15 downto 8));
                            when 25 => din_sig <= std_logic_vector(to_signed(Kd_snap, 16)(7 downto 0));
                            
                            when 26 => din_sig <= x"DA";
                            
                            when others => NULL;
                        end case;
                        
                        tx_start_sig <= '1';
                        transmit_data_state := transmit_data_state + 1;
                        
                    else
                        uart_state_reg <= done;
                    end if;
                end if;
                
            when done =>
                uart_state_reg <= idle;
                
        end case;
    end if;
end process UART_ctrl;

PID_freq_ctrl: process(clk) --PID frequency selection process
begin
    if(rst='1')then
        pid_freq <= 30000;
        max_pid_count <= 3333;
    elsif rising_edge(clk)then
        case (pid_freq_state)is
            when 0 => PID_freq <= 1;     max_pid_count <= 100000000; --For testing purposes, not practical
            when 1 => PID_freq <= 10;    max_pid_count <= 10000000;
            when 2 => PID_freq <= 20;    max_pid_count <= 5000000;
            when 3 => PID_freq <= 50;    max_pid_count <= 2000000;
            when 4 => PID_freq <= 100;   max_pid_count <= 1000000; -- Beyond 50Hz impossible to tune with Z-N method
            when 5 => PID_freq <= 1000;  max_pid_count <= 100000;
            when 6 => PID_freq <= 5000;  max_pid_count <= 20000;
            when 7 => PID_freq <= 10000; max_pid_count <= 10000;
            when 8 => PID_freq <= 20000; max_pid_count <= 5000;
            when 9 => PID_freq <= 30000; max_pid_count <= 3333;
            when others => PID_freq <= 30000; max_pid_count <= 3333;
        end case;
    end if;
end process PID_freq_ctrl;

end Behavioral;
