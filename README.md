# FPGA Proportional-Integral-Derivative Controller

This controller was developed as part of my master's thesis. The system was designed primarily to regulate the temperature of an electric heater without active cooling, although it can be easily adapted to other processes.

The system implements a classic parallel PID algorithm with independent gain (K) adjustment for each term. The error is calculated as the difference between a 12-bit setpoint (selected by the user with buttons) and the 12-bit measured value read from an MCP3201 ADC over SPI. The integral term uses a simple numerical integration scheme with anti-windup limits on the accumulator, and the derivative term is based on a backward difference. The PID update frequency can be changed in real time. The weighted sum of the three terms is converted back to a 12-bit logic vector that represents the duty cycle of a 50 kHz PWM signal.

The output signal is then averaged by an RC DAC and fed to the controlled object. To observe live values such as the error, setpoint, output, individual PID terms, and the K parameters, UART communication with a PC over USB is implemented.

## Hardware platform
- Digilent Arty A7-100 (XC7A100TCSG324-1)
- Custom breakout board

## Known issues
The current version does not scale the gains by the integral and derivative time constants. When tuning the K parameters, this must be taken into account.
