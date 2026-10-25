"""HTTP API。

PUT   /api/v1/segments/{id}/audio                 Ogg Opus 本体 (ヘッダ X-Omi-Metadata に base64url JSON)
PUT   /api/v1/segments/{id}/device-transcript     端末 (Apple) での文字起こし結果
POST  /api/v1/segments/{id}/transcribe            サーバでの文字起こしをキューに積む
POST  /api/v1/segments/{id}/diarize               話者分離をやり直す
PUT   /api/v1/segments/{id}/speakers/{label}      セグメント内の話者ラベルを別の人に付け替える
PUT   /api/v1/segments/{id}/utterances            時間の範囲 (発話) の話者を指定する {start, end, speaker_id|name|unknown}
POST  /api/v1/segments/{id}/reassign              録音の中で、ある話者を別の人に付け替える {from_speaker_id, ...}
GET   /api/v1/segments/{id}/clip?start=&end=      発話の音声 (WAV)
PUT   /api/v1/utterances/{id}                     発話の話者を指定・確認する {speaker_id|name|unknown|confirm}
DELETE /api/v1/segments/{id}                      セグメントを削除 (音声・文字起こしも)
POST  /api/v1/segments/delete                     まとめて削除 {ids: [...]}
PUT   /api/v1/markers/{id}                        ボタンの印 {kind, at, device_id}
GET   /api/v1/markers?start=&end=                 印の一覧
DELETE /api/v1/markers/{id}                       印を削除
GET   /api/v1/segments?start=&end=                一覧 (ISO 8601, UTC)
GET   /api/v1/segments/{id}                       詳細 + 文字起こし (話者付き)
GET   /api/v1/segments/{id}/audio                 音声
GET   /api/v1/speakers                            話者一覧 (発話の数・確認したい発話の数・学習の状態)
GET   /api/v1/speakers/{id}/utterances            話者の発話 (filter=suspicious: その人らしくないもの)
GET   /api/v1/speakers/voices                     学習した声 (iPhone の話者分離で名前を当てる。since=版 で変化なしなら省略)
GET   /api/v1/compare/stt                         文字起こしの聞き比べ: 次に聞く組 (A/B は目隠し) と集計
POST  /api/v1/compare/stt/vote                    聞き比べの結果 {id, choice: a|b|same|neither}
DELETE /api/v1/compare/stt/vote/{id}              聞き比べの結果を取り消す
PUT   /api/v1/compare/stt/preference              書き出しと AI に使う文字起こし {preference: apple|whisper}
POST  /api/v1/speakers/train                      名前を付けた話者を学習し直す
PATCH /api/v1/speakers/{id}                       話者の名前を変更 {name} / 「その他」にする {ignored}
POST  /api/v1/speakers/{id}/assign                声のすべての録音を、ある人にする {speaker_id|name|unknown}
POST  /api/v1/speakers/{id}/merge                 話者を別の話者にまとめる (同一人物)
GET   /api/v1/search?q=                           文字起こしの全文検索
GET   /api/v1/stats?days=30                       蓄積の状況と、夜の整理の進み具合
GET   /api/v1/notes                               AI のまとめ (<data>/notes/*.md) の一覧
GET   /api/v1/notes/{name}                        まとめの本文
PUT   /api/v1/notes/{name}                        iPhone が自分で ChatGPT に頼んで書いたまとめを置く {text, agent}
GET   /api/v1/ai/materials?day=                   iPhone が自分で ChatGPT に頼むときの指示と添付 (自宅サーバは OpenAI と通信しない)
GET   /api/v1/health                              接続確認
GET   /api/v1/ai/status                           ChatGPT との接続と「AI で整理する」の状態
POST  /api/v1/ai/connect                          ChatGPT で続ける (許可の画面の URL を返す)
POST  /api/v1/ai/callback                         許可のあとのアドレスを貼り付けて完了する {url}
POST  /api/v1/ai/disconnect                       ChatGPT との接続を解除する
GET   /api/v1/ai/models  PUT /api/v1/ai/model     使うモデル
POST  /api/v1/ai/run                              AI で整理する {day}
GET   /api/v1/vocabulary                          用語集 (POST で追加、PUT/DELETE /api/v1/vocabulary/{id})
GET   /guide.md                                   使い方 (毎日の流れ)。認証なし
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import io
import json
import logging
import re
import wave
from datetime import date, timedelta
from contextlib import asynccontextmanager
from datetime import timezone
from pathlib import Path
from typing import Any, Callable

import numpy as np

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, Response
from pydantic import BaseModel, Field

from . import __version__
from . import compare, models, nightly, speaker_model
from . import stats as stats_module
from .ai import AiRunner
from .chatgpt import ChatGPT, ChatGPTError
from .audio import SAMPLE_RATE, load_audio
from .config import Settings
from .db import OTHER, Database, now_iso, parse_iso
from .diarize import Diarizer
from .diarize import label_for
from .exporter import choose_transcript, has_speech
from .notes import NotesStore
from .stt import Engine, create_engine
from .worker import MIN_UTTERANCE_SECONDS, TranscriptionWorker, audio_relpath, enrich, write_sidecar

log = logging.getLogger(__name__)

SEGMENT_ID = re.compile(r"^[0-9A-Za-z_-]{1,64}$")
LABEL = re.compile(r"^[0-9A-Za-z_-]{1,16}$")
MARKER_ID = re.compile(r"^[0-9A-Za-z_-]{1,64}$")
MARKER_KINDS = ("highlight", "split", "memo")
STATIC = Path(__file__).parent / "static"


class PieceIn(BaseModel):
    start: float
    end: float
    text: str
    language: str | None = Field(default=None, max_length=16)


class TranscriptIn(BaseModel):
    engine: str = Field(max_length=200)
    locale: str | None = Field(default=None, max_length=50)
    created_at: str | None = None
    pieces: list[PieceIn]


class MarkerIn(BaseModel):
    kind: str
    at: str
    device_id: str | None = Field(default=None, max_length=100)


class DeleteIn(BaseModel):
    ids: list[str] = Field(max_length=5000)


class CallbackIn(BaseModel):
    url: str = Field(max_length=8000)


class ModelIn(BaseModel):
    model: str = Field(min_length=1, max_length=200)


class ConnectIn(BaseModel):
    # "iphone": iPhone のアプリが 127.0.0.1 で戻りを受け取る (サーバは待ち受けない)
    client: str | None = Field(default=None, max_length=20)


class VocabularyIn(BaseModel):
    term: str = Field(min_length=1, max_length=100)
    reading: str | None = Field(default=None, max_length=100)
    aliases: list[str] = Field(default_factory=list, max_length=30)
    note: str | None = Field(default=None, max_length=500)


class RunIn(BaseModel):
    day: str | None = Field(default=None, max_length=10)


class SpeakerPatch(BaseModel):
    name: str | None = Field(default=None, max_length=100)
    # true: 「その他」にする (名前を付ける候補に出さない) / false: 候補に戻す
    ignored: bool | None = None


class MergeIn(BaseModel):
    into: int


class AssignIn(BaseModel):
    """話者の指定: 既存の話者 / 名前 (無ければ新しい話者を作る) / 不明"""
    speaker_id: int | None = None
    name: str | None = Field(default=None, max_length=100)
    unknown: bool = False
    # PUT /utterances/{id} 用: 今の話者で合っている
    confirm: bool = False


class RangeAssignIn(AssignIn):
    start: float = Field(ge=0)
    end: float = Field(gt=0)


class ReassignIn(AssignIn):
    # この話者 (None は「不明」) の部分を付け替える。from_label を指定したらそのラベルだけ
    from_speaker_id: int | None = None
    from_label: str | None = Field(default=None, max_length=16)
    # 名前で指定 (iPhone だけで名前を付けた人など、ID を知らないとき)
    from_name: str | None = Field(default=None, max_length=64)


class NoteIn(BaseModel):
    text: str = Field(max_length=1024 * 1024)
    agent: str | None = Field(default=None, max_length=100)


class CompareVoteIn(BaseModel):
    id: str = Field(max_length=200)
    choice: str = Field(max_length=16)


class ComparePreferenceIn(BaseModel):
    preference: str = Field(max_length=16)


def _decode_metadata(header: str | None) -> dict[str, Any]:
    if not header:
        raise HTTPException(400, "X-Omi-Metadata header is required")
    try:
        raw = base64.urlsafe_b64decode(header + "=" * (-len(header) % 4))
        meta = json.loads(raw)
    except (binascii.Error, ValueError) as e:
        raise HTTPException(400, f"invalid X-Omi-Metadata: {e}") from e
    if not isinstance(meta, dict) or not meta.get("started_at"):
        raise HTTPException(400, "metadata.started_at is required")
    return meta


def create_app(settings: Settings | None = None, *, engine_factory: Callable[[Settings], Engine] = create_engine,
               diarizer_factory: Callable[[Settings], Any] = Diarizer, start_worker: bool = True,
               chatgpt: ChatGPT | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    settings.ensure_dirs()
    tokens = [t.encode() for t in settings.resolve_tokens()]
    db = Database(settings.data_dir / "omi.sqlite3")
    worker = TranscriptionWorker(db, settings, engine_factory, diarizer_factory)
    notes = NotesStore(settings.data_dir)
    gpt = chatgpt or ChatGPT(settings.data_dir)
    ai = AiRunner(settings, gpt)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        if start_worker:
            worker.start()
        yield
        worker.stop()
        gpt.stop_listener()
        db.close()

    app = FastAPI(title="Omi Home Server", version=__version__, lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)
    app.state.db = db
    app.state.worker = worker
    app.state.chatgpt = gpt
    app.state.ai = ai
    app.state.settings = settings

    def auth(request: Request) -> None:
        header = request.headers.get("authorization", "")
        scheme, _, token = header.partition(" ")
        if scheme.lower() != "bearer" or not any(hmac.compare_digest(token.encode(), t) for t in tokens):
            raise HTTPException(401, "invalid token", headers={"WWW-Authenticate": "Bearer"})

    def check_id(seg_id: str) -> str:
        if not SEGMENT_ID.match(seg_id):
            raise HTTPException(400, "invalid segment id")
        return seg_id

    def should_transcribe(requested: bool) -> bool:
        if not worker.transcription_enabled:
            return False
        return settings.transcribe_policy == "always" or (settings.transcribe_policy == "requested" and requested)

    def segment_view(seg: dict[str, Any]) -> dict[str, Any]:
        out = {k: v for k, v in seg.items() if k != "turns_json"}
        out["turns"] = json.loads(seg.get("turns_json") or "[]")
        out["speakers"] = db.speaker_map(seg["id"])
        out["transcripts"] = enrich(db, seg, db.transcripts_for(seg["id"]))
        out["has_speech"] = has_speech(seg, out["transcripts"])
        return out

    def delete_segment(seg_id: str) -> bool:
        row = db.delete_segment(seg_id)
        if row is None:
            return False
        if row.get("audio_path"):
            audio = settings.data_dir / row["audio_path"]
            audio.unlink(missing_ok=True)
            audio.with_suffix(".json").unlink(missing_ok=True)
        worker.mark_dirty(row["started_at"])
        return True

    def require_segment(seg_id: str) -> dict[str, Any]:
        seg = db.get_segment(check_id(seg_id))
        if seg is None:
            raise HTTPException(404, "not found")
        return seg

    @app.middleware("http")
    async def security_headers(request: Request, call_next):
        response = await call_next(request)
        # 閲覧 UI は外部リソースを一切読み込まない
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; "
            "script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/", response_class=HTMLResponse, include_in_schema=False)
    def index() -> HTMLResponse:
        return HTMLResponse((STATIC / "index.html").read_text(encoding="utf-8"))

    @app.get("/guide.md", include_in_schema=False)
    def guide() -> Response:
        return Response((STATIC / "guide.md").read_text(encoding="utf-8"), media_type="text/markdown; charset=utf-8")

    @app.get("/api/v1/health", dependencies=[Depends(auth)])
    def health() -> dict[str, Any]:
        queues = db.queue_counts()
        return {
            "status": "ok",
            "version": __version__,
            "server_transcription": {
                "engine": settings.stt_engine,
                "model": settings.stt_model or None,
                "policy": settings.transcribe_policy,
                "languages": settings.languages,
                "queue": queues["transcription"],
                "last_error": worker.last_error,
            },
            "diarization": {"enabled": settings.diarization, "queue": queues["diarization"]},
        }

    @app.put("/api/v1/segments/{seg_id}/audio", dependencies=[Depends(auth)])
    async def put_audio(seg_id: str, request: Request) -> dict[str, Any]:
        check_id(seg_id)
        meta = _decode_metadata(request.headers.get("x-omi-metadata"))
        if meta.get("id", seg_id) != seg_id:
            raise HTTPException(400, "metadata.id does not match the URL")
        rel = audio_relpath(seg_id, meta["started_at"])
        dest = settings.data_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(".upload")

        hasher = hashlib.sha256()
        size = 0
        with tmp.open("wb") as f:
            async for chunk in request.stream():
                size += len(chunk)
                if size > settings.max_upload_bytes:
                    f.close()
                    tmp.unlink(missing_ok=True)
                    raise HTTPException(413, "upload too large")
                hasher.update(chunk)
                f.write(chunk)
        digest = hasher.hexdigest()
        expected = request.headers.get("x-content-sha256")
        if expected and not hmac.compare_digest(expected.lower(), digest):
            tmp.unlink(missing_ok=True)
            raise HTTPException(400, "sha256 mismatch")
        with tmp.open("rb") as f:
            magic = f.read(4)
        if magic != b"OggS":
            tmp.unlink(missing_ok=True)
            raise HTTPException(400, "body must be an Ogg Opus file")

        previous = db.get_segment(seg_id)
        tmp.replace(dest)
        db.upsert_segment(seg_id, meta, audio_path=str(rel), sha256=digest, size=size)

        unchanged = previous is not None and previous.get("audio_sha256") == digest
        active = ("queued", "running", "done")
        stt_status = (previous or {}).get("server_stt_status", "none")
        requested = request.headers.get("x-omi-transcribe") == "1" or bool(meta.get("transcription_requested"))
        if should_transcribe(requested) and not (unchanged and stt_status in active):
            db.set_stt_status(seg_id, "queued")
            stt_status = "queued"
        diar_status = (previous or {}).get("diarization_status", "none")
        if worker.diarization_enabled and not (unchanged and diar_status in active):
            db.set_diarization_status(seg_id, "queued")
            diar_status = "queued"
        worker.mark_dirty(meta["started_at"])
        write_sidecar(db, settings, seg_id)
        return {"id": seg_id, "stored": True, "sha256": digest, "bytes": size,
                "server_transcription": stt_status, "diarization": diar_status}

    @app.put("/api/v1/segments/{seg_id}/device-transcript", dependencies=[Depends(auth)])
    def put_device_transcript(seg_id: str, body: TranscriptIn) -> dict[str, Any]:
        check_id(seg_id)
        if db.get_segment(seg_id) is None:
            # 音声より先に届いた場合はアプリが再送する
            raise HTTPException(409, "upload audio first")
        db.put_transcript(seg_id, "device", engine=body.engine, locale=body.locale,
                          pieces=[p.model_dump(exclude_none=True) for p in body.pieces], created_at=body.created_at)
        write_sidecar(db, settings, seg_id)
        worker.mark_dirty(db.get_segment(seg_id)["started_at"])
        return {"id": seg_id, "stored": True}

    @app.post("/api/v1/segments/{seg_id}/transcribe", dependencies=[Depends(auth)])
    def request_transcription(seg_id: str) -> dict[str, Any]:
        require_segment(seg_id)
        if not worker.transcription_enabled:
            raise HTTPException(409, "server transcription is disabled (OMI_STT_ENGINE=none)")
        db.set_stt_status(seg_id, "queued")
        worker.notify()
        return {"id": seg_id, "server_transcription": "queued"}

    @app.post("/api/v1/segments/{seg_id}/diarize", dependencies=[Depends(auth)])
    def request_diarization(seg_id: str) -> dict[str, Any]:
        require_segment(seg_id)
        if not worker.diarization_enabled:
            raise HTTPException(409, "diarization is disabled (OMI_DIARIZATION=0)")
        db.set_diarization_status(seg_id, "queued")
        worker.notify()
        return {"id": seg_id, "diarization": "queued"}

    # --- 話者の指定 -------------------------------------------------------

    def resolve_target(body: AssignIn, embedding: Callable[[], Any]) -> int | None:
        """指定された話者の ID。新しい名前なら、声の特徴から話者を作る (取れなければ 409)。"""
        name = (body.name or "").strip()
        if body.unknown or name == OTHER:
            return None
        if body.speaker_id is not None:
            if not db.speaker_exists(body.speaker_id):
                raise HTTPException(404, "speaker not found")
            return body.speaker_id
        if not name:
            raise HTTPException(400, "speaker_id, name, unknown のどれかを指定してください")
        found = db.find_speaker_by_name(name)
        if found is not None:
            return found
        emb = embedding()
        if emb is None:
            raise HTTPException(409, "発話が短すぎて新しい話者として登録できません。既にいる話者の名前を指定してください")
        return db.create_speaker(emb, 1.0, name=name)

    def embedding_near(seg: dict[str, Any], start: float, end: float) -> Any:
        """範囲の半分以上と重なる発話の声の特徴"""
        best, best_overlap = None, 0.0
        for u in db.utterances_for(seg["id"]):
            overlap = min(end, u["end_s"]) - max(start, u["start_s"])
            if u["embedding"] is not None and overlap > best_overlap:
                best, best_overlap = u["embedding"], overlap
        return best if best is not None and best_overlap >= 0.5 * (end - start) else None

    def placeholder_embedding() -> Any:
        """声の特徴はあとで (ワーカーが範囲の音声から) 埋める。それまでは誰とも一致しない"""
        dim = db.embedding_dim()
        return np.zeros(dim, dtype=np.float32) if dim else None

    def speakers_changed(seg: dict[str, Any]) -> None:
        write_sidecar(db, settings, seg["id"])
        worker.mark_dirty(seg["started_at"])
        worker.mark_model_dirty()

    @app.put("/api/v1/segments/{seg_id}/speakers/{label}", dependencies=[Depends(auth)])
    def assign_speaker(seg_id: str, label: str, body: AssignIn) -> dict[str, Any]:
        seg = require_segment(seg_id)
        if not LABEL.match(label):
            raise HTTPException(400, "invalid label")
        turns = [t for t in json.loads(seg.get("turns_json") or "[]") if t["label"] == label]
        if turns:
            db.ensure_segment_speaker(seg_id, label, sum(t["end"] - t["start"] for t in turns))
        elif label not in db.speaker_map(seg_id):
            raise HTTPException(404, "speaker label not found in segment")
        found = db.segment_speaker_embedding(seg_id, label)
        speaker_id = resolve_target(body, lambda: found[0] if found else None)
        db.assign_segment_speaker(seg_id, label, speaker_id)
        speakers_changed(seg)
        return {"id": seg_id, "label": label, "speaker_id": speaker_id}

    @app.put("/api/v1/segments/{seg_id}/utterances", dependencies=[Depends(auth)])
    def assign_range(seg_id: str, body: RangeAssignIn) -> dict[str, Any]:
        seg = require_segment(seg_id)
        if body.end <= body.start or body.end - body.start > 600:
            raise HTTPException(400, "invalid range")
        def embedding() -> Any:
            found = embedding_near(seg, body.start, body.end)
            if found is None and body.end - body.start >= MIN_UTTERANCE_SECONDS:
                found = placeholder_embedding()
            return found

        speaker_id = resolve_target(body, embedding)
        turns = json.loads(seg.get("turns_json") or "[]")
        label = label_for(body.start, body.end, turns) if turns else None
        uid = db.add_manual_utterance(seg_id, body.start, body.end, label, speaker_id)
        speakers_changed(seg)
        return {"id": uid, "segment_id": seg_id, "speaker_id": speaker_id}

    @app.put("/api/v1/utterances/{uid}", dependencies=[Depends(auth)])
    def assign_utterance(uid: int, body: AssignIn) -> dict[str, Any]:
        u = db.get_utterance(uid)
        if u is None:
            raise HTTPException(404, "not found")
        seg = require_segment(u["segment_id"])
        if body.confirm:
            speaker_id = u["speaker_id"]
        else:
            speaker_id = resolve_target(body, lambda: u["embedding"] if u["embedding"] is not None
                                        else embedding_near(seg, u["start_s"], u["end_s"]))
        db.set_utterance_manual(uid, speaker_id)
        speakers_changed(seg)
        return {"id": uid, "segment_id": u["segment_id"], "speaker_id": speaker_id}

    @app.post("/api/v1/segments/{seg_id}/reassign", dependencies=[Depends(auth)])
    def reassign(seg_id: str, body: ReassignIn) -> dict[str, Any]:
        seg = require_segment(seg_id)
        smap = db.speaker_map(seg_id)
        if body.from_name is not None:
            found = db.find_speaker_by_name(body.from_name)
            if found is None:
                raise HTTPException(404, f"「{body.from_name}」という人はいません")
            body.from_speaker_id = found
        if body.from_label is not None:
            labels = [body.from_label] if body.from_label in smap else []
            utterances: list[dict[str, Any]] = []
        else:
            labels = [label for label, info in smap.items() if info["speaker_id"] == body.from_speaker_id]
            # 発話ごとに指定・付け替えられた部分も、今その人になっているものは一緒に直す
            utterances = [u for u in db.utterances_for(seg_id)
                          if u["speaker_id"] == body.from_speaker_id and (u["manual"] or u["auto_speaker_id"] is not None)]
        if not labels and not utterances:
            raise HTTPException(404, "その話者はこの録音にいません")

        def embedding() -> Any:
            for label in labels:
                found = db.segment_speaker_embedding(seg_id, label)
                if found:
                    return found[0]
            return next((u["embedding"] for u in utterances if u["embedding"] is not None), None)

        speaker_id = resolve_target(body, embedding)
        for label in labels:
            db.assign_segment_speaker(seg_id, label, speaker_id)
        for u in utterances:
            db.set_utterance_manual(u["id"], speaker_id)
        speakers_changed(seg)
        return {"id": seg_id, "labels": len(labels), "utterances": len(utterances), "speaker_id": speaker_id}

    @app.get("/api/v1/segments/{seg_id}/clip", dependencies=[Depends(auth)])
    def clip(seg_id: str, start: float, end: float, pad: float = 0.25) -> Response:
        """発話を確かめるための短い音声 (16 kHz モノラルの WAV)"""
        seg = require_segment(seg_id)
        if not seg.get("audio_path"):
            raise HTTPException(404, "not found")
        if end <= start or end - start > 120 or start < 0:
            raise HTTPException(400, "invalid range")
        audio = load_audio(settings.data_dir / seg["audio_path"])
        a = max(0, int((start - max(pad, 0)) * SAMPLE_RATE))
        b = min(len(audio), int((end + max(pad, 0)) * SAMPLE_RATE))
        pcm = (np.clip(audio[a:b], -1, 1) * 32767).astype("<i2").tobytes()
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SAMPLE_RATE)
            w.writeframes(pcm)
        return Response(buf.getvalue(), media_type="audio/wav")

    @app.delete("/api/v1/segments/{seg_id}", dependencies=[Depends(auth)])
    def delete_one(seg_id: str) -> dict[str, Any]:
        if not delete_segment(check_id(seg_id)):
            raise HTTPException(404, "not found")
        return {"deleted": [seg_id]}

    @app.post("/api/v1/segments/delete", dependencies=[Depends(auth)])
    def delete_many(body: DeleteIn) -> dict[str, Any]:
        deleted = [i for i in body.ids if SEGMENT_ID.match(i) and delete_segment(i)]
        return {"deleted": deleted}

    @app.put("/api/v1/markers/{marker_id}", dependencies=[Depends(auth)])
    def put_marker(marker_id: str, body: MarkerIn) -> dict[str, Any]:
        if not MARKER_ID.match(marker_id):
            raise HTTPException(400, "invalid marker id")
        if body.kind not in MARKER_KINDS:
            raise HTTPException(400, f"kind must be one of {MARKER_KINDS}")
        try:
            at = parse_iso(body.at)
        except ValueError as e:
            raise HTTPException(400, f"invalid at: {e}") from e
        at_iso = at.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        db.put_marker(marker_id, body.kind, at_iso, body.device_id)
        worker.mark_dirty(at_iso)
        return {"id": marker_id, "stored": True}

    @app.get("/api/v1/markers", dependencies=[Depends(auth)])
    def list_markers(start: str | None = None, end: str | None = None) -> dict[str, Any]:
        return {"markers": db.list_markers(start, end)}

    @app.delete("/api/v1/markers/{marker_id}", dependencies=[Depends(auth)])
    def delete_marker(marker_id: str) -> dict[str, Any]:
        m = db.get_marker(marker_id) if MARKER_ID.match(marker_id) else None
        if m is None or not db.delete_marker(marker_id):
            raise HTTPException(404, "not found")
        worker.mark_dirty(m["at"])
        return {"deleted": marker_id}

    @app.get("/api/v1/segments", dependencies=[Depends(auth)])
    def list_segments(start: str | None = None, end: str | None = None, limit: int = 500) -> dict[str, Any]:
        return {"segments": [segment_view(s) for s in db.list_segments(start, end, min(max(limit, 1), 5000))]}

    @app.get("/api/v1/segments/{seg_id}", dependencies=[Depends(auth)])
    def get_segment(seg_id: str) -> dict[str, Any]:
        return segment_view(require_segment(seg_id))

    @app.get("/api/v1/segments/{seg_id}/audio", dependencies=[Depends(auth)])
    def get_audio(seg_id: str) -> FileResponse:
        seg = require_segment(seg_id)
        if not seg.get("audio_path"):
            raise HTTPException(404, "not found")
        return FileResponse(settings.data_dir / seg["audio_path"], media_type="audio/ogg")

    def utterance_view(u: dict[str, Any], model: Any, pieces_by_segment: dict[str, list[dict[str, Any]]]) -> dict[str, Any]:
        if u["segment_id"] not in pieces_by_segment:
            chosen = choose_transcript(db.transcripts_for(u["segment_id"]), compare.preference(db))
            pieces_by_segment[u["segment_id"]] = chosen["pieces"] if chosen else []
        texts = []
        for p in pieces_by_segment[u["segment_id"]]:
            overlap = min(u["end_s"], p["end"]) - max(u["start_s"], p["start"])
            if overlap > 0 and overlap >= 0.3 * max(p["end"] - p["start"], 1e-3):
                texts.append(p["text"])
        at = parse_iso(u["started_at"]) + timedelta(seconds=u["start_s"])
        sid = u["speaker_id"]
        below = speaker_model.suspicious_below(model, sid) if sid is not None else None
        return {
            "id": u["id"], "segment_id": u["segment_id"], "start": round(u["start_s"], 2), "end": round(u["end_s"], 2),
            "at": at.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            "text": " ".join(texts), "speaker_id": sid, "manual": bool(u["manual"]),
            "score": None if u["score"] is None else round(u["score"], 3),
            "suspicious": bool(not u["manual"] and u["score"] is not None and below is not None and u["score"] < below),
        }

    @app.get("/api/v1/speakers", dependencies=[Depends(auth)])
    def list_speakers() -> dict[str, Any]:
        model = worker.speaker_model
        counts: dict[int, dict[str, int]] = {}
        named = db.named_speakers()
        for u in db.all_utterances():
            sid = u["speaker_id"]
            if sid is None or u["end_s"] <= u["start_s"]:
                continue
            c = counts.setdefault(sid, {"utterances": 0, "confirmed": 0, "suspicious": 0})
            c["utterances"] += 1
            c["confirmed"] += int(bool(u["manual"]))
            # 確かめるのは名前のある人の発話だけ (「その他」は確かめなくてよい)
            if sid in named and not u["manual"] and u["score"] is not None \
                    and u["score"] < speaker_model.suspicious_below(model, sid):
                c["suspicious"] += 1
        speakers = db.list_speakers()
        for s in speakers:
            s.update(counts.get(s["id"], {"utterances": 0, "confirmed": 0, "suspicious": 0}))
            s["learned"] = model is not None and s["id"] in model
            s["threshold"] = round(model.review_threshold(s["id"]), 3) if s["learned"] else None
        return {"speakers": speakers, "model": speaker_model.model_info(db), "training": worker.model_pending}

    # ---- 文字起こしの聞き比べ ----------------------------------------------

    @app.get("/api/v1/compare/stt", dependencies=[Depends(auth)])
    def compare_next(count: int = 10) -> dict[str, Any]:
        return compare.next_pairs(db, count=min(max(count, 1), 50))

    @app.post("/api/v1/compare/stt/vote", dependencies=[Depends(auth)])
    def compare_vote(body: CompareVoteIn) -> dict[str, Any]:
        try:
            return compare.vote(db, body.id, body.choice)
        except KeyError:
            raise HTTPException(404, "この範囲の文字起こしが見つかりません") from None
        except ValueError as e:
            raise HTTPException(400, str(e)) from None

    @app.delete("/api/v1/compare/stt/vote/{pair_id:path}", dependencies=[Depends(auth)])
    def compare_undo(pair_id: str) -> dict[str, Any]:
        compare.undo(db, pair_id)
        return compare.summary(db)

    @app.put("/api/v1/compare/stt/preference", dependencies=[Depends(auth)])
    def compare_preference(body: ComparePreferenceIn) -> dict[str, Any]:
        try:
            compare.set_preference(db, body.preference)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        worker.mark_dirty(all_days=True)  # 書き出し (timeline/) を作り直す
        return compare.summary(db)

    @app.get("/api/v1/speakers/voices", dependencies=[Depends(auth)])
    def speaker_voices(since: str | None = None) -> dict[str, Any]:
        payload = speaker_model.voices_payload(
            db, worker.speaker_model, diarization_threshold=settings.diarization_threshold,
            match_threshold=settings.speaker_match_threshold, min_seconds=settings.speaker_min_seconds,
            embedding_model=models.EMBEDDING.name)
        if since and since == payload["version"]:
            return {"version": payload["version"], "unchanged": True}
        return payload

    @app.get("/api/v1/speakers/{speaker_id}/utterances", dependencies=[Depends(auth)])
    def speaker_utterances(speaker_id: int, filter: str = "suspicious", limit: int = 50) -> dict[str, Any]:
        if not db.speaker_exists(speaker_id):
            raise HTTPException(404, "speaker not found")
        model = worker.speaker_model
        below = speaker_model.suspicious_below(model, speaker_id)
        rows = [u for u in db.all_utterances() if u["speaker_id"] == speaker_id and u["end_s"] > u["start_s"]]
        if filter == "suspicious":
            rows = sorted((u for u in rows if not u["manual"] and u["score"] is not None and u["score"] < below),
                          key=lambda u: u["score"])
        elif filter == "confirmed":
            rows = sorted((u for u in rows if u["manual"]), key=lambda u: (u["started_at"], u["start_s"]), reverse=True)
        else:
            rows = sorted(rows, key=lambda u: (u["started_at"], u["start_s"]), reverse=True)
        cache: dict[str, list[dict[str, Any]]] = {}
        name = db.speaker_names().get(speaker_id)
        return {"speaker": {"id": speaker_id, "display_name": name}, "threshold": round(below, 3),
                "learned": model is not None and speaker_id in model, "total": len(rows),
                "utterances": [utterance_view(u, model, cache) for u in rows[:min(max(limit, 1), 500)]]}

    @app.post("/api/v1/speakers/train", dependencies=[Depends(auth)])
    def train_speakers() -> dict[str, Any]:
        report = worker.retrain()
        return {"model": speaker_model.model_info(db), "labels_changed": report["labels_changed"],
                "utterances_changed": report["utterances_changed"], "segments_changed": len(report["segments"])}

    def check_new_name(speaker_id: int, name: str) -> None:
        if name == OTHER:
            raise HTTPException(400, f"「{OTHER}」は名前に使えません。名前のない声はすべて「{OTHER}」と表示します")
        same = db.find_speaker_by_name(name)
        if same is not None and same != speaker_id:
            raise HTTPException(409, f"「{name}」はもういます。同じ人なら「同じ人としてまとめる」を使ってください")

    def speakers_renamed() -> None:
        worker.mark_dirty(all_days=True)
        worker.mark_model_dirty()  # 名前の付いた話者は学習の対象になる

    @app.patch("/api/v1/speakers/{speaker_id}", dependencies=[Depends(auth)])
    def rename_speaker(speaker_id: int, body: SpeakerPatch) -> dict[str, Any]:
        if not db.speaker_exists(speaker_id):
            raise HTTPException(404, "speaker not found")
        if body.ignored is not None:
            db.set_speaker_ignored(speaker_id, body.ignored)
        if body.name is not None or body.ignored is None:
            name = (body.name or "").strip()
            if name:
                check_new_name(speaker_id, name)
            db.rename_speaker(speaker_id, name or None)
        speakers_renamed()
        return {"id": speaker_id, "name": body.name, "ignored": body.ignored}

    @app.post("/api/v1/speakers/{speaker_id}/assign", dependencies=[Depends(auth)])
    def assign_voice(speaker_id: int, body: AssignIn) -> dict[str, Any]:
        """名前のない声を、すべての録音でまとめて決める: 新しい名前を付ける / 既にいる人にまとめる / 「その他」にする"""
        if not db.speaker_exists(speaker_id):
            raise HTTPException(404, "speaker not found")
        name = (body.name or "").strip()
        if body.unknown or name == OTHER:
            db.set_speaker_ignored(speaker_id, True)
            speakers_renamed()
            return {"id": speaker_id, "speaker_id": None}
        target = body.speaker_id if body.speaker_id is not None else (db.find_speaker_by_name(name) if name else None)
        if target is None:
            if not name:
                raise HTTPException(400, "speaker_id, name, unknown のどれかを指定してください")
            db.rename_speaker(speaker_id, name)
            target = speaker_id
        elif target != speaker_id:
            if not db.merge_speakers(speaker_id, target):
                raise HTTPException(404, "speaker not found")
        speakers_renamed()
        return {"id": speaker_id, "speaker_id": target}

    @app.post("/api/v1/speakers/{speaker_id}/merge", dependencies=[Depends(auth)])
    def merge_speaker(speaker_id: int, body: MergeIn) -> dict[str, Any]:
        if not db.merge_speakers(speaker_id, body.into):
            raise HTTPException(404, "speaker not found (or same speaker)")
        worker.mark_dirty(all_days=True)
        worker.mark_model_dirty()
        return {"merged": speaker_id, "into": body.into}

    # --- AI (Sign in with ChatGPT) ------------------------------------------

    def gpt_error(e: ChatGPTError) -> HTTPException:
        status = 401 if e.reconnect else 429 if e.code == "subscription_sharing_usage_limit_exceeded" else 502
        return HTTPException(status, {"message": e.message, "code": e.code, "reconnect": e.reconnect})

    def timeline_days() -> list[str]:
        return sorted((p.stem for p in (settings.data_dir / "timeline").glob("????-??-??.md")), reverse=True)

    @app.get("/api/v1/ai/status", dependencies=[Depends(auth)])
    def ai_status() -> dict[str, Any]:
        from .exporter import local_tz
        queues = db.queue_counts()
        return {
            "chatgpt": gpt.status(),
            "model": db.get_kv("chatgpt_model"),
            "job": ai.status(),
            "day": nightly.target_day(local_tz(settings)).isoformat(),
            "days": timeline_days()[:14],
            "pending": sum(q.get("queued", 0) + q.get("running", 0) for q in queues.values()),
            "last_run": nightly.last_run(settings.data_dir),
        }

    @app.post("/api/v1/ai/connect", dependencies=[Depends(auth)])
    def ai_connect(request: Request, body: ConnectIn | None = None) -> dict[str, Any]:
        try:
            if body is not None and body.client == "iphone":
                # iPhone は自分の 127.0.0.1 で戻りを受け取り、結果を /ai/callback に送る
                return gpt.start_login(listen=False)
            # 許可のあとの「Omimi に戻る」の行き先 (この Web 画面のまとめ)
            return gpt.start_login(return_url=f"{request.url.scheme}://{request.url.netloc}/#/notes")
        except ChatGPTError as e:
            raise gpt_error(e) from e

    @app.post("/api/v1/ai/callback", dependencies=[Depends(auth)])
    def ai_callback(body: CallbackIn) -> dict[str, Any]:
        try:
            return gpt.complete_from_url(body.url)
        except ChatGPTError as e:
            raise HTTPException(400, {"message": e.message, "code": e.code}) from e

    @app.post("/api/v1/ai/welcomed", dependencies=[Depends(auth)])
    def ai_welcomed() -> dict[str, Any]:
        gpt.dismiss_welcome()
        return gpt.status()

    @app.post("/api/v1/ai/disconnect", dependencies=[Depends(auth)])
    def ai_disconnect() -> dict[str, Any]:
        if ai.running:
            raise HTTPException(409, {"message": "整理が終わってから接続を解除してください"})
        return {"revoked": gpt.sign_out(), "chatgpt": gpt.status()}

    @app.get("/api/v1/ai/models", dependencies=[Depends(auth)])
    def ai_models() -> dict[str, Any]:
        try:
            return {"models": gpt.list_models(), "model": db.get_kv("chatgpt_model")}
        except ChatGPTError as e:
            raise gpt_error(e) from e

    @app.put("/api/v1/ai/model", dependencies=[Depends(auth)])
    def ai_set_model(body: ModelIn) -> dict[str, Any]:
        db.set_kv("chatgpt_model", body.model)
        return {"model": body.model}

    @app.post("/api/v1/ai/run", dependencies=[Depends(auth)])
    def ai_run(body: RunIn) -> dict[str, Any]:
        from datetime import date as date_type

        from .exporter import local_tz
        try:
            day = date_type.fromisoformat(body.day) if body.day else nightly.target_day(local_tz(settings))
        except ValueError as e:
            raise HTTPException(400, {"message": "日付は YYYY-MM-DD で指定してください"}) from e
        status = gpt.status()
        if not status["connected"]:
            raise HTTPException(401, {"message": "ChatGPT とつながっていません。「ChatGPT で続ける」から接続してください",
                                      "reconnect": True})
        try:
            return ai.start(day, db.get_kv("chatgpt_model"))
        except RuntimeError as e:
            raise HTTPException(409, {"message": str(e)}) from e

    # --- 用語集 -------------------------------------------------------------

    def vocabulary_changed() -> None:
        from .vocabulary import Vocabulary
        Vocabulary.load(db).write(settings.data_dir)
        worker.mark_dirty(all_days=True)  # 書き出し (timeline) の補正を作り直す

    def clean_vocabulary(body: VocabularyIn) -> tuple[str, str | None, list[str], str | None]:
        term = body.term.strip()
        if not term:
            raise HTTPException(400, {"message": "正しい表記を入れてください"})
        aliases = []
        for a in body.aliases:
            a = a.strip()
            if a and a != term and a not in aliases:
                aliases.append(a)
        return term, (body.reading or "").strip() or None, aliases, (body.note or "").strip() or None

    @app.get("/api/v1/vocabulary", dependencies=[Depends(auth)])
    def list_vocabulary() -> dict[str, Any]:
        return {"vocabulary": db.list_vocabulary()}

    @app.post("/api/v1/vocabulary", dependencies=[Depends(auth)])
    def add_vocabulary(body: VocabularyIn) -> dict[str, Any]:
        term, reading, aliases, note = clean_vocabulary(body)
        try:
            vid = db.put_vocabulary(None, term, reading, aliases, note)
        except ValueError as e:
            raise HTTPException(409, {"message": f"「{term}」はもう登録されています"}) from e
        vocabulary_changed()
        return db.get_vocabulary(vid)

    @app.put("/api/v1/vocabulary/{vid}", dependencies=[Depends(auth)])
    def update_vocabulary(vid: int, body: VocabularyIn) -> dict[str, Any]:
        term, reading, aliases, note = clean_vocabulary(body)
        try:
            db.put_vocabulary(vid, term, reading, aliases, note)
        except ValueError as e:
            raise HTTPException(409, {"message": f"「{term}」はもう登録されています"}) from e
        except KeyError as e:
            raise HTTPException(404, {"message": "見つかりません"}) from e
        vocabulary_changed()
        return db.get_vocabulary(vid)

    @app.delete("/api/v1/vocabulary/{vid}", dependencies=[Depends(auth)])
    def delete_vocabulary(vid: int) -> dict[str, Any]:
        if not db.delete_vocabulary(vid):
            raise HTTPException(404, {"message": "見つかりません"})
        vocabulary_changed()
        return {"deleted": vid}

    @app.get("/api/v1/stats", dependencies=[Depends(auth)])
    def get_stats(days: int = 30) -> dict[str, Any]:
        return stats_module.compute(db, settings, days)

    @app.get("/api/v1/notes", dependencies=[Depends(auth)])
    def list_notes(request: Request) -> dict[str, Any]:
        # iPhone がまとめを取りに来た時刻 (「今夜の状況」の最後の段に出す)
        if request.headers.get("user-agent", "").startswith("omi-original-app/"):
            db.set_kv(stats_module.IPHONE_NOTES_PULL, now_iso())
        return {"notes": notes.list()}

    @app.put("/api/v1/notes/{name:path}", dependencies=[Depends(auth)])
    def put_note(name: str, body: NoteIn) -> dict[str, Any]:
        try:
            entry = notes.write(name, body.text)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        if entry["kind"] == "day":
            # 「蓄積」の最後の整理にも出す
            nightly.append_run(settings.data_dir, {
                "started_at": now_iso(), "finished_at": now_iso(), "day": entry["date"], "status": "ok",
                "agent": body.agent or "chatgpt@iphone", "note": f"notes/{name}",
                "message": "iPhone が ChatGPT に頼んでまとめを書きました"})
        return entry

    @app.get("/api/v1/ai/materials", dependencies=[Depends(auth)])
    def ai_materials(day: str) -> dict[str, Any]:
        try:
            target = date.fromisoformat(day)
        except ValueError:
            raise HTTPException(400, "day は YYYY-MM-DD") from None
        request = nightly.chatgpt_request(settings, target)
        if request is None:
            raise HTTPException(404, "この日の記録がありません")
        return request

    @app.get("/api/v1/notes/{name:path}", dependencies=[Depends(auth)])
    def get_note(name: str) -> dict[str, Any]:
        note = notes.read(name)
        if note is None:
            raise HTTPException(404, "not found")
        return note

    @app.get("/api/v1/search", dependencies=[Depends(auth)])
    def search(q: str, limit: int = 100) -> dict[str, Any]:
        if not q.strip():
            return {"results": []}
        results = db.search(q.strip(), min(max(limit, 1), 1000))
        for r in results:
            seg = db.get_segment(r["segment_id"])
            if seg:
                enrich(db, seg, [r])
        return {"results": results}

    return app
