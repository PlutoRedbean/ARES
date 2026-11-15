import multiprocessing
import time
import sys
import os
import math

# Ensure pc_host is in path
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

from core.shared_state import SharedState
from core.network_process import network_loop
from core.cv_process import cv_loop
from core.virtual_controller import VirtualController

def get_euler_angles(q):
    """
    Convert quaternion (x, y, z, w) to Euler angles (roll, pitch, yaw) in radians.
    Standard sequence.
    """
    x, y, z, w = q
    
    # Roll (x-axis rotation)
    sinr_cosp = 2 * (w * x + y * z)
    cosr_cosp = 1 - 2 * (x * x + y * y)
    roll = math.atan2(sinr_cosp, cosr_cosp)
    
    # Pitch (y-axis rotation)
    sinp = 2 * (w * y - z * x)
    # Clamp to avoid numerical errors
    if abs(sinp) >= 1:
        pitch = math.copysign(math.pi / 2, sinp)
    else:
        pitch = math.asin(sinp)
        
    # Yaw (z-axis rotation)
    siny_cosp = 2 * (w * z + x * y)
    cosy_cosp = 1 - 2 * (y * y + z * z)
    yaw = math.atan2(siny_cosp, cosy_cosp)
    
    return roll, pitch, yaw

def main():
    print("Starting Immersive Controller PC Host...")
    
    # Initialize Shared State
    shared_state = SharedState()
    
    # Create processes
    # We use multiprocessing to keep CV (heavy CPU) separate from Network (I/O bound/Latency sensitive)
    p_network = multiprocessing.Process(target=network_loop, args=(shared_state,))
    p_cv = multiprocessing.Process(target=cv_loop, args=(shared_state,))
    
    # Initialize Virtual Controller
    controller = VirtualController()
    
    # Start Processes
    p_network.start()
    p_cv.start()
    
    # Performance Monitoring
    loop_times = []
    avg_latency = 0.0
    
    # Gyro State
    calib_yaw = 0.0
    calib_pitch = 0.0
    
    # Config
    # GYRO_SENSITIVITY: Multiplier for angle delta. 
    # Lowered values for less aggressive movement.
    GYRO_SENS_X = 2.0 
    GYRO_SENS_Y = 3.0 
    DEADZONE = 0.06

    try:
        while True:
            start_time = time.time()
            
            # --- 1. Map Inputs ---
            
            # A. Left Joystick (Movement) - Direct from Touchscreen
            jx = shared_state.joy_x
            jy = -shared_state.joy_y # Invert Y for standard games

            # B. Right Joystick (Camera) - From IMU (Gyro)
            # 1. Get Quaternion
            q = (shared_state.imu_x, shared_state.imu_y, shared_state.imu_z, shared_state.imu_w)
            
            # 2. Convert to Euler
            roll, pitch, yaw = get_euler_angles(q)
            
            # 3. Handle Calibration
            # If trigger flag is set (by Network 'CALIBRATE' packet) OR first run (checking if 0.0)
            if shared_state.trigger_calibration:
                calib_yaw = yaw
                calib_pitch = pitch
                # Let the CV process know we handled it (it might also use it for hand position reset)
                # But we don't clear the flag here immediately if CV needs it. 
                # Actually, CV process clears it. Let's just read it.
                # To prevent race condition, we can just update our local calib constantly while it's true.
                pass 
                
            # 4. Calculate Deltas
            
            # Calculate shortest angular distance for Yaw
            diff_x = yaw - calib_yaw
            # Wrap to -PI to PI
            if diff_x > math.pi: diff_x -= 2*math.pi
            if diff_x < -math.pi: diff_x += 2*math.pi
            
            # Pitch usually doesn't wrap in normal usage
            diff_y = pitch - calib_pitch
            
            # 5. Apply Sensitivity & Curve
            # Invert checks:
            # - Yaw: -diff_x * Sens (Inverted Yaw)
            # - Pitch: diff_y * Sens (Inverted from previous state to matching user request 'Phone Up -> Look Down')
            
            raw_cx = -diff_x * GYRO_SENS_X 
            raw_cy = diff_y * GYRO_SENS_Y # REMOVED negative sign to invert axis
            
            # Deadzone
            # Apply deadzone to raw deltas before sensitivity or after? 
            # Applying after sensitivity calculation allows consistent "stick output" logic.
            if abs(raw_cx) < DEADZONE: raw_cx = 0
            elif raw_cx > 0: raw_cx -= DEADZONE
            else: raw_cx += DEADZONE
            
            if abs(raw_cy) < DEADZONE: raw_cy = 0
            elif raw_cy > 0: raw_cy -= DEADZONE
            else: raw_cy += DEADZONE
            
            # Rescale after deadzone subtration to regain range 0..1 (Optional, but good for feel)
            # For now, just clamping is enough as sensitivity is high.
            
            # Clamp
            raw_cx = max(-1.0, min(1.0, raw_cx))
            raw_cy = max(-1.0, min(1.0, raw_cy))
            
            # Square Curve (Preserve Sign)
            cx = math.copysign(raw_cx ** 2, raw_cx)
            cy = math.copysign(raw_cy ** 2, raw_cy)

            # --- Gesture Logic ---
            # 1. Attack = Phone Swung Down (Acceleration)
            # Threshold of -30.0 m/s^2 is a strong swing.
            is_attacking = (shared_state.acc_y < -30.0) or (shared_state.acc_z < -30.0)

            # 2. Heal = Grip + Raised (Computed in CV Process)
            is_healing = shared_state.is_healing
            
            # 3. Shield = Left Arm Elevated + Flexed
            is_shielding = shared_state.is_shielding
            
            # 4. Parry = Left Arm Flick Out
            is_parrying = shared_state.is_parrying
            
            # 5. Dodge = Head Flick
            is_dodging = shared_state.is_dodging
            
            # 6. Buttons (Bitmask)
            buttons = shared_state.buttons
            is_clutch_held = (buttons & (1 << 14))

            # --- UX: Clutch Logic ---
            # If "Hold to Aim" button is NOT held, we do not look around.
            if not is_clutch_held:
                 cx = 0.0
                 cy = 0.0

            # --- UX: Attack Stabilization ---
            if is_attacking:
                cx = 0.0 # Lock camera during swing
                cy = 0.0
                
            # --- 2. Update Controller ---
            if controller:
                controller.update(jx, jy, cx, cy, is_attacking, is_healing, is_shielding, is_parrying, is_dodging, buttons)

            # --- 3. Performance Calc ---
            elapsed = (time.time() - start_time) * 1000 # ms
            loop_times.append(elapsed)
            if len(loop_times) >= 100:
                avg_latency = sum(loop_times) / len(loop_times)
                loop_times = []

            # --- 4. Status Display ---
            # Debug Euler angles to help user orientation
            display_yaw = math.degrees(yaw)
            display_pitch = math.degrees(pitch)
            status_line = f"\rLat: {avg_latency:.2f}ms | Yaw:{display_yaw:.0f} Pitch:{display_pitch:.0f} | Cam:({cx:.2f}, {cy:.2f}) | Atk: {is_attacking} | Shld: {is_shielding} | Pry: {is_parrying} | Dge: {is_dodging}"
            print(f"{status_line:<130}", end="") 
            time.sleep(0.001)

    except KeyboardInterrupt:
        print("\nStopping...")
        shared_state.running = False
        
    # Join processes
    p_network.join()
    p_cv.join()
    print("System Shutdown Complete.")

if __name__ == "__main__":
    main()
