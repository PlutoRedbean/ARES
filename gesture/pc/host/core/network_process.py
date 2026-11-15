import time
import socket
from utils.config import UDP_IP, UDP_PORT, BUFFER_SIZE

def network_loop(shared_state):
    """
    Process for handling UDP network communication.
    """
    print(f"Network Process started on {UDP_IP}:{UDP_PORT}")
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((UDP_IP, UDP_PORT))
    sock.setblocking(False)  # Non-blocking to allow checking shared_state.running
    
    print("UDP Socket bound. Waiting for data...")

    while shared_state.running:
        try:
            data, addr = sock.recvfrom(BUFFER_SIZE)
            decoded_data = data.decode('utf-8')
            
            if decoded_data == "CALIBRATE":
                print(f"[{addr[0]}:{addr[1]}] Calibration Triggered!")
                shared_state.trigger_calibration = True
            elif decoded_data.startswith("CONFIG,"):
                # CONFIG,KEY,VALUE
                try:
                    parts = decoded_data.split(',')
                    if len(parts) >= 3:
                        key = parts[1]
                        val = float(parts[2])
                        if key == "DODGE_SENSITIVITY":
                            # Slider 0-100. Default 25.0 -> Threshold 2.5
                            # We store the actual threshold value (Slider / 10.0)
                            shared_state.dodge_sensitivity = val / 10.0
                            print(f"Config Update: Dodge Threshold set to {shared_state.dodge_sensitivity:.2f}")
                except Exception as e:
                    print(f"Config Parse Error: {e}")
            elif decoded_data.startswith("DATA,"):
                # DEBUG: Print raw data to diagnose parsing issues
                # print(f"RAW PACKET: {decoded_data}")
                parts = decoded_data.split(',')
                # Expecting DATA,joyX,joyY,rotX,rotY,rotZ,rotW,accX,accY,accZ,buttons
                if len(parts) >= 11:
                    try:
                        shared_state.joy_x = float(parts[1])
                        shared_state.joy_y = float(parts[2])
                        shared_state.imu_x = float(parts[3])
                        shared_state.imu_y = float(parts[4])
                        shared_state.imu_z = float(parts[5])
                        shared_state.imu_w = float(parts[6])
                        shared_state.acc_x = float(parts[7])
                        shared_state.acc_y = float(parts[8])
                        shared_state.acc_z = float(parts[9])
                        shared_state.buttons = int(parts[10]) # Parse Generic Button Flags
                    except ValueError:
                        print(f"Error parsing packet: {decoded_data}")
                elif len(parts) >= 10: # Backward compatibility
                    try:
                        shared_state.joy_x = float(parts[1])
                        shared_state.joy_y = float(parts[2])
                        shared_state.imu_x = float(parts[3])
                        shared_state.imu_y = float(parts[4])
                        shared_state.imu_z = float(parts[5])
                        shared_state.imu_w = float(parts[6])
                        shared_state.acc_x = float(parts[7])
                        shared_state.acc_y = float(parts[8])
                        shared_state.acc_z = float(parts[9])
                    except ValueError:
                         pass
                elif len(parts) >= 7:
                    # Legacy support for older Android version if needed
                     try:
                        shared_state.joy_x = float(parts[1])
                        shared_state.joy_y = float(parts[2])
                        shared_state.imu_x = float(parts[3])
                        shared_state.imu_y = float(parts[4])
                        shared_state.imu_z = float(parts[5])
                        shared_state.imu_w = float(parts[6])
                     except ValueError:
                        pass
            else:
                print(f"[{addr[0]}:{addr[1]}] Received: {decoded_data}")
        except BlockingIOError:
            # No data received, sleep briefly to save CPU
            time.sleep(0.001) 
        except Exception as e:
            print(f"Network Error: {e}")
            
    print("Network Process stopped.")
    sock.close()
