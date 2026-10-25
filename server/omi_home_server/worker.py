"""バックグラウンドワーカー: 話者分離・話者識別と、サーバ側の文字起こしを 1 スレッドで順番に処理する。"""

from __future__ import annotations

import json
import logging
import threading
import time

import numpy as np
from pathlib import Path
from typing import Any, Callable

from . import speaker_model
from .audio import SAMPLE_RATE, load_audio
from .config import Settings
from .db import Database
from .diarize import Diarizer, label_for
from .exporter import Exporter
from .speakers import identify
from .stt import Engine, create_engine, regions_from_turns, transcribe_regions
from .vocabulary import Vocabulary

log = logging.getLogger(__name__)

# 声の特徴を取る発話の最短の長さ (秒)
MIN_UTTERANCE_SECONDS = 1.0
# 人が話者を直してから学習し直すまで待つ秒数 (続けて直す間は待つ)
RETRAIN_DELAY = 10.0


def enrich(db: Database, seg: dict[str, Any], transcripts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """文字起こしの各区間に話者 (ID と表示名) を付ける。

    サーバの文字起こしは区間に話者ラベルを持つ。端末 (Apple) の文字起こしは時刻の重なりで割り当てる。
    話者名は読み出し時に解決するので、名前の変更や統合が過去の記録にも反映される。
    """
    turns = json.loads(seg.get("turns_json") or "[]")
    smap = db.speaker_map(seg["id"])
    utterances = db.utterances_for(seg["id"])
    vocab = Vocabulary.load(db)
    names = db.speaker_names() if utterances else {}
    for t in transcripts:
        for p in t["pieces"]:
            # 用語集の「よく間違う表記」を正しい表記に (元の文字起こしは original_text に残す)
            if vocab and "original_text" not in p:
                fixed = vocab.correct(p["text"])
                if fixed != p["text"]:
                    p["original_text"], p["text"] = p["text"], fixed
            label = p.get("speaker_label") or (label_for(p["start"], p["end"], turns) if turns else None)
            if label:
                p["speaker_label"] = label
                info = smap.get(label)
                if info and info["speaker_id"] is not None:
                    p["speaker_id"] = info["speaker_id"]
                    p["speaker"] = info["speaker"]
            # 発話ごとの指定 (人が直したもの・学習したモデルが付け替えたもの) を優先する
            u = utterance_for(p["start"], p["end"], utterances)
            if u is not None:
                p["utterance_id"] = u["id"]
                if u["manual"]:
                    p["speaker_manual"] = True
                sid = u["speaker_id"]
                if sid is None:
                    if u["manual"]:
                        p.pop("speaker_id", None)
                        p.pop("speaker", None)
                else:
                    p["speaker_id"] = sid
                    p["speaker"] = names.get(sid)
    return transcripts


def utterance_for(start: float, end: float, utterances: list[dict[str, Any]]) -> dict[str, Any] | None:
    """文字起こしの区間に対応する発話。人が指定した範囲を優先し、区間の半分以上が重なるものを選ぶ。"""
    length = max(end - start, 1e-3)
    for manual in (1, 0):
        best, best_overlap = None, 0.0
        for u in utterances:
            if u["manual"] != manual:
                continue
            overlap = min(end, u["end_s"]) - max(start, u["start_s"])
            if overlap > best_overlap:
                best, best_overlap = u, overlap
        if best is not None and best_overlap >= 0.5 * min(length, best["end_s"] - best["start_s"]):
            return best
    return None


def write_sidecar(db: Database, settings: Settings, seg_id: str) -> None:
    """DB が壊れても復元できるよう、音声の隣にメタデータと文字起こしの JSON を置く。"""
    seg = db.get_segment(seg_id)
    if not seg or not seg.get("audio_path"):
        return
    audio = settings.data_dir / seg["audio_path"]
    payload = {
        "segment": {k: v for k, v in seg.items() if k != "turns_json"},
        "turns": json.loads(seg.get("turns_json") or "[]"),
        "speakers": db.speaker_map(seg_id),
        "transcripts": enrich(db, seg, db.transcripts_for(seg_id)),
    }
    tmp = audio.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2))
    tmp.replace(audio.with_suffix(".json"))


