#!/usr/bin/env python3
"""Run ARES on a live HDMI capture card or replay every frame of a recording."""
import argparse
from dataclasses import dataclass
import json
import sys
from threading import Condition, Event, Thread
from time import monotonic

from gestures import Confirmation, LABELS, UNKNOWN, classify
from motion import MotionFeed

VIDEO_TIMEOUT = 0.5


@dataclass
class Frame:
    number: int
    seconds: float
    image: object
    epoch: int = 0


class LiveCamera:
    """Only the capture thread touches VideoCapture. Keep one newest frame."""
    def __init__(self, index):
        self.origin = monotonic()
        self.index = index
        self.changed = Condition()
        self.stop = Event()
        self.frame = None
        self.epoch = 0

    def capture(self):
        import cv2
        number = 0
        while not self.stop.is_set():
            cap = cv2.VideoCapture(self.index)
            try:
                if cap.isOpened():
                    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
                    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
                    cap.set(cv2.CAP_PROP_FPS, 30)
                    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
                last = None
                while cap.isOpened() and not self.stop.is_set():
                    ok, image = cap.read()
                    if not ok:
                        break
                    now = monotonic()
                    with self.changed:
                        if last is not None and now - last >= VIDEO_TIMEOUT:
                            self.epoch += 1
                        self.frame = Frame(number, now - self.origin, image, self.epoch)
                        number += 1
                        last = now
                        self.changed.notify()
            except cv2.error as error:
                print(f"Capture device {self.index}: {error}", file=sys.stderr)
            finally:
                cap.release()
            with self.changed:
                self.epoch += 1
                self.frame = None
                self.changed.notify()
            self.stop.wait(VIDEO_TIMEOUT)

    def is_current(self, frame):
        with self.changed:
            return (frame.epoch == self.epoch and self.frame is not None and
                    monotonic() - self.origin - self.frame.seconds < VIDEO_TIMEOUT)

    def frames(self):
        last_number = -1
        last_epoch = self.epoch
        expired = False
        reader = Thread(target=self.capture, daemon=True)
        reader.start()
        try:
            while True:
                with self.changed:
                    timeout = VIDEO_TIMEOUT
                    if self.frame is not None and not expired:
                        timeout = max(0, self.origin + self.frame.seconds + VIDEO_TIMEOUT - monotonic())
                    self.changed.wait_for(
                        lambda: self.epoch != last_epoch or
                        (self.frame is not None and self.frame.number != last_number),
                        timeout=timeout)
                    frame = self.frame
                    last_epoch = self.epoch
                    if frame is not None and frame.number == last_number:
                        frame = None
                    if frame is not None:
                        last_number = frame.number
                        if monotonic() - self.origin - frame.seconds >= VIDEO_TIMEOUT:
                            frame = None
                    expired = frame is None
                yield frame
        finally:
            self.stop.set()
            reader.join(timeout=1)


def replay(path):
    import cv2
    cap = cv2.VideoCapture(path)
    try:
        if not cap.isOpened():
            raise OSError(f"Cannot open video {path}")
        number = 0
        while True:
            ok, image = cap.read()
            if not ok:
                return
            yield Frame(number, cap.get(cv2.CAP_PROP_POS_MSEC) / 1000, image)
            number += 1
    finally:
        cap.release()


def infer(frame, hands, pose, shield_side, draw, log_landmarks):
    import cv2
    import mediapipe as mp
    image = cv2.flip(frame.image, 1)
    rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
    rgb.flags.writeable = False
    hand_result = hands.process(rgb)
    pose_result = pose.process(rgb)
    pose_lms = pose_result.pose_landmarks
    height, width = image.shape[:2]
    joints = [(p.x * width, p.y * height, p.visibility)
              for p in pose_lms.landmark] if pose_lms else []
    hand_points = [[(p.x, p.y, p.z) for p in h.landmark]
                   for h in hand_result.multi_hand_world_landmarks or []]
    raw = classify(joints, hand_points, shield_side)

    hand_images = hand_result.multi_hand_landmarks or []
    if draw:
        drawing = mp.solutions.drawing_utils
        if pose_lms:
            drawing.draw_landmarks(image, pose_lms, mp.solutions.pose.POSE_CONNECTIONS)
        for hand in hand_images:
            drawing.draw_landmarks(image, hand, mp.solutions.hands.HAND_CONNECTIONS)
    details = {}
    if log_landmarks:
        details = {"size": [width, height], "pose_px": joints,
                   "hands": [{"side": side.classification[0].label, "world": world,
                              "image": [(p.x, p.y, p.z) for p in hand.landmark]}
                             for hand, side, world in zip(hand_images,
                                 hand_result.multi_handedness or [], hand_points)]}
    return raw, image, details


