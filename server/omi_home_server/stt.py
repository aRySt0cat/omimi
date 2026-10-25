"""サーバ側の文字起こしエンジン。

- faster-whisper: CPU / x86_64 CUDA / Mac 向け (CTranslate2)
- transformers:   PyTorch 環境向け。DGX Spark (aarch64 + GB10) は NGC PyTorch コンテナで動かす
- none:           文字起こしをしない (保存のみ)

音声は発話区間 (話者分離の結果、なければ簡易 VAD) ごとに切り出し、区間ごとに
言語を判別 (候補言語に限定) してから文字起こしする。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any, Protocol, Sequence

import numpy as np

from .audio import SAMPLE_RATE, speech_regions
from .config import Settings

log = logging.getLogger(__name__)


@dataclass
class Piece:
    start: float
    end: float
    text: str
    language: str | None = None
    # セグメント内の話者ラベル ("S0" など)。話者名は読み出し時に解決する。
    speaker_label: str | None = None

    def as_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {"start": round(self.start, 3), "end": round(self.end, 3), "text": self.text}
        if self.language:
            d["language"] = self.language
        if self.speaker_label:
            d["speaker_label"] = self.speaker_label
        return d


class Engine(Protocol):
    name: str
    model: str

    def transcribe(self, audio: np.ndarray, language: str | None = None, hotwords: str | None = None) -> list[Piece]:
        """hotwords: 用語集の語 (人名・専門用語) を空白区切りで。認識しやすくするヒント"""
        ...

    def detect_language(self, audio: np.ndarray, candidates: Sequence[str]) -> tuple[str, float]: ...


# Whisper が無音・雑音で出しがちな定型文 (区間全体がこれだけなら捨てる)。
# 実際の発話でもあり得る短い挨拶 (「ありがとうございました」等) は消さない。
HALLUCINATIONS = {
    "ご視聴ありがとうございました", "ご視聴ありがとうございました。", "字幕は自動生成されています",
    "Thank you for watching.", "Thanks for watching!",
}


def _clean(pieces: list[Piece]) -> list[Piece]:
    return [p for p in pieces if p.text.strip() and p.text.strip() not in HALLUCINATIONS]


def _pick(probs: dict[str, float], candidates: Sequence[str]) -> tuple[str, float]:
    scores = {c: probs.get(c, 0.0) for c in candidates}
    total = sum(scores.values())
    best = max(scores, key=scores.get)
    return best, (scores[best] / total if total > 0 else 0.0)


class NoneEngine:
    name = "none"
    model = ""

    def transcribe(self, audio: np.ndarray, language: str | None = None, hotwords: str | None = None) -> list[Piece]:
        return []

    def detect_language(self, audio: np.ndarray, candidates: Sequence[str]) -> tuple[str, float]:
        return candidates[0], 0.0


class FasterWhisperEngine:
    name = "faster-whisper"

    def __init__(self, settings: Settings):
        from faster_whisper import WhisperModel

        self.model = settings.stt_model or "large-v3-turbo"
        log.info("loading faster-whisper model=%s device=%s", self.model, settings.stt_device)
        self._model = WhisperModel(self.model, device=settings.stt_device, compute_type=settings.stt_compute_type)

    def transcribe(self, audio: np.ndarray, language: str | None = None, hotwords: str | None = None) -> list[Piece]:
        segments, _info = self._model.transcribe(
            audio, language=language, vad_filter=True, beam_size=5, condition_on_previous_text=False,
            hotwords=hotwords or None,
        )
        return _clean([Piece(s.start, s.end, s.text.strip(), language) for s in segments])

    def detect_language(self, audio: np.ndarray, candidates: Sequence[str]) -> tuple[str, float]:
        _lang, _prob, all_probs = self._model.detect_language(audio[: 30 * SAMPLE_RATE])
        return _pick(dict(all_probs), candidates)


class TransformersEngine:
    name = "transformers"

    def __init__(self, settings: Settings):
        import torch
        import transformers
        from transformers import pipeline

        self._torch = torch
        self.model = settings.stt_model or "openai/whisper-large-v3-turbo"
        device = settings.stt_device
        if device == "auto":
            device = "cuda:0" if torch.cuda.is_available() else "cpu"
        dtype = torch.float16 if device.startswith("cuda") else torch.float32
        log.info("loading transformers model=%s device=%s dtype=%s", self.model, device, dtype)
        # transformers 4.56 以降は dtype、それより前は torch_dtype
        major, minor = (int(x) for x in transformers.__version__.split(".")[:2])
        dtype_arg = "dtype" if (major, minor) >= (4, 56) else "torch_dtype"
        self._pipe = pipeline("automatic-speech-recognition", model=self.model, device=device, **{dtype_arg: dtype})

    def transcribe(self, audio: np.ndarray, language: str | None = None, hotwords: str | None = None) -> list[Piece]:
        # 用語のヒント (hotwords) はこのエンジンでは使わない (出力に混ざることがあるため)。補正と AI のまとめで使う
        kwargs = {"task": "transcribe", **({"language": language} if language else {})}
        # 区間は 30 秒以内に切ってあるので分割処理 (chunk_length_s) は使わない
        result = self._pipe({"raw": audio[: 30 * SAMPLE_RATE], "sampling_rate": SAMPLE_RATE}, return_timestamps=True,
                            generate_kwargs=kwargs)
        duration = len(audio) / SAMPLE_RATE
        chunks = result.get("chunks") or [{"timestamp": (0.0, duration), "text": result["text"]}]
        pieces = []
        for ch in chunks:
            t0, t1 = ch["timestamp"]
            pieces.append(Piece(float(t0 or 0.0), float(t1 if t1 is not None else duration), ch["text"].strip(), language))
        return _clean(pieces)

    def detect_language(self, audio: np.ndarray, candidates: Sequence[str]) -> tuple[str, float]:
        """Whisper の言語トークンの確率を候補言語に限って比べる。"""
        torch = self._torch
        model, tok = self._pipe.model, self._pipe.tokenizer
        feats = self._pipe.feature_extractor(audio[: 30 * SAMPLE_RATE], sampling_rate=SAMPLE_RATE,
                                             return_tensors="pt").input_features
        feats = feats.to(model.device, dtype=model.dtype)
        sot = tok.convert_tokens_to_ids("<|startoftranscript|>")
        with torch.no_grad():
            logits = model(input_features=feats, decoder_input_ids=torch.tensor([[sot]], device=model.device)).logits[0, -1]
        ids = [tok.convert_tokens_to_ids(f"<|{c}|>") for c in candidates]
        probs = torch.softmax(logits[ids].float(), dim=-1).tolist()
        return _pick(dict(zip(candidates, probs)), candidates)


def create_engine(settings: Settings) -> Engine:
    if settings.stt_engine == "faster-whisper":
        return FasterWhisperEngine(settings)
    if settings.stt_engine == "transformers":
        return TransformersEngine(settings)
    if settings.stt_engine == "none":
        return NoneEngine()
    raise ValueError(f"unknown OMI_STT_ENGINE: {settings.stt_engine}")


def regions_from_turns(turns: list[dict[str, Any]], *, merge_gap: float = 1.0, max_seconds: float = 28.0,
                       pad: float = 0.2, duration: float | None = None) -> list[tuple[float, float, str | None]]:
    """話者分離の結果を、同じ話者の連続した発話にまとめ、Whisper の 30 秒窓に収まるよう分割する。"""
    merged: list[list[Any]] = []
    for t in sorted(turns, key=lambda t: t["start"]):
        if merged and merged[-1][2] == t["label"] and t["start"] - merged[-1][1] <= merge_gap \
                and t["end"] - merged[-1][0] <= max_seconds:
            merged[-1][1] = max(merged[-1][1], t["end"])
        else:
            merged.append([t["start"], t["end"], t["label"]])
    out: list[tuple[float, float, str | None]] = []
    for s, e, label in merged:
        s = max(0.0, s - pad)
        e = e + pad if duration is None else min(duration, e + pad)
        while e - s > max_seconds:
            out.append((s, s + max_seconds, label))
            s += max_seconds
        out.append((s, e, label))
    return out


def transcribe_regions(engine: Engine, audio: np.ndarray, turns: list[dict[str, Any]] | None,
                       languages: Sequence[str], hotwords: str | None = None) -> list[Piece]:
    """発話区間ごとに言語を判別して文字起こしする。"""
    duration = len(audio) / SAMPLE_RATE
    if turns:
        regions = regions_from_turns(turns, duration=duration)
    else:
        regions = [(s / SAMPLE_RATE, e / SAMPLE_RATE, None) for s, e in speech_regions(audio)]
    languages = list(languages) or [None]  # type: ignore[list-item]
    previous = languages[0]
    pieces: list[Piece] = []
    for start, end, label in regions:
        clip = audio[int(start * SAMPLE_RATE):int(end * SAMPLE_RATE)]
        # 0.7 秒未満 (前後の余白込み) は Whisper が意味のない文字列を出しやすいので飛ばす
        if len(clip) < int(SAMPLE_RATE * 0.7):
            continue
        language = languages[0]
        if len(languages) > 1:
            # 1 秒未満は判別が不安定なので直前の区間の言語を使う
            language = engine.detect_language(clip, languages)[0] if end - start >= 1.0 else previous
        previous = language
        for p in engine.transcribe(clip, language=language, hotwords=hotwords):
            pieces.append(Piece(start + p.start, min(end, start + p.end), p.text, language, label))
    return pieces