class TranscriptionWorker:
    """2 本のスレッドで処理する。

    - 話者分離スレッド: 話者分離・話者識別と、timeline/ の書き出し (速い。CPU)
    - 文字起こしスレッド: サーバの Whisper (遅い。モデルの初回ダウンロードもここ)

    文字起こしが遅くても、新しい録音の話者分離は待たされない。
    """

    def __init__(self, db: Database, settings: Settings,
                 engine_factory: Callable[[Settings], Engine] = create_engine,
                 diarizer_factory: Callable[[Settings], Any] = Diarizer):
        self.db = db
        self.settings = settings
        self._engine_factory = engine_factory
        self._diarizer_factory = diarizer_factory
        self._engine: Engine | None = None
        self._diarizer: Any = None
        self._diar_wake = threading.Event()
        self._stt_wake = threading.Event()
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self.last_error: str | None = None
        self.exporter = Exporter(db, settings)
        self._dirty: set[Any] = set()
        self._dirty_lock = threading.Lock()
        # 名前を付けた話者を学習したモデル。起動後に一度学習し直す (前の版のデータにも発話の特徴を作るため)
        self.speaker_model = speaker_model.SpeakerModel.load(speaker_model.model_path(settings.data_dir))
        self._model_lock = threading.Lock()
        self._model_dirty_at: float | None = time.monotonic() - RETRAIN_DELAY

    @property
    def transcription_enabled(self) -> bool:
        return self.settings.stt_engine != "none"

    @property
    def diarization_enabled(self) -> bool:
        return self.settings.diarization

    @property
    def enabled(self) -> bool:
        return self.transcription_enabled or self.diarization_enabled

    def start(self) -> None:
        # 話者分離・文字起こしが無効でも、書き出し (timeline/) のために話者分離スレッドは動かす
        if self._threads:
            return
        self.db.requeue_running()
        self._threads = [threading.Thread(target=self._diar_loop, name="omi-diarization", daemon=True)]
        if self.transcription_enabled:
            self._threads.append(threading.Thread(target=self._stt_loop, name="omi-transcription", daemon=True))
        for t in self._threads:
            t.start()
        self.notify()

    def stop(self) -> None:
        self._stop.set()
        self.notify()
        for t in self._threads:
            t.join(timeout=5)

    def notify(self) -> None:
        self._diar_wake.set()
        self._stt_wake.set()

    def mark_dirty(self, *started_ats: str, all_days: bool = False) -> None:
        """書き出しを作り直す日を登録する (ISO 時刻で指定)。"""
        with self._dirty_lock:
            if all_days:
                self._dirty.add("*")
            for iso in started_ats:
                if iso:
                    self._dirty.add(self.exporter.day_of(iso))
        self._diar_wake.set()

    def flush_exports(self) -> int:
        """登録された日の timeline/ を作り直す。"""
        with self._dirty_lock:
            dirty, self._dirty = self._dirty, set()
        if not dirty:
            return 0
        days = self.exporter.all_days() if "*" in dirty else dirty
        try:
            self.exporter.write_agents_guide()
            for day in sorted(days):
                self.exporter.export_day(day)
        except Exception:  # noqa: BLE001 - 書き出しの失敗で処理を止めない
            log.exception("export failed")
        return len(days)

    def engine(self) -> Engine:
        if self._engine is None:
            self._engine = self._engine_factory(self.settings)
        return self._engine

    def diarizer(self) -> Any:
        if self._diarizer is None:
            self._diarizer = self._diarizer_factory(self.settings)
        return self._diarizer

    def process_diarization(self) -> bool:
        """話者分離を 1 件処理する。処理したら True。"""
        if not self.diarization_enabled:
            return False
        seg = self.db.next_diarization_job()
        if seg is None:
            return False
        seg_id = seg["id"]
        try:
            t0 = time.monotonic()
            audio = load_audio(self.settings.data_dir / seg["audio_path"])
            diarizer = self.diarizer()
            turns = diarizer.diarize(audio)
            embeddings = diarizer.speaker_embeddings(audio, turns)
            model = self.speaker_model
            identify(self.db, seg_id, embeddings, match_threshold=self.settings.speaker_match_threshold,
                     min_seconds=self.settings.speaker_min_seconds, model=model)
            self.db.set_turns(seg_id, [t.as_dict() for t in turns])
            self.db.replace_auto_utterances(seg_id, self.utterance_rows(audio, [t.as_dict() for t in turns]))
            speaker_model.apply_model(self.db, model, {seg_id})
            self.db.set_diarization_status(seg_id, "done")
            log.info("diarized %s: %d turns, %d speakers in %.1fs", seg_id, len(turns), len(embeddings),
                     time.monotonic() - t0)
        except Exception as e:  # noqa: BLE001 - 1 件の失敗でワーカーを止めない
            log.exception("diarization failed for %s", seg_id)
            self.last_error = f"diarization: {type(e).__name__}: {e}"
            self.db.set_diarization_status(seg_id, "failed", self.last_error)
        write_sidecar(self.db, self.settings, seg_id)
        self.mark_dirty(seg["started_at"])
        self._stt_wake.set()  # 話者分離待ちだった文字起こしを進める
        return True

    def utterance_rows(self, audio: Any, turns: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """話者分離の区間を、同じ話者が続けて話した発話にまとめ、それぞれの声の特徴を取る。"""
        embed = getattr(self.diarizer(), "embed", None)
        rows = []
        for start, end, label in regions_from_turns(turns, pad=0.0, duration=len(audio) / SAMPLE_RATE):
            emb = None
            if embed is not None and end - start >= MIN_UTTERANCE_SECONDS:
                emb = embed(audio[int(start * SAMPLE_RATE):int(end * SAMPLE_RATE)])
            rows.append({"start": round(start, 3), "end": round(end, 3), "label": label, "embedding": emb})
        return rows

    def process_speaker_backlog(self) -> bool:
        """以前に処理した録音の発話の特徴づくりと、人が指定した範囲の特徴づくりを少しずつ進める。"""
        if not self.diarization_enabled:
            return False
        for seg in self.db.segments_without_utterances(limit=1):
            try:
                audio = load_audio(self.settings.data_dir / seg["audio_path"])
                rows = self.utterance_rows(audio, json.loads(seg.get("turns_json") or "[]"))
            except Exception:  # noqa: BLE001
                log.exception("utterance backfill failed for %s", seg["id"])
                rows = []
            # 失敗しても空の発話を 1 つ入れて、何度も繰り返さない
            self.db.replace_auto_utterances(seg["id"], rows or [{"start": 0.0, "end": 0.0, "label": None}])
            self.mark_model_dirty()
            return True
        pending = self.db.manual_utterances_without_embedding(MIN_UTTERANCE_SECONDS, limit=10)
        if not pending:
            return False
        embed = getattr(self.diarizer(), "embed", None)
        audio_cache: dict[str, Any] = {}
        for u in pending:
            emb = None
            try:
                if embed is not None:
                    if u["audio_path"] not in audio_cache:
                        audio_cache[u["audio_path"]] = load_audio(self.settings.data_dir / u["audio_path"])
                    audio = audio_cache[u["audio_path"]]
                    emb = embed(audio[int(u["start_s"] * SAMPLE_RATE):int(u["end_s"] * SAMPLE_RATE)])
            except Exception:  # noqa: BLE001
                log.exception("embedding failed for utterance %s", u["id"])
            self.db.set_utterance_embedding(u["id"], emb)
            # 名前だけ先に作った話者 (声の特徴がまだない) に、この発話の声を入れる
            sid = u["manual_speaker_id"]
            if emb is not None and sid is not None:
                profile = next((vec for i, vec, _w in self.db.speaker_profiles() if i == sid), None)
                if profile is not None and float(np.linalg.norm(profile)) == 0.0:
                    self.db.update_speaker_embedding(sid, emb, 1.0)
        self.mark_model_dirty()
        return True

    @property
    def model_pending(self) -> bool:
        """話者の指定が変わって、学習し直しを待っている"""
        return self._model_dirty_at is not None

    def mark_model_dirty(self) -> None:
        """話者の指定が変わった。少し待ってから学習し直す。"""
        self._model_dirty_at = time.monotonic()
        self._diar_wake.set()

    def retrain(self) -> dict[str, Any]:
        """名前を付けた話者を学習し直し、過去の記録にも当てはめる。"""
        with self._model_lock:
            self._model_dirty_at = None
            model, report = speaker_model.retrain(self.db, self.settings.data_dir)
            self.speaker_model = model
        for seg_id in report["segments"]:
            seg = self.db.get_segment(seg_id)
            if seg:
                write_sidecar(self.db, self.settings, seg_id)
                self.mark_dirty(seg["started_at"])
        return report

    def retrain_if_due(self, force: bool = False) -> bool:
        due = self._model_dirty_at
        if due is None or not self.diarization_enabled:
            return False
        if not force and time.monotonic() - due < RETRAIN_DELAY:
            return False
        try:
            self.retrain()
        except Exception:  # noqa: BLE001
            log.exception("speaker model training failed")
            self._model_dirty_at = None
        return True

    def process_transcription(self) -> bool:
        """文字起こしを 1 件処理する。処理したら True。"""
        if not self.transcription_enabled:
            return False
        seg = self.db.next_transcription_job(wait_for_diarization=self.diarization_enabled)
        if seg is None:
            return False
        seg_id = seg["id"]
        turns = json.loads(seg.get("turns_json") or "[]")
        device_text = any(t["pieces"] for t in self.db.transcripts_for(seg_id) if t["origin"] == "device")
        if self.diarization_enabled and seg.get("diarization_status") == "done" and not turns and not device_text:
            # 話者分離で話し声が見つからなかった録音は Whisper に掛けない (物音だけの録音が多いため)
            self.db.put_transcript(seg_id, "server", engine="skipped:no-speech", locale="+".join(self.settings.languages),
                                   pieces=[])
            self.db.set_stt_status(seg_id, "done")
            write_sidecar(self.db, self.settings, seg_id)
            self.mark_dirty(seg["started_at"])
            return True
        try:
            t0 = time.monotonic()
            audio = load_audio(self.settings.data_dir / seg["audio_path"])
            engine = self.engine()
            pieces = transcribe_regions(engine, audio, turns, self.settings.languages,
                                        hotwords=Vocabulary.load(self.db).hotwords())
            label = f"{engine.name}:{engine.model}" if engine.model else engine.name
            self.db.put_transcript(seg_id, "server", engine=label, locale="+".join(self.settings.languages),
                                   pieces=[p.as_dict() for p in pieces])
            self.db.set_stt_status(seg_id, "done")
            log.info("transcribed %s (%.1fs audio) in %.1fs: %d pieces", seg_id, len(audio) / 16000,
                     time.monotonic() - t0, len(pieces))
        except Exception as e:  # noqa: BLE001
            log.exception("transcription failed for %s", seg_id)
            self.last_error = f"transcription: {type(e).__name__}: {e}"
            self.db.set_stt_status(seg_id, "failed", self.last_error)
        write_sidecar(self.db, self.settings, seg_id)
        self.mark_dirty(seg["started_at"])
        return True

    def process_one(self) -> bool:
        """話者分離を優先して 1 件処理する (CLI・テスト用)。"""
        return self.process_diarization() or self.process_transcription()

    def _diar_loop(self) -> None:
        self.mark_dirty(all_days=True)  # 起動時に全日分を作り直す (書式の変更を反映)
        while not self._stop.is_set():
            due = self._model_dirty_at
            wait = 60.0 if due is None else max(1.0, RETRAIN_DELAY - (time.monotonic() - due))
            self._diar_wake.wait(timeout=wait)
            self._diar_wake.clear()
            # 思わぬ失敗 (ほかのプロセスが DB に書いていて待ちきれなかった等) でスレッドを止めない。
            # 止まると、話者分離も、それを待つ文字起こしも、静かに進まなくなる
            self._guarded("diarization", self._diar_round)

    def _diar_round(self) -> None:
        while not self._stop.is_set() and self.process_diarization():
            self.flush_exports()
        # 新しい録音を優先し、空いたら以前の録音の発話の特徴づくり → 学習し直し
        while not self._stop.is_set() and self.db.queue_counts()["diarization"].get("queued", 0) == 0 \
                and self.process_speaker_backlog():
            pass
        self.retrain_if_due()
        self.flush_exports()

    def _stt_loop(self) -> None:
        while not self._stop.is_set():
            self._stt_wake.wait(timeout=60)
            self._stt_wake.clear()
            self._guarded("transcription", self._stt_round)

    def _stt_round(self) -> None:
        while not self._stop.is_set() and self.process_transcription():
            pass

    def _guarded(self, name: str, body: Callable[[], None]) -> None:
        try:
            body()
        except Exception as e:  # noqa: BLE001
            log.exception("%s loop failed; retrying shortly", name)
            self.last_error = f"{name}: {type(e).__name__}: {e}"
            self._stop.wait(5)  # 同じ失敗を繰り返して CPU を使い切らないよう、少し待ってからやり直す

    def drain(self) -> int:
        """キューが空になるまで同期的に処理する (CLI・テスト用)。"""
        n = 0
        while self.process_one() or self.process_speaker_backlog():
            n += 1
        self.retrain_if_due(force=True)
        self.flush_exports()
        return n


def audio_relpath(seg_id: str, started_at: str) -> Path:
    """audio/YYYY/MM/DD/<id>.opus (日付は UTC)"""
    day = started_at[:10]
    y, m, d = day.split("-")
    return Path("audio") / y / m / d / f"{seg_id}.opus"
