"""Ogg Opus セグメントのデコード。"""

from __future__ import annotations

from pathlib import Path

import numpy as np

SAMPLE_RATE = 16_000


def load_audio(path: Path, sample_rate: int = SAMPLE_RATE) -> np.ndarray:
    """音声ファイルを float32 モノラル (-1..1) で読み込む。"""
    import av  # 遅延 import (テストで不要な場合に読み込まない)

    resampler = av.AudioResampler(format="flt", layout="mono", rate=sample_rate)
    chunks: list[np.ndarray] = []
    with av.open(str(path)) as container:
        stream = container.streams.audio[0]
        for frame in container.decode(stream):
            for out in resampler.resample(frame):
                chunks.append(out.to_ndarray().reshape(-1))
        for out in resampler.resample(None):
            chunks.append(out.to_ndarray().reshape(-1))
    if not chunks:
        return np.zeros(0, dtype=np.float32)
    return np.concatenate(chunks).astype(np.float32, copy=False)


def speech_regions(audio: np.ndarray, sample_rate: int = SAMPLE_RATE, *, frame_ms: int = 30,
                   min_speech_s: float = 0.3, merge_gap_s: float = 0.8, pad_s: float = 0.3,
                   max_region_s: float = 28.0) -> list[tuple[int, int]]:
    """簡易なエネルギーベースの音声区間検出。

    24 時間録音は無音が多く、Whisper は無音で幻覚 (「ご視聴ありがとうございました」等) を起こしやすい。
    発話がありそうな区間だけを切り出して文字起こしする。戻り値はサンプル位置 [start, end) のリスト。
    """
    n = len(audio)
    if n == 0:
        return []
    hop = int(sample_rate * frame_ms / 1000)
    frames = n // hop
    if frames == 0:
        return [(0, n)]
    energy = np.sqrt(np.mean(audio[: frames * hop].reshape(frames, hop) ** 2, axis=1) + 1e-12)
    db = 20 * np.log10(energy + 1e-9)
    noise_floor = np.percentile(db, 20)
    threshold = max(noise_floor + 10.0, -55.0)
    active = db > threshold

    regions: list[list[int]] = []
    start = None
    for i, a in enumerate(active):
        if a and start is None:
            start = i
        elif not a and start is not None:
            regions.append([start, i])
            start = None
    if start is not None:
        regions.append([start, frames])

    merged: list[list[int]] = []
    gap = int(merge_gap_s * 1000 / frame_ms)
    for r in regions:
        if merged and r[0] - merged[-1][1] <= gap:
            merged[-1][1] = r[1]
        else:
            merged.append(r)

    pad = int(pad_s * sample_rate)
    min_len = int(min_speech_s * sample_rate)
    max_len = int(max_region_s * sample_rate)
    out: list[tuple[int, int]] = []
    for s, e in merged:
        s_sample = max(0, s * hop - pad)
        e_sample = min(n, e * hop + pad)
        if e_sample - s_sample < min_len:
            continue
        # Whisper の 30 秒窓に収まるよう分割
        while e_sample - s_sample > max_len:
            out.append((s_sample, s_sample + max_len))
            s_sample += max_len
        out.append((s_sample, e_sample))
    return out
