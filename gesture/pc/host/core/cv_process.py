import time
import math
import cv2
import mediapipe as mp
from utils.config import CAMERA_INDEX, FRAME_WIDTH, FRAME_HEIGHT

def cv_loop(shared_state):
    """
    Process for handling Computer Vision (MediaPipe) tasks.
    """
    print(f"CV Process started using camera index {CAMERA_INDEX}")

    mp_hands = mp.solutions.hands
    mp_pose = mp.solutions.pose
    mp_drawing = mp.solutions.drawing_utils

    # Initialize MediaPipe Hands
    hands = mp_hands.Hands(
        model_complexity=1,
        max_num_hands=2,
        min_detection_confidence=0.7,
        min_tracking_confidence=0.5
    )

    # Initialize MediaPipe Pose (for Arm Tracking)
    pose = mp_pose.Pose(
        model_complexity=0,
        min_detection_confidence=0.5,
        min_tracking_confidence=0.5
    )

    cap = cv2.VideoCapture(CAMERA_INDEX)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, FRAME_WIDTH)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, FRAME_HEIGHT)

    if not cap.isOpened():
        print(f"Error: Could not open webcam at index {CAMERA_INDEX}.")
        return

    print("MediaPipe Hands & Pose initialized. Starting loop...")

    # Velocity Tracking
    prev_wrist_x = 0.5
    prev_wrist_y = 0.5
    prev_l_wrist_x = 0.5 # For Left Hand (Parry)
    prev_time = time.time()
    
    # Head Tracking (Dodge - Duck/Squat)
    prev_nose_y = 0.5
    
    heal_end_time = 0.0
    parry_end_time = 0.0 
    parry_cooldown_time = 0.0 
    
    dodge_end_time = 0.0
    dodge_cooldown_time = 0.0
    
    # Track grip state globally for conflict resolution
    left_hand_gripped = False

    while shared_state.running:
        success, image = cap.read()
        if not success:
            print("Ignoring empty camera frame.")
            continue

        curr_time = time.time()
        dt = curr_time - prev_time
        prev_time = curr_time

        # Flip image (Mirror View)
        image = cv2.flip(image, 1)
        image_rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
        image_rgb.flags.writeable = False
        
        # Run Inference
        results_hands = hands.process(image_rgb)
        results_pose = pose.process(image_rgb)

        image_rgb.flags.writeable = True
        image = cv2.cvtColor(image_rgb, cv2.COLOR_RGB2BGR)
        
        h, w, _ = image.shape
        pose_landmarks = results_pose.pose_landmarks.landmark if results_pose.pose_landmarks else None
        
        # Helper for Pose Coords
        def get_pose_pt(idx):
            if not pose_landmarks: return None, 0.0
            lm = pose_landmarks[idx]
            return (int(lm.x * w), int(lm.y * h)), lm.visibility

        # --- Hand Processing ---
        healing_detected = False
        right_hand_found = False
        left_hand_gripped = False # Reset per frame
        arm_debug_status = [] 
        
        if results_hands.multi_hand_landmarks:
            for hand_landmarks, handedness in zip(results_hands.multi_hand_landmarks, results_hands.multi_handedness):
                label = handedness.classification[0].label # "Left" or "Right"
                
                # Basic Info
                wrist = hand_landmarks.landmark[mp_hands.HandLandmark.WRIST]
                
                # Grip Detection (Finger Curl)
                fingers_curled = 0
                if hand_landmarks.landmark[8].y > hand_landmarks.landmark[6].y: fingers_curled += 1 
                if hand_landmarks.landmark[12].y > hand_landmarks.landmark[10].y: fingers_curled += 1 
                if hand_landmarks.landmark[16].y > hand_landmarks.landmark[14].y: fingers_curled += 1 
                is_gripped = fingers_curled >= 2 

                # Arm Viz (Linked to Hand)
                if pose_landmarks:
                    pose_l_pt, _ = get_pose_pt(15)
                    pose_r_pt, _ = get_pose_pt(16)
                    cx, cy = int(wrist.x * w), int(wrist.y * h)
                    
                    dist_l = math.hypot(cx - pose_l_pt[0], cy - pose_l_pt[1]) if pose_l_pt else 9999
                    dist_r = math.hypot(cx - pose_r_pt[0], cy - pose_r_pt[1]) if pose_r_pt else 9999
                    
                    chain_indices = [11, 13, 15] if dist_l < dist_r else [12, 14, 16]
                    color = (255, 255, 0) if label == "Left" else (255, 0, 255)
                    
                    p1, v1 = get_pose_pt(chain_indices[0])
                    p2, v2 = get_pose_pt(chain_indices[1])
                    p3, v3 = get_pose_pt(chain_indices[2])
                    
                    if v1 > 0.5 and v2 > 0.5: cv2.line(image, p1, p2, color, 3)
                    if v2 > 0.5 and v3 > 0.5: cv2.line(image, p2, p3, color, 3)
                    arm_debug_status.append(f"{label[0]}Arm")

                # Action Logic
                is_raised = wrist.y < 0.45

                if label == "Left":
                    left_hand_gripped = is_gripped # Store for Shield Logic
                    
                    # Left Hand -> Heal (Must be strictly Left Side for safety)
                    if wrist.x < 0.6: 
                        if is_gripped and is_raised:
                            healing_detected = True
                        
                elif label == "Right":
                    # Right Hand -> Camera
                    if wrist.x > 0.4:
                        shared_state.wrist_x = wrist.x
                        shared_state.wrist_y = wrist.y
                        shared_state.is_gripped = is_gripped
                        shared_state.is_raised = is_raised 
                        
                        # Velocity (Right Hand)
                        if dt > 0:
                            vx = (wrist.x - prev_wrist_x) / dt
                            vy = (wrist.y - prev_wrist_y) / dt
                        else: vx, vy = 0, 0
                        
                        shared_state.arm_vel_x = vx
                        shared_state.arm_vel_y = vy
                        
                        prev_wrist_x = wrist.x
                        prev_wrist_y = wrist.y
                        right_hand_found = True

                # Debug Draw
                mp_drawing.draw_landmarks(image, hand_landmarks, mp_hands.HAND_CONNECTIONS)
                cx_l, cy_l = int(wrist.x * w), int(wrist.y * h)
                cv2.putText(image, f"{label} G:{fingers_curled}", (cx_l, cy_l - 10), 
                           cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 0), 1)

        # --- Dodge Scan (Head Motion) ---
        # Target: Nose (Index 0)
        # Motion: Rapid Downward Movement (Y velocity > Threshold)
        dodge_triggered = False
        nose_vel_y = 0.0
        
        if pose_landmarks:
            lm_nose = pose_landmarks[0]
            if lm_nose.visibility > 0.5:
                if dt > 0:
                    nose_vel_y = (lm_nose.y - prev_nose_y) / dt
                
                prev_nose_y = lm_nose.y
                
                # Threshold: Dynamic from Settings
                thresh = shared_state.dodge_sensitivity
                
                # Check for rapid DOWNWARD movement (Y+ direction)
                if (nose_vel_y > thresh) and (curr_time > dodge_cooldown_time):
                    dodge_triggered = True
                    dodge_end_time = curr_time + 0.1 # Pulse 100ms
                    dodge_cooldown_time = curr_time + 0.5 # Cooldown 500ms
                    print(f"DODGE! VelY: {nose_vel_y:.2f} (Thresh: {thresh:.1f})")

        is_dodging = (curr_time < dodge_end_time) or dodge_triggered
        shared_state.is_dodging = is_dodging


        # --- Parry Logic (Left Arm Flick) ---
        parry_triggered = False
        l_vel_x = 0.0
        
        if pose_landmarks:
             lm_l_wr = pose_landmarks[16] # Model Right (Phys Left)
             
             if lm_l_wr.visibility > 0.5:
                 # Calculate Velocity
                 if dt > 0:
                     l_vel_x = (lm_l_wr.x - prev_l_wrist_x) / dt
                 
                 prev_l_wrist_x = lm_l_wr.x
                 
                 # Check Trigger
                 if (l_vel_x < -2.5) and (curr_time > parry_cooldown_time):
                     parry_triggered = True
                     parry_end_time = curr_time + 0.1 # Pulse for 100ms
                     parry_cooldown_time = curr_time + 0.4 # Cooldown 400ms 
                     print(f"PARRY! Vel: {l_vel_x:.2f}")

        is_parrying = (curr_time < parry_end_time) or parry_triggered
        shared_state.is_parrying = is_parrying

        # --- Shield Block ---
        shielding_active = False
        if pose_landmarks:
            lm_nose = pose_landmarks[0]
            lm_shield_wr = pose_landmarks[16] # Model Right (Phys Left)
            lm_shield_el = pose_landmarks[14] 
            lm_shield_sh = pose_landmarks[12] 
            
            # Check visibility
            if (lm_shield_wr.visibility > 0.5 and lm_shield_el.visibility > 0.5):
                
                # Check 1: Height Constraint (Hand BELOW Head)
                if lm_shield_wr.y > lm_nose.y:
                    
                    # Check 2: Flexion (Angle < 90)
                    v1_x, v1_y = lm_shield_sh.x - lm_shield_el.x, lm_shield_sh.y - lm_shield_el.y
                    v2_x, v2_y = lm_shield_wr.x - lm_shield_el.x, lm_shield_wr.y - lm_shield_el.y
                    mag1 = math.sqrt(v1_x**2 + v1_y**2)
                    mag2 = math.sqrt(v2_x**2 + v2_y**2)
                    
                    if mag1 > 0 and mag2 > 0:
                        dot = (v1_x * v2_x) + (v1_y * v2_y)
                        angle = math.degrees(math.acos(max(-1.0, min(1.0, dot / (mag1 * mag2)))))
                        
                        if angle < 90.0:
                            shielding_active = True
                            
        shared_state.is_shielding = shielding_active

        # De-bounce Heal
        if healing_detected: heal_end_time = curr_time + 0.5
        is_healing_stable = curr_time < heal_end_time
        
        shared_state.is_healing = is_healing_stable
        shared_state.hand_detected = right_hand_found
        
        if not right_hand_found:
             shared_state.arm_vel_x = 0
             shared_state.arm_vel_y = 0

        # Calibration
        if shared_state.trigger_calibration and right_hand_found:
            shared_state.calib_wrist_x = shared_state.wrist_x
            shared_state.calib_wrist_y = shared_state.wrist_y
            shared_state.trigger_calibration = False

        # HUD
        arm_status = " ".join(arm_debug_status) if arm_debug_status else "None"
        status_text = f"Heal:{shared_state.is_healing} Shld:{shared_state.is_shielding} Pry:{shared_state.is_parrying} Dge:{shared_state.is_dodging} | Cam:{right_hand_found}"
        cv2.putText(image, status_text, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 0), 2)
        
        cx_c = int(shared_state.calib_wrist_x * w)
        cy_c = int(shared_state.calib_wrist_y * h)
        cv2.circle(image, (cx_c, cy_c), 10, (255, 0, 0), 2)

        cv2.imshow('Immersive Controller - CV Debug', image)
        if cv2.waitKey(5) & 0xFF == 27:
            shared_state.running = False

    cap.release()
    cv2.destroyAllWindows()
    hands.close()
    pose.close()
    print("CV Process stopped.")
