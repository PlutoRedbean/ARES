import time
import pytest
import sys
import os
from unittest.mock import MagicMock

# Add core to path
sys.path.append(os.path.join(os.path.dirname(__file__), '..'))

from core.shared_state import SharedState
from core.virtual_controller import VirtualController

def test_shared_state_latency():
    """Measure overhead of SharedMemory (Multiprocessing Values)"""
    state = SharedState()
    
    start_time = time.perf_counter()
    state.joy_x = 0.5
    state.joy_y = -0.5
    read_x = state.joy_x
    read_y = state.joy_y
    end_time = time.perf_counter()
    
    latency_ms = (end_time - start_time) * 1000
    print(f"\nShared Memory R/W Latency: {latency_ms:.4f}ms")
    
    assert read_x == 0.5
    assert read_y == -0.5
    assert latency_ms < 0.1, "Shared state access should be sub-0.1ms"

def test_controller_update_latency():
    """Measure logic time for controller update"""
    controller = VirtualController()
    
    # If driver not installed, VirtualController handles exception and sets gamepad=None
    # We mock it to test logic speed
    if controller.gamepad is None:
        controller.gamepad = MagicMock()
        
    state = SharedState()
    state.joy_x = 1.0
    state.joy_y = 0.0
    state.wrist_x = 0.5
    state.wrist_y = 0.5
    
    start_time = time.perf_counter()
    
    # Simulate the mapped logic
    # Calculate inputs
    jx = state.joy_x
    jy = state.joy_y
    cx = (state.wrist_x - 0.5) * 2
    cy = (state.wrist_y - 0.5) * 2
    grip = state.is_gripped
    
    controller.update(jx, jy, cx, cy, grip)
    
    end_time = time.perf_counter()
    
    latency_ms = (end_time - start_time) * 1000
    print(f"Controller Update (Logic+Vigembus) Latency: {latency_ms:.4f}ms")
    
    # ViGEmBus calls might take ~1-2ms, Python logic is negligible
    assert latency_ms < 5.0, "Controller update loop is too slow!"
