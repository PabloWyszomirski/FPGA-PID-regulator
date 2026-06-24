import serial
import struct
import time
import csv
import os
import sys
import threading
from collections import deque
import matplotlib.pyplot as plt
import matplotlib.animation as animation


def enable_ansi():
    if os.name == 'nt':
        try:
            import ctypes
            kernel32 = ctypes.windll.kernel32
            kernel32.SetConsoleMode(kernel32.GetStdHandle(-11), 7)
        except Exception:
            os.system('')


CLEAR = "\033[H\033[J"

BAUD_RATE = 230400

HEADER = 0xAD
FOOTER = 0xDA
PAYLOAD_LEN = 26
FRAME_LEN = 1 + PAYLOAD_LEN + 1

FRAME_FORMAT = '>h i 10h'
PWM_EN_OFFSET = 18

MAX_POINTS = 300
times_q = deque(maxlen=MAX_POINTS)
temps_q = deque(maxlen=MAX_POINTS)
setpoints_q = deque(maxlen=MAX_POINTS)
pwms_q = deque(maxlen=MAX_POINTS)

stats = {'ok': 0, 'dropped': 0, 'fps': 0.0}

running = True


def extract_frames(buf: bytearray):
    frames = []
    dropped = 0
    i = 0
    n = len(buf)

    while n - i >= FRAME_LEN:
        if buf[i] != HEADER:
            i += 1
            dropped += 1
            continue

        if buf[i + FRAME_LEN - 1] != FOOTER:
            i += 1
            dropped += 1
            continue

        payload = bytes(buf[i + 1: i + 1 + PAYLOAD_LEN])

        pwm_en = (payload[PWM_EN_OFFSET] << 8) | payload[PWM_EN_OFFSET + 1]
        if pwm_en > 1:
            i += 1
            dropped += 1
            continue

        frames.append(payload)
        i += FRAME_LEN

    if i:
        del buf[:i]

    return frames, dropped


def read_uart_loop(port_name):
    global running

    enable_ansi()

    try:
        ser = serial.Serial(port_name, BAUD_RATE, timeout=0.2)
        try:
            ser.set_buffer_size(rx_size=1 << 16)
        except Exception:
            pass
        print("Successfully connected to UART. Waiting for data...\n")
        time.sleep(1)
        ser.reset_input_buffer()
    except serial.SerialException as e:
        print(f"Connection error: {e}")
        running = False
        return

    buffer = bytearray()
    start_time = time.time()
    last_flush = time.time()
    fps_window_start = time.time()
    fps_count = 0

    with open('data.csv', mode='w', newline='', encoding='utf-8') as csv_file:
        csv_writer = csv.writer(csv_file)
        csv_writer.writerow(['Time_s', 'Temperature_C', 'Setpoint_C', 'PWM_%', 'PWM_EN',
                             'Error', 'P_term', 'I_term', 'D_term', 'Freq_Hz',
                             'Kp', 'Ki', 'Kd'])
        csv_writer.writerow(['s', '°C', '°C', '%', '-', '-', '-', '-', '-',
                             'Hz', '-', '-', '-'])

        try:
            while running:
                waiting = ser.in_waiting
                chunk = ser.read(waiting if waiting > 0 else 1)
                if not chunk:
                    continue
                buffer.extend(chunk)

                frames, dropped = extract_frames(buffer)
                stats['dropped'] += dropped

                for payload in frames:
                    try:
                        (p_term, i_term, d_term, ctrl_in, ctrl_out, setpoint,
                         error, pid_freq, pwm_enabled,
                         kp_raw, ki_raw, kd_raw) = struct.unpack(FRAME_FORMAT, payload)
                    except struct.error:
                        continue

                    stats['ok'] += 1
                    fps_count += 1

                    temp_celsius = ctrl_in / 10.0
                    setpoint_celsius = setpoint / 10.0
                    pwm_percent = (ctrl_out * 100.0) / 4095.0
                    kp_real, ki_real, kd_real = kp_raw, ki_raw, kd_raw

                    current_time = round(time.time() - start_time, 2)

                    times_q.append(current_time)
                    temps_q.append(temp_celsius)
                    setpoints_q.append(setpoint_celsius)
                    pwms_q.append(pwm_percent)

                    csv_writer.writerow([current_time, temp_celsius, setpoint_celsius,
                                         round(pwm_percent, 2), pwm_enabled, error,
                                         p_term, i_term, d_term, pid_freq,
                                         kp_real, ki_real, kd_real])

                    pwm_state = "ON " if pwm_enabled == 1 else "OFF"

                    sys.stdout.write(
                        f"{CLEAR}Current values:\n"
                        f"Time: {current_time:6.1f}s | Freq: {pid_freq:5d}Hz | PWM_SW: {pwm_state} | "
                        f"Temp: {temp_celsius:5.1f}°C | Set: {setpoint_celsius:5.1f}°C | "
                        f"PWM: {pwm_percent:5.1f}% | Error: {error:5d}\n"
                        f"P_term: {p_term:6d} | I_term: {i_term:8d} | D_term: {d_term:6d} | "
                        f"Kp: {kp_real:5.2f} | Ki: {ki_real:5.2f} | Kd: {kd_real:5.2f}\n"
                        f"\n[Link] OK: {stats['ok']:7d} | Dropped bytes: {stats['dropped']:6d} "
                        f"| Frames/s: {stats['fps']:6.1f}\n"
                    )
                    sys.stdout.flush()

                now = time.time()

                if now - fps_window_start >= 1.0:
                    stats['fps'] = fps_count / (now - fps_window_start)
                    fps_count = 0
                    fps_window_start = now

                if now - last_flush > 0.25:
                    csv_file.flush()
                    last_flush = now

        except Exception as e:
            print(f"\nError in UART thread: {e}")
        finally:
            csv_file.flush()
            ser.close()
            running = False
            print("Serial port closed. Data saved to 'data.csv'.")


