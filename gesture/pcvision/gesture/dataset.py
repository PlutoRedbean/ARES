"""Dataset and augmentation for gesture frames captured at 1280x720.

The camera tool already letterboxes frames to the hardware geometry, so this
module only decodes, augments and builds the per-cell target.  Geometric
augmentation must move the label centre with the image.
"""

from __future__ import annotations

import os
from pathlib import Path

import cv2
import numpy as np
import torch
from torch.utils.data import DataLoader, Dataset

from common import (
    FRAME_H,
    FRAME_W,
    Label,
    gaussian_target,
    letterbox,
)


def _photometric(img: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    if rng.random() < 0.7:
        alpha = rng.uniform(0.75, 1.25)
        beta = rng.uniform(-28, 28)
        img = np.clip(img.astype(np.float32) * alpha + beta, 0, 255).astype(np.uint8)
    if rng.random() < 0.5:
        hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV).astype(np.float32)
        hsv[..., 0] = (hsv[..., 0] + rng.uniform(-6, 6)) % 180
        hsv[..., 1] = np.clip(hsv[..., 1] * rng.uniform(0.8, 1.2), 0, 255)
        hsv[..., 2] = np.clip(hsv[..., 2] * rng.uniform(0.85, 1.15), 0, 255)
        img = cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2BGR)
    if rng.random() < 0.15:
        img = cv2.GaussianBlur(img, (3, 3), rng.uniform(0.3, 1.2))
    if rng.random() < 0.15:
        noise = rng.normal(0, rng.uniform(1.5, 6.0), img.shape)
        img = np.clip(img.astype(np.float32) + noise, 0, 255).astype(np.uint8)
    if rng.random() < 0.12:
        q = int(rng.uniform(45, 90))
        ok, enc = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, q])
        if ok:
            img = cv2.imdecode(enc, cv2.IMREAD_COLOR)
    return img


def _geometric(img: np.ndarray, cx: float, cy: float, rng: np.random.Generator,
               hflip: float = 0.0):
    angle = float(rng.uniform(-8.0, 8.0))
    scale = float(rng.uniform(0.9, 1.1))
    m = cv2.getRotationMatrix2D((cx, cy), angle, scale)
    m[0, 2] += float(rng.uniform(-36.0, 36.0))
    m[1, 2] += float(rng.uniform(-30.0, 30.0))
    warped = cv2.warpAffine(img, m, (FRAME_W, FRAME_H), flags=cv2.INTER_LINEAR,
                            borderMode=cv2.BORDER_REFLECT_101)
    pt = m @ np.array([cx, cy, 1.0], dtype=np.float64)
    cx2, cy2 = float(pt[0]), float(pt[1])
    if hflip > 0 and rng.random() < hflip:
        warped = cv2.flip(warped, 1)
        cx2 = float(FRAME_W - 1 - cx2)
    return warped, cx2, cy2


class GestureDataset(Dataset):
    def __init__(self, labels: list[Label], root: str | os.PathLike, names: list[str],
                 train: bool = True, sigma: float = 2.0, hflip: float = 0.0,
                 seed: int = 0):
        self.labels = labels
        self.root = Path(root)
        self.names = names
        self.k = len(names)
        self.train = train
        self.sigma = sigma
        self.hflip = hflip
        self.seed = seed
        self.epoch = 0

    def __len__(self) -> int:
        return len(self.labels)

    def set_epoch(self, epoch: int) -> None:
        self.epoch = epoch

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, torch.Tensor]:
        l = self.labels[idx]
        path = self.root / l.file
        img = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if img is None:
            raise FileNotFoundError(f"cannot read {path}")
        if img.shape[1] != FRAME_W or img.shape[0] != FRAME_H:
            img = letterbox(img)
        cx = float(l.x) if l.x >= 0 else FRAME_W / 2.0
        cy = float(l.y) if l.y >= 0 else FRAME_H / 2.0

        if self.train:
            rng = np.random.default_rng((self.seed * 1_000_003 + idx * 7919 + self.epoch * 104_729) & 0xFFFFFFFF)
            img, cx, cy = _geometric(img, cx, cy, rng, self.hflip)
            img = _photometric(img, rng)
        else:
            rng = np.random.default_rng(0)

        target = gaussian_target(l.cls, cx, cy, self.k, self.sigma)
        rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        x = rgb.astype(np.float32)
        x = (x - 128.0) / 128.0
        x = np.ascontiguousarray(x.transpose(2, 0, 1))
        return torch.from_numpy(x), torch.from_numpy(target)


def make_loader(labels: list[Label], root: str | os.PathLike, names: list[str],
                train: bool, batch: int = 4, workers: int = 4, sigma: float = 2.0,
                hflip: float = 0.0, seed: int = 0) -> DataLoader:
    ds = GestureDataset(labels, root, names, train=train, sigma=sigma, hflip=hflip, seed=seed)
    return DataLoader(
        ds,
        batch_size=batch,
        shuffle=train,
        num_workers=workers,
        pin_memory=torch.cuda.is_available(),
        drop_last=False,
        # workers are re-created each epoch so set_epoch() reaches them
        persistent_workers=False,
    )