def display(image, stable, raw, motion):
    import cv2
    h, w = image.shape[:2]
    text = f"{LABELS[stable]}  raw={LABELS[raw]}"
    if motion:
        for col, row in motion.mirrored_tiles():
            cv2.rectangle(image, (col*w//16, row*h//9),
                          ((col+1)*w//16-1, (row+1)*h//9-1), (0, 180, 255), 2)
        text += f"  M1 #{motion.seq} mean={motion.mean} blocks={motion.count}"
    cv2.putText(image, text, (12, 32), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 80), 2)
    cv2.imshow("ARES HDMI", image)
    return (cv2.waitKey(1) & 255) in (27, ord("q"))


def emit(frame, seconds, raw, stable, event, **details):
    print(json.dumps(dict(frame=frame, t=round(seconds, 6), raw=raw, stable=stable,
                          event=event, **details), separators=(",", ":")), flush=True)


def run(args):
    import cv2
    import mediapipe as mp
    import numpy as np
    camera = LiveCamera(args.camera) if args.video is None else None
    source = camera.frames() if camera else replay(args.video)
    motion = MotionFeed()
    serial_thread = motion.start(args.serial) if args.serial else None
    confirm = Confirmation()
    start = camera.origin if camera else monotonic()
    last_time = 0
    epoch = None
    lost = False
    try:
        # The full Pose model ships in the pinned wheel, also usable offline.
        with mp.solutions.hands.Hands(max_num_hands=2, model_complexity=1,
                min_detection_confidence=0.7, min_tracking_confidence=0.5) as hands, \
             mp.solutions.pose.Pose(model_complexity=1) as pose:
            for frame in source:
                if frame is None:
                    if not lost:
                        confirm.update(UNKNOWN)
                        emit(None, monotonic() - start, UNKNOWN, UNKNOWN, "video_lost")
                    lost = True
                    if not args.headless and display(np.zeros((360, 640, 3), np.uint8),
                                                     UNKNOWN, UNKNOWN, None):
                        break
                    continue
                if frame.epoch != epoch or lost:
                    confirm.update(UNKNOWN)
                    if epoch is not None or lost:
                        hands.reset()
                        pose.reset()
                    epoch = frame.epoch
                inference_start = monotonic()
                raw, image, details = infer(frame, hands, pose, args.shield_side,
                                            not args.headless, args.landmarks)
                # Disconnection during inference invalidates even this in-flight result.
                if camera and not camera.is_current(frame):
                    raw = UNKNOWN
                lost = False
                stable = confirm.update(raw)
                last_time = frame.seconds
                now = monotonic()
                details["inference_ms"] = round(1000 * (now - inference_start), 2)
                if camera:
                    details["capture_to_result_ms"] = round(1000 * (now - start - frame.seconds), 2)
                summary = motion.current(now)
                if summary:
                    details["motion"] = dict(seq=summary.seq, mean_diff=summary.mean,
                                             active_count=summary.count, mask_hex=summary.mask.hex())
                emit(frame.number, last_time, raw, stable, "frame", **details)
                if not args.headless and display(image, stable, raw, summary):
                    break
    finally:
        emit(None, monotonic() - start if camera else last_time, UNKNOWN, UNKNOWN, "end")
        source.close()
        motion.stop.set()
        if serial_thread:
            serial_thread.join(timeout=1)
        if not args.headless:
            cv2.destroyAllWindows()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--camera", type=int, default=0, help="USB capture device index")
    source.add_argument("--video", help="recording to replay in source order")
    parser.add_argument("--serial", help="optional MSH port for M1 debug overlay")
    parser.add_argument("--shield-side", choices=("left", "right", "either"), default="right",
                        help="Pose arm in mirrored input, default is the Immersive reference arm")
    parser.add_argument("--landmarks", action="store_true", help="include keypoints in JSONL stdout")
    parser.add_argument("--headless", action="store_true", help="disable the OpenCV window")
    args = parser.parse_args()
    try:
        run(args)
    except OSError as error:
        sys.exit(str(error))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
