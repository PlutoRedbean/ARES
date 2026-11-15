import vgamepad as vg
import time

class VirtualController:
    def __init__(self):
        try:
            self.gamepad = vg.VX360Gamepad()
            print("Virtual Controller (Xbox 360) initialized.")
        except Exception as e:
            print(f"Failed to initialize Virtual Controller: {e}")
            print("Ensure ViGEmBus driver is installed (https://github.com/nefarius/ViGEmBus/releases)")
            self.gamepad = None

    def update(self, joy_x, joy_y, cam_x, cam_y, is_attacking, is_healing, is_shielding, is_parrying, is_dodging, buttons):
        """
        Update controller state.
        buttons: Bitmask (Bit 0=A, 1=B, 2=X, 3=Y, 4=Up, 5=Down, 6=Left, 7=Right)
        """
        if not self.gamepad:
            return

        # Map Floats (-1.0 to 1.0) to Int16 (-32768 to 32767)
        # Joystick (Left Stick)
        lx = int(joy_x * 32767)
        ly = int(joy_y * 32767) # Y might need inverting depending on game
        
        # Camera (Right Stick)
        rx = int(cam_x * 32767)
        ry = int(cam_y * 32767)

        self.gamepad.left_joystick(x_value=lx, y_value=ly)
        self.gamepad.right_joystick(x_value=rx, y_value=ry)



        # Map Heal (Grip + Raise) to X Button (OR via physical button below)
        # Note: If Physical Button X is pressed, it overlaps. 
        # But Heal is logically separate. Let's say Heal is always X.
        if is_healing:
            self.gamepad.press_button(button=vg.XUSB_BUTTON.XUSB_GAMEPAD_X)
        else:
             # Only release if Physical X is NOT pressed
             if not (buttons & (1 << 2)): 
                self.gamepad.release_button(button=vg.XUSB_BUTTON.XUSB_GAMEPAD_X)

        # --- Generic Buttons ---
        # A (Bit 0)
        if buttons & (1 << 0): self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_A)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_A)
        
        # B (Bit 1) + Dodge
        if is_dodging or (buttons & (1 << 1)): 
            self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_B)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_B)
        
        # X (Bit 2) - Managed above with Heal
        if buttons & (1 << 2): self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_X)
        
        # Y (Bit 3)
        if buttons & (1 << 3): self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_Y)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_Y)
        
        # D-Pad Up (Bit 4)
        if buttons & (1 << 4): self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_UP)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_UP)
        
        # D-Pad Down (Bit 5)
        if buttons & (1 << 5): self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_DOWN)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_DOWN)
        
        # D-Pad Left (Bit 6)
        if buttons & (1 << 6): self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_LEFT)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_LEFT)
        
        # D-Pad Right (Bit 7)
        if buttons & (1 << 7): self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_RIGHT)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_RIGHT)

        # Menu (Start) - Bit 8
        if buttons & (1 << 8): self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_START)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_START)

        # View (Back/Select) - Bit 9
        if buttons & (1 << 9): self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_BACK)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_BACK)

        # Share (Guide) - Bit 10
        if buttons & (1 << 10): self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_GUIDE)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_GUIDE)

        # L3 (Left Stick Click) - Bit 11
        if buttons & (1 << 11): self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_LEFT_THUMB)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_LEFT_THUMB)

        # R3 (Right Stick Click) - Bit 12
        if buttons & (1 << 12): self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_RIGHT_THUMB)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_RIGHT_THUMB)

        # LB (Left Bumper) - Bit 15 + Shield Block
        if is_shielding or (buttons & (1 << 15)): 
             self.gamepad.press_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_LEFT_SHOULDER)
        else: self.gamepad.release_button(vg.XUSB_BUTTON.XUSB_GAMEPAD_LEFT_SHOULDER)

        # RB (Right Bumper) - Bit 16 (Combined with is_attacking)
        if is_attacking or (buttons & (1 << 16)):
             self.gamepad.press_button(button=vg.XUSB_BUTTON.XUSB_GAMEPAD_RIGHT_SHOULDER)
        else:
             self.gamepad.release_button(button=vg.XUSB_BUTTON.XUSB_GAMEPAD_RIGHT_SHOULDER)

        # LT (Left Trigger) - Bit 17 + Parry
        if is_parrying or (buttons & (1 << 17)): 
            self.gamepad.left_trigger(value=255)
        else: 
            self.gamepad.left_trigger(value=0)

        # RT (Right Trigger) - Bit 18
        if buttons & (1 << 18): self.gamepad.right_trigger(value=255)
        else: self.gamepad.right_trigger(value=0)

        self.gamepad.update()

    def reset(self):
        if self.gamepad:
            self.gamepad.reset()
            self.gamepad.update()
