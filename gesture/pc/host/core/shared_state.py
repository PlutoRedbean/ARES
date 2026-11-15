import multiprocessing
import ctypes

class SharedState:
    """
    Manages shared memory between processes.
    Uses multiprocessing.Value and Array for thread-safe access.
    """
    def __init__(self):
        # System State
        self._running = multiprocessing.Value(ctypes.c_bool, True)
        
        # CV Data - Hand Tracking
        self._hand_detected = multiprocessing.Value(ctypes.c_bool, False)
        # Coordinates usually normalized 0.0 to 1.0
        self._wrist_x = multiprocessing.Value(ctypes.c_double, 0.0)
        self._wrist_y = multiprocessing.Value(ctypes.c_double, 0.0)
        
        # Calibration Data
        self._calib_wrist_x = multiprocessing.Value(ctypes.c_double, 0.5)
        self._calib_wrist_y = multiprocessing.Value(ctypes.c_double, 0.5)
        self._trigger_calibration = multiprocessing.Value(ctypes.c_bool, False)
        self._is_gripped = multiprocessing.Value(ctypes.c_bool, False)
        
        # Settings
        self._dodge_sensitivity = multiprocessing.Value(ctypes.c_double, 2.5) # Default Threshold
        
        # Gestures
        self._arm_vel_x = multiprocessing.Value(ctypes.c_double, 0.0)
        self._arm_vel_y = multiprocessing.Value(ctypes.c_double, 0.0)
        self._is_raised = multiprocessing.Value(ctypes.c_bool, False)
        # Detailed Gesture Flags
        self._is_healing = multiprocessing.Value(ctypes.c_bool, False)
        self._is_shielding = multiprocessing.Value(ctypes.c_bool, False)
        self._is_parrying = multiprocessing.Value(ctypes.c_bool, False)
        self._is_dodging = multiprocessing.Value(ctypes.c_bool, False)

        # Network Data - Phone Controller
        self._joy_x = multiprocessing.Value(ctypes.c_double, 0.0)
        self._joy_y = multiprocessing.Value(ctypes.c_double, 0.0)
        # Rotation (Quaternion: x, y, z, w)
        self._imu_x = multiprocessing.Value(ctypes.c_double, 0.0)
        self._imu_y = multiprocessing.Value(ctypes.c_double, 0.0)
        self._imu_z = multiprocessing.Value(ctypes.c_double, 0.0)
        self._imu_w = multiprocessing.Value(ctypes.c_double, 1.0) # Identity w=1
        # Linear Acceleration
        self._acc_x = multiprocessing.Value(ctypes.c_double, 0.0)
        self._acc_y = multiprocessing.Value(ctypes.c_double, 0.0)
        self._acc_z = multiprocessing.Value(ctypes.c_double, 0.0)
        
        self._buttons = multiprocessing.Value(ctypes.c_int, 0)

    # --- System Properties ---
    @property
    def running(self):
        return self._running.value

    @running.setter
    def running(self, value):
        self._running.value = value

    # --- CV Properties ---
    @property
    def hand_detected(self):
        return self._hand_detected.value

    @hand_detected.setter
    def hand_detected(self, value):
        self._hand_detected.value = value

    @property
    def wrist_x(self):
        return self._wrist_x.value

    @wrist_x.setter
    def wrist_x(self, value):
        self._wrist_x.value = value

    @property
    def wrist_y(self):
        return self._wrist_y.value

    @wrist_y.setter
    def wrist_y(self, value):
        self._wrist_y.value = value
        
    @property
    def is_gripped(self):
        return self._is_gripped.value
    
    @is_gripped.setter
    def is_gripped(self, value):
        self._is_gripped.value = value

    @property
    def arm_vel_x(self): return self._arm_vel_x.value
    @arm_vel_x.setter
    def arm_vel_x(self, value): self._arm_vel_x.value = value

    @property
    def arm_vel_y(self): return self._arm_vel_y.value
    @arm_vel_y.setter
    def arm_vel_y(self, value): self._arm_vel_y.value = value

    @property
    def is_raised(self): return self._is_raised.value
    @is_raised.setter
    def is_raised(self, value): self._is_raised.value = value

    @property
    def is_healing(self): return self._is_healing.value
    @is_healing.setter
    def is_healing(self, value): self._is_healing.value = value
    
    @property
    def is_shielding(self): return self._is_shielding.value
    @is_shielding.setter
    def is_shielding(self, value): self._is_shielding.value = value

    @property
    def is_parrying(self): return self._is_parrying.value
    @is_parrying.setter
    def is_parrying(self, value): self._is_parrying.value = value

    @property
    def is_dodging(self): return self._is_dodging.value
    @is_dodging.setter
    def is_dodging(self, value): self._is_dodging.value = value

    # --- Network Properties ---
    @property
    def joy_x(self): return self._joy_x.value
    @joy_x.setter
    def joy_x(self, value): self._joy_x.value = value

    @property
    def joy_y(self): return self._joy_y.value
    @joy_y.setter
    def joy_y(self, value): self._joy_y.value = value

    @property
    def imu_x(self): return self._imu_x.value
    @imu_x.setter
    def imu_x(self, value): self._imu_x.value = value

    @property
    def imu_y(self): return self._imu_y.value
    @imu_y.setter
    def imu_y(self, value): self._imu_y.value = value

    @property
    def imu_z(self): return self._imu_z.value
    @imu_z.setter
    def imu_z(self, value): self._imu_z.value = value

    @property
    def imu_w(self): return self._imu_w.value
    @imu_w.setter
    def imu_w(self, value): self._imu_w.value = value

    @property
    def acc_x(self): return self._acc_x.value
    @acc_x.setter
    def acc_x(self, value): self._acc_x.value = value

    @property
    def acc_y(self): return self._acc_y.value
    @acc_y.setter
    def acc_y(self, value): self._acc_y.value = value

    @property
    def acc_z(self): return self._acc_z.value
    @acc_z.setter
    def acc_z(self, value): self._acc_z.value = value

    # --- Calibration properties ---
    @property
    def calib_wrist_x(self): return self._calib_wrist_x.value
    @calib_wrist_x.setter
    def calib_wrist_x(self, value): self._calib_wrist_x.value = value

    @property
    def calib_wrist_y(self): return self._calib_wrist_y.value
    @calib_wrist_y.setter
    def calib_wrist_y(self, value): self._calib_wrist_y.value = value

    @property
    def trigger_calibration(self): return self._trigger_calibration.value
    @trigger_calibration.setter
    def trigger_calibration(self, value): self._trigger_calibration.value = value

    # Buttons
    @property
    def buttons(self): return self._buttons.value
    @buttons.setter
    def buttons(self, value): self._buttons.value = value
    
    # Settings
    @property
    def dodge_sensitivity(self): return self._dodge_sensitivity.value
    @dodge_sensitivity.setter
    def dodge_sensitivity(self, value): self._dodge_sensitivity.value = value