def animate(i, ax1, ax2, line_temp, line_sp, line_pwm):
    if len(times_q) == 0:
        return line_temp, line_sp, line_pwm

    t = list(times_q)
    y_temp = list(temps_q)
    y_sp = list(setpoints_q)
    y_pwm = list(pwms_q)

    line_temp.set_data(t, y_temp)
    line_sp.set_data(t, y_sp)
    line_pwm.set_data(t, y_pwm)

    ax1.set_xlim(max(0, t[-1] - 30), t[-1] + 5)
    min_t = min(min(y_temp), min(y_sp)) - 5
    max_t = max(max(y_temp), max(y_sp)) + 5
    ax1.set_ylim(min_t, max_t)

    return line_temp, line_sp, line_pwm


def main():
    global running

    user_input = input("Enter the active port, press Enter to use the default COM6: ").strip()
    PORT = user_input if user_input else 'COM6'

    print(f"Starting program for port {PORT}. Close the plot window to exit...")

    uart_thread = threading.Thread(target=read_uart_loop, args=(PORT,))
    uart_thread.daemon = True
    uart_thread.start()

    fig, ax1 = plt.subplots(figsize=(10, 6))
    fig.canvas.manager.set_window_title('PID controller - parameters')

    ax1.set_xlabel('Time [s]')
    ax1.set_ylabel('Temperature [°C]')
    ax1.grid(True)

    ax2 = ax1.twinx()
    ax2.set_ylabel('Control signal PWM [%]')
    ax2.set_ylim(-5, 105)

    line_temp, = ax1.plot([], [], 'r-', label='Temperature [°C]', linewidth=2)
    line_sp, = ax1.plot([], [], 'g--', label='Setpoint [°C]', linewidth=2)
    line_pwm, = ax2.plot([], [], 'b-', label='PWM duty cycle [%]', alpha=0.6)

    lines = [line_temp, line_sp, line_pwm]
    labels = [l.get_label() for l in lines]
    ax1.legend(lines, labels, loc='upper left')

    ani = animation.FuncAnimation(
        fig, animate, fargs=(ax1, ax2, line_temp, line_sp, line_pwm),
        interval=100, blit=False, cache_frame_data=False)

    try:
        plt.show()
    except KeyboardInterrupt:
        pass
    finally:
        running = False
        uart_thread.join(timeout=2)
        print("Application closed.")


if __name__ == '__main__':
    main()