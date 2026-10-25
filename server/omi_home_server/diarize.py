"""話者分離 (誰がいつ話したか) と話者の埋め込みベクトル (sherpa-onnx, CPU)。"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import numpy as np

from . import models
from .audio import SAMPLE_RATE
from .config import Settings

log = logging.getLogger(__name__)


@dataclass
class Turn:
    start: float
    end: float
    # セグメント内での話者ラベル ("S0", "S1", ...)
    label: str

    def as_dict(self) -> dict:
        return {"start": round(self.start, 3), "end": round(self.end, 3), "label": self.label}


class Diarizer:
    def __init__(self, settings: Settings):
        import sherpa_onnx as so

        seg_model = models.ensure(models.SEGMENTATION, settings.models_path, settings.allow_model_download)
        emb_model = models.ensure(models.EMBEDDING, settings.models_path, settings.allow_model_download)
        threads = max(1, settings.num_threads)
        embedding = so.SpeakerEmbeddingExtractorConfig(model=str(emb_model), num_threads=threads)
        config = so.OfflineSpeakerDiarizationConfig(
            segmentation=so.OfflineSpeakerSegmentationModelConfig(
                pyannote=so.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(seg_model)), num_threads=threads),
            embedding=embedding,
            clustering=so.FastClusteringConfig(num_clusters=-1, threshold=settings.diarization_threshold),
            min_duration_on=0.3,
            min_duration_off=0.5,
        )
        if not config.validate():
            raise models.ModelUnavailable("話者分離の設定が不正です")
        self._sd = so.OfflineSpeakerDiarization(config)
        self._extractor = so.SpeakerEmbeddingExtractor(embedding)
        self.model_name = f"{models.SEGMENTATION.name}+{models.EMBEDDING.name}"

    def diarize(self, audio: np.ndarray) -> list[Turn]:
        if len(audio) < SAMPLE_RATE // 2:
            return []
        result = self._sd.process(np.ascontiguousarray(audio, dtype=np.float32)).sort_by_start_time()
        return [Turn(float(s.start), float(s.end), f"S{s.speaker}") for s in result]

    def embed(self, audio: np.ndarray) -> np.ndarray | None:
        if len(audio) < SAMPLE_RATE // 2:
            return None
        stream = self._extractor.create_stream()
        stream.accept_waveform(SAMPLE_RATE, np.ascontiguousarray(audio, dtype=np.float32))
        stream.input_finished()
        if not self._extractor.is_ready(stream):
            return None
        v = np.asarray(self._extractor.compute(stream), dtype=np.float32)
        n = float(np.linalg.norm(v))
        return v / n if n > 0 else None

    def speaker_embeddings(self, audio: np.ndarray, turns: list[Turn],
                           max_seconds: float = 60.0) -> dict[str, tuple[np.ndarray, float]]:
        """話者ラベルごとに発話をつなげて埋め込みを計算する。戻り値は {label: (埋め込み, 発話秒数)}。"""
        by_label: dict[str, list[np.ndarray]] = {}
        for t in turns:
            clip = audio[int(t.start * SAMPLE_RATE):int(t.end * SAMPLE_RATE)]
            if len(clip):
                by_label.setdefault(t.label, []).append(clip)
        out: dict[str, tuple[np.ndarray, float]] = {}
        for label, clips in by_label.items():
            joined = np.concatenate(clips)
            seconds = len(joined) / SAMPLE_RATE
            emb = self.embed(joined[: int(max_seconds * SAMPLE_RATE)])
            if emb is not None:
                out[label] = (emb, seconds)
        return out


def label_for(start: float, end: float, turns: list[dict]) -> str | None:
    """区間と最も長く重なる話者ラベル (端末の文字起こしに話者を付けるのに使う)。"""
    best, best_overlap = None, 0.0
    for t in turns:
        overlap = min(end, t["end"]) - max(start, t["start"])
        if overlap > best_overlap:
            best, best_overlap = t["label"], overlap
    if best is None and turns:
        # 重なりがなければ最も近い区間
        mid = (start + end) / 2
        nearest = min(turns, key=lambda t: min(abs(mid - t["start"]), abs(mid - t["end"])))
        if min(abs(mid - nearest["start"]), abs(mid - nearest["end"])) < 1.0:
            best = nearest["label"]
    return best
