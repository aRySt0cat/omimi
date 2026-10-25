"""環境変数による設定。"""

from __future__ import annotations

import os
import secrets
from dataclasses import dataclass, field
from pathlib import Path

TRANSCRIBE_POLICIES = ("requested", "always", "never")


def _bool(name: str, default: bool) -> bool:
    v = os.environ.get(name)
    return default if v is None else v.strip().lower() in ("1", "true", "yes", "on")


@dataclass
class Settings:
    data_dir: Path = field(default_factory=lambda: Path(os.environ.get("OMI_DATA_DIR", "./data")).resolve())
    # カンマ区切りで複数指定可。未指定なら <data_dir>/token を生成して使う。
    api_tokens: list[str] = field(default_factory=list)
    # requested: アプリが要求したセグメントだけ / always: 全て / never: しない
    transcribe_policy: str = "requested"
    stt_engine: str = "faster-whisper"  # faster-whisper | transformers | none
    stt_model: str = ""
    # 文字起こしの候補言語。2 つ以上なら発話ごとに自動判別する (先頭が既定)。
    languages: list[str] = field(default_factory=lambda: ["ja", "en"])
    stt_device: str = "auto"
    stt_compute_type: str = "default"
    # 1 回のアップロードの上限 (byte)。32 kbps の Opus なら 5 分で約 1.2 MB。
    max_upload_bytes: int = 512 * 1024 * 1024

    # 話者分離・識別 (sherpa-onnx)
    diarization: bool = True
    # 話者分離のクラスタリングしきい値 (小さいほど話者を細かく分ける)。
    # 細かく分けすぎても、次の話者識別で同じ人は同じ話者プロファイルにまとまる。
    diarization_threshold: float = 0.3
    # 既知の話者と同一人物とみなすコサイン類似度。
    # 実際の装着者の声では、話し方 (日本語/英語、音読) が違う録音どうしで 0.65〜0.95 だった。
    # 別人が同じ話者になるなら上げる (同一人物が分かれたら Web 画面で統合する)。
    speaker_match_threshold: float = 0.6
    # 新しい話者として登録するのに必要な発話秒数 (短すぎる声は「不明」のまま)
    speaker_min_seconds: float = 3.0
    model_dir: Path | None = None
    # 初回にモデルを GitHub (k2-fsa/sherpa-onnx) から取得してよいか。0 なら手動配置のみ。
    allow_model_download: bool = True
    num_threads: int = field(default_factory=lambda: min(os.cpu_count() or 4, 8))
    # 書き出し (timeline/) で日付の区切りと時刻表示に使うタイムゾーン。未指定ならサーバの地域設定。
    timezone: str | None = None

    @property
    def stt_language(self) -> str:
        return self.languages[0] if self.languages else ""

    @property
    def models_path(self) -> Path:
        return self.model_dir or (self.data_dir / "models")

    @classmethod
    def from_env(cls) -> "Settings":
        s = cls()
        tokens = os.environ.get("OMI_API_TOKEN", "")
        s.api_tokens = [t.strip() for t in tokens.split(",") if t.strip()]
        s.transcribe_policy = os.environ.get("OMI_TRANSCRIBE_POLICY", s.transcribe_policy)
        if s.transcribe_policy not in TRANSCRIBE_POLICIES:
            raise ValueError(f"OMI_TRANSCRIBE_POLICY must be one of {TRANSCRIBE_POLICIES}")
        s.stt_engine = os.environ.get("OMI_STT_ENGINE", s.stt_engine)
        s.stt_model = os.environ.get("OMI_STT_MODEL", s.stt_model)
        if "OMI_LANGUAGES" in os.environ:
            s.languages = [x.strip() for x in os.environ["OMI_LANGUAGES"].split(",") if x.strip()]
        elif "OMI_STT_LANGUAGE" in os.environ:  # 旧設定 (単一言語)
            s.languages = [os.environ["OMI_STT_LANGUAGE"].strip()]
        s.stt_device = os.environ.get("OMI_STT_DEVICE", s.stt_device)
        s.stt_compute_type = os.environ.get("OMI_STT_COMPUTE_TYPE", s.stt_compute_type)
        if "OMI_MAX_UPLOAD_BYTES" in os.environ:
            s.max_upload_bytes = int(os.environ["OMI_MAX_UPLOAD_BYTES"])
        s.diarization = _bool("OMI_DIARIZATION", s.diarization)
        s.diarization_threshold = float(os.environ.get("OMI_DIARIZATION_THRESHOLD", s.diarization_threshold))
        s.speaker_match_threshold = float(os.environ.get("OMI_SPEAKER_MATCH_THRESHOLD", s.speaker_match_threshold))
        s.speaker_min_seconds = float(os.environ.get("OMI_SPEAKER_MIN_SECONDS", s.speaker_min_seconds))
        if "OMI_MODEL_DIR" in os.environ:
            s.model_dir = Path(os.environ["OMI_MODEL_DIR"]).resolve()
        s.allow_model_download = _bool("OMI_ALLOW_MODEL_DOWNLOAD", s.allow_model_download)
        if "OMI_NUM_THREADS" in os.environ:
            s.num_threads = int(os.environ["OMI_NUM_THREADS"])
        s.timezone = os.environ.get("OMI_TIMEZONE") or None
        return s

    def ensure_dirs(self) -> None:
        (self.data_dir / "audio").mkdir(parents=True, exist_ok=True)

    def resolve_tokens(self) -> list[str]:
        """トークン未設定なら生成してファイルに保存する (パーミッション 600)。"""
        if self.api_tokens:
            return self.api_tokens
        path = self.data_dir / "token"
        if not path.exists():
            self.data_dir.mkdir(parents=True, exist_ok=True)
            path.write_text(secrets.token_urlsafe(32) + "\n")
            path.chmod(0o600)
        self.api_tokens = [path.read_text().strip()]
        return self.api_tokens
