"""SQLite による保存。音声ファイル本体はファイルシステムに置き、ここではメタデータと文字起こしを持つ。"""

from __future__ import annotations

import json
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

import numpy as np

SCHEMA = """
CREATE TABLE IF NOT EXISTS segments (
    id               TEXT PRIMARY KEY,
    source           TEXT,
    device_id        TEXT,
    device_name      TEXT,
    firmware         TEXT,
    codec            TEXT,
    sample_rate      INTEGER,
    started_at       TEXT NOT NULL,
    ended_at         TEXT,
    duration_seconds REAL,
    frame_count      INTEGER,
    concealed_frames INTEGER,
    audio_path       TEXT,
    audio_sha256     TEXT,
    audio_bytes      INTEGER,
    received_at      TEXT NOT NULL,
    server_stt_status TEXT NOT NULL DEFAULT 'none',  -- none | queued | running | done | failed
    server_stt_error  TEXT
);
CREATE INDEX IF NOT EXISTS segments_started_at ON segments(started_at);
CREATE INDEX IF NOT EXISTS segments_stt_status ON segments(server_stt_status);

CREATE TABLE IF NOT EXISTS transcripts (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    segment_id  TEXT NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
    origin      TEXT NOT NULL,   -- device | server
    engine      TEXT,
    locale      TEXT,
    created_at  TEXT NOT NULL,
    text        TEXT NOT NULL,
    pieces_json TEXT NOT NULL,
    UNIQUE(segment_id, origin)
);

-- 話者プロファイル (同じ人を録音をまたいで識別する)
CREATE TABLE IF NOT EXISTS speakers (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT,              -- NULL なら「話者 <id>」
    embedding   BLOB NOT NULL,     -- 正規化した float32 の平均ベクトル
    weight      REAL NOT NULL,     -- 平均に使った発話秒数 (上限あり)
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL,
    merged_into INTEGER REFERENCES speakers(id)
);

-- セグメント内の話者ラベル → 話者プロファイル
CREATE TABLE IF NOT EXISTS segment_speakers (
    segment_id  TEXT NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
    label       TEXT NOT NULL,
    speaker_id  INTEGER REFERENCES speakers(id),
    seconds     REAL NOT NULL,
    similarity  REAL,
    embedding   BLOB,
    PRIMARY KEY (segment_id, label)
);
CREATE INDEX IF NOT EXISTS segment_speakers_speaker ON segment_speakers(speaker_id);

-- Omi のボタンで付けた印 (highlight=注目, split=区切り, memo=メモ)
CREATE TABLE IF NOT EXISTS markers (
    id          TEXT PRIMARY KEY,
    kind        TEXT NOT NULL,
    at          TEXT NOT NULL,
    device_id   TEXT,
    received_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS markers_at ON markers(at);

-- 発話 (同じ話者が続けて話した区間) ごとの声の特徴と話者。
-- 話者は「人が指定したもの (manual)」→「学習したモデルが付けたもの (auto_speaker_id)」→「話者分離のラベルの話者」の順に決まる。
CREATE TABLE IF NOT EXISTS utterances (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    segment_id        TEXT NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
    start_s           REAL NOT NULL,
    end_s             REAL NOT NULL,
    label             TEXT,
    embedding         BLOB,            -- 声の特徴 (NULL は未計算、空は短すぎて取れなかった)
    auto_speaker_id   INTEGER,         -- モデルがラベルと別の人と判断したときの話者
    score             REAL,            -- 今の話者らしさ (高いほどその人らしい)
    manual            INTEGER NOT NULL DEFAULT 0,  -- 1 = 人が指定・確認した
    manual_speaker_id INTEGER,         -- manual=1 のときの話者 (NULL は「不明」)
    updated_at        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS utterances_segment ON utterances(segment_id);

-- 用語集: 人名・専門用語など、文字起こしで間違えやすい語
CREATE TABLE IF NOT EXISTS vocabulary (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    term         TEXT NOT NULL UNIQUE,   -- 正しい表記
    reading      TEXT,                   -- 読み (ひらがな・カタカナ)
    aliases_json TEXT NOT NULL DEFAULT '[]',  -- よく間違う表記
    note         TEXT,                   -- 説明 (AI に渡す)
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);

-- ちょっとした状態 (iPhone が最後にまとめを受け取った時刻など)
CREATE TABLE IF NOT EXISTS kv (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- 文字起こしの聞き比べ (Apple と Whisper のどちらが正しいか、人が聞いて選んだ結果)
CREATE TABLE IF NOT EXISTS stt_votes (
    pair_id      TEXT PRIMARY KEY,
    segment_id   TEXT NOT NULL,
    start_s      REAL NOT NULL,
    end_s        REAL NOT NULL,
    apple_text   TEXT NOT NULL,
    whisper_text TEXT NOT NULL,
    winner       TEXT NOT NULL,   -- apple | whisper | same | neither
    created_at   TEXT NOT NULL
);
"""

# 既存の DB に後から追加した列
MIGRATIONS = {
    "segments": {
        "diarization_status": "TEXT NOT NULL DEFAULT 'none'",
        "diarization_error": "TEXT",
        "turns_json": "TEXT",
    },
    # 1 = 人がこのラベルの話者を指定した (学習で付け直さない)
    "segment_speakers": {"manual": "INTEGER NOT NULL DEFAULT 0"},
    # 1 = 「その他」にした声 (アナウンス・店員など。名前を付ける候補に出さない)
    "speakers": {"ignored": "INTEGER NOT NULL DEFAULT 0"},
}

# 名前を付けていない人 (店員・アナウンス・通りすがりなど) の表示名。人の名前には使えない。
OTHER = "その他"
# 「よく聞く声」(名前を付ける候補) とみなす、聞いた日数と合計秒数
CANDIDATE_DAYS = 2
CANDIDATE_SECONDS = 60.0

SEGMENT_FIELDS = (
    "source", "device_id", "device_name", "firmware", "codec", "sample_rate", "started_at", "ended_at",
    "duration_seconds", "frame_count", "concealed_frames",
)

# 平均ベクトルに使う発話秒数の上限 (古い声の影響を少しずつ薄める)
WEIGHT_CAP = 600.0


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _blob(v: np.ndarray) -> bytes:
    return np.asarray(v, dtype=np.float32).tobytes()


def _vec(b: bytes) -> np.ndarray:
    return np.frombuffer(b, dtype=np.float32)


def _normalize(v: np.ndarray) -> np.ndarray:
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else v


def speaker_display_name(speaker_id: int | None, name: str | None) -> str | None:
    """名前を付けた人はその名前、名前のない声は「その他」"""
    if speaker_id is None:
        return None
    return name or OTHER


class Database:
    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.RLock()
        # 夜の整理や CLI など、ほかのプロセスが書いている間は待つ (既定の 5 秒では足りないことがある)
        self._conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None, timeout=60)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._conn.executescript(SCHEMA)
        self._migrate()
        # 用語集を変えるたびに増やす (読み出し側のキャッシュを捨てる目安)
        self.vocabulary_version = 0

    def _migrate(self) -> None:
        with self._lock:
            for table, columns in MIGRATIONS.items():
                existing = {r["name"] for r in self._conn.execute(f"PRAGMA table_info({table})")}
                for name, decl in columns.items():
                    if name not in existing:
                        self._conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {decl}")

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    @contextmanager
    def tx(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            self._conn.execute("BEGIN IMMEDIATE")
            try:
                yield self._conn
            except BaseException:
                self._conn.execute("ROLLBACK")
                raise
            self._conn.execute("COMMIT")

    def query(self, sql: str, params: tuple | list = ()) -> list[sqlite3.Row]:
        with self._lock:
            return self._conn.execute(sql, params).fetchall()

    # --- segments -------------------------------------------------------

    def upsert_segment(self, seg_id: str, meta: dict[str, Any], *, audio_path: str, sha256: str, size: int) -> None:
        values = {k: meta.get(k) for k in SEGMENT_FIELDS}
        if not values.get("started_at"):
            raise ValueError("started_at is required")
        cols = ", ".join(SEGMENT_FIELDS)
        placeholders = ", ".join("?" for _ in SEGMENT_FIELDS)
        updates = ", ".join(f"{k}=excluded.{k}" for k in SEGMENT_FIELDS)
        with self.tx() as c:
            c.execute(
                f"""INSERT INTO segments (id, {cols}, audio_path, audio_sha256, audio_bytes, received_at)
                    VALUES (?, {placeholders}, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET {updates},
                      audio_path=excluded.audio_path, audio_sha256=excluded.audio_sha256,
                      audio_bytes=excluded.audio_bytes, received_at=excluded.received_at""",
                (seg_id, *values.values(), audio_path, sha256, size, now_iso()),
            )

    def get_segment(self, seg_id: str) -> dict[str, Any] | None:
        rows = self.query("SELECT * FROM segments WHERE id=?", (seg_id,))
        return dict(rows[0]) if rows else None

    def list_segments(self, start: str | None, end: str | None, limit: int = 500) -> list[dict[str, Any]]:
        sql = "SELECT * FROM segments WHERE 1=1"
        params: list[Any] = []
        if start:
            sql += " AND started_at >= ?"
            params.append(start)
        if end:
            sql += " AND started_at < ?"
            params.append(end)
        sql += " ORDER BY started_at ASC LIMIT ?"
        params.append(limit)
        return [dict(r) for r in self.query(sql, params)]

    def set_stt_status(self, seg_id: str, status: str, error: str | None = None) -> None:
        with self.tx() as c:
            c.execute("UPDATE segments SET server_stt_status=?, server_stt_error=? WHERE id=?", (status, error, seg_id))

    def set_diarization_status(self, seg_id: str, status: str, error: str | None = None) -> None:
        with self.tx() as c:
            c.execute("UPDATE segments SET diarization_status=?, diarization_error=? WHERE id=?", (status, error, seg_id))

    def next_diarization_job(self) -> dict[str, Any] | None:
        """話者分離待ちのセグメントを 1 つ取り running にする (新しい録音から処理して結果を早く見せる)。"""
        with self.tx() as c:
            row = c.execute("SELECT id FROM segments WHERE diarization_status='queued' "
                            "ORDER BY started_at DESC LIMIT 1").fetchone()
            if row is None:
                return None
            c.execute("UPDATE segments SET diarization_status='running', diarization_error=NULL WHERE id=?", (row["id"],))
            return dict(c.execute("SELECT * FROM segments WHERE id=?", (row["id"],)).fetchone())

    def next_transcription_job(self, wait_for_diarization: bool) -> dict[str, Any] | None:
        """文字起こし待ちのセグメントを 1 つ取り running にする。
        話者ごとに区切って文字起こしするため、話者分離が終わっていないものは後回しにする。"""
        cond = "AND diarization_status NOT IN ('queued', 'running')" if wait_for_diarization else ""
        with self.tx() as c:
            row = c.execute(f"SELECT id FROM segments WHERE server_stt_status='queued' {cond} "
                            "ORDER BY started_at DESC LIMIT 1").fetchone()
            if row is None:
                return None
            c.execute("UPDATE segments SET server_stt_status='running', server_stt_error=NULL WHERE id=?", (row["id"],))
            return dict(c.execute("SELECT * FROM segments WHERE id=?", (row["id"],)).fetchone())

    def requeue_running(self) -> int:
        """前回の異常終了で running のまま残ったものを戻す。"""
        with self.tx() as c:
            n = c.execute("UPDATE segments SET server_stt_status='queued' WHERE server_stt_status='running'").rowcount
            n += c.execute("UPDATE segments SET diarization_status='queued' WHERE diarization_status='running'").rowcount
            return n

    def queue_counts(self) -> dict[str, dict[str, int]]:
        out: dict[str, dict[str, int]] = {}
        for col, key in (("server_stt_status", "transcription"), ("diarization_status", "diarization")):
            rows = self.query(f"SELECT {col} AS s, COUNT(*) AS n FROM segments GROUP BY {col}")
            out[key] = {r["s"]: r["n"] for r in rows}
        return out

    def delete_segment(self, seg_id: str) -> dict[str, Any] | None:
        """セグメントを削除し、削除した行を返す (音声ファイルは呼び出し側で消す)。"""
        with self.tx() as c:
            row = c.execute("SELECT * FROM segments WHERE id=?", (seg_id,)).fetchone()
            if row is None:
                return None
            c.execute("DELETE FROM segments WHERE id=?", (seg_id,))  # 文字起こし・話者の対応も連鎖削除
            return dict(row)

    def segment_days(self) -> list[str]:
        """セグメントのある開始時刻 (UTC ISO) の一覧 (書き出し対象の日を求めるのに使う)。"""
        return [r["started_at"] for r in self.query("SELECT started_at FROM segments")] + \
               [r["at"] for r in self.query("SELECT at FROM markers")]

    def set_turns(self, seg_id: str, turns: list[dict[str, Any]]) -> None:
        with self.tx() as c:
            c.execute("UPDATE segments SET turns_json=? WHERE id=?", (json.dumps(turns), seg_id))

    # --- transcripts ----------------------------------------------------

    def put_transcript(self, seg_id: str, origin: str, *, engine: str, locale: str | None,
                       pieces: list[dict[str, Any]], created_at: str | None = None) -> None:
        text = "\n".join(p["text"] for p in pieces if p.get("text"))
        with self.tx() as c:
            c.execute(
                """INSERT INTO transcripts (segment_id, origin, engine, locale, created_at, text, pieces_json)
                   VALUES (?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(segment_id, origin) DO UPDATE SET engine=excluded.engine, locale=excluded.locale,
                     created_at=excluded.created_at, text=excluded.text, pieces_json=excluded.pieces_json""",
                (seg_id, origin, engine, locale, created_at or now_iso(), text,
                 json.dumps(pieces, ensure_ascii=False)),
            )

    def transcripts_for(self, seg_id: str) -> list[dict[str, Any]]:
        rows = self.query("SELECT * FROM transcripts WHERE segment_id=? ORDER BY origin", (seg_id,))
        out = []
        for r in rows:
            d = dict(r)
            d["pieces"] = json.loads(d.pop("pieces_json"))
            out.append(d)
        return out

    def search(self, q: str, limit: int = 100) -> list[dict[str, Any]]:
        # 個人のライフログ規模なら LIKE で十分 (日本語の部分一致もそのまま効く)
        like = "%" + q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        rows = self.query(
            """SELECT t.segment_id, t.origin, t.engine, t.text, t.pieces_json, s.started_at, s.duration_seconds
               FROM transcripts t JOIN segments s ON s.id = t.segment_id
               WHERE t.text LIKE ? ESCAPE '\\' ORDER BY s.started_at DESC LIMIT ?""",
            (like, limit),
        )
        out = []
        for r in rows:
            d = dict(r)
            d["pieces"] = [p for p in json.loads(d.pop("pieces_json")) if q in p.get("text", "")]
            out.append(d)
        return out

    # --- speakers -------------------------------------------------------

    def speaker_profiles(self) -> list[tuple[int, np.ndarray, float]]:
        rows = self.query("SELECT id, embedding, weight FROM speakers WHERE merged_into IS NULL")
        return [(r["id"], _vec(r["embedding"]), r["weight"]) for r in rows]

    def create_speaker(self, embedding: np.ndarray, weight: float, name: str | None = None) -> int:
        with self.tx() as c:
            cur = c.execute(
                "INSERT INTO speakers (name, embedding, weight, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                (name, _blob(_normalize(embedding)), min(weight, WEIGHT_CAP), now_iso(), now_iso()))
            return int(cur.lastrowid)

    def update_speaker_embedding(self, speaker_id: int, embedding: np.ndarray, weight: float) -> None:
        with self.tx() as c:
            c.execute("UPDATE speakers SET embedding=?, weight=?, updated_at=? WHERE id=?",
                      (_blob(_normalize(embedding)), min(weight, WEIGHT_CAP), now_iso(), speaker_id))

    def rename_speaker(self, speaker_id: int, name: str | None) -> bool:
        """名前を付ける (名前を付けると「その他」から外れる)"""
        with self.tx() as c:
            return c.execute("UPDATE speakers SET name=?, ignored=CASE WHEN ? IS NULL THEN ignored ELSE 0 END, updated_at=? "
                             "WHERE id=? AND merged_into IS NULL",
                             (name or None, name or None, now_iso(), speaker_id)).rowcount > 0

    def set_speaker_ignored(self, speaker_id: int, ignored: bool) -> bool:
        """「その他」にする (名前は外す) / 名前を付ける候補に戻す"""
        with self.tx() as c:
            if ignored:
                sql = "UPDATE speakers SET ignored=1, name=NULL, updated_at=? WHERE id=? AND merged_into IS NULL"
            else:
                sql = "UPDATE speakers SET ignored=0, updated_at=? WHERE id=? AND merged_into IS NULL"
            return c.execute(sql, (now_iso(), speaker_id)).rowcount > 0

    def find_speaker_by_name(self, name: str) -> int | None:
        rows = self.query("SELECT id FROM speakers WHERE name=? AND merged_into IS NULL ORDER BY id LIMIT 1", (name,))
        return rows[0]["id"] if rows else None

    def merge_speakers(self, source: int, target: int) -> bool:
        """source の話者を target にまとめる (同一人物だった場合)。"""
        if source == target:
            return False
        with self.tx() as c:
            rows = {r["id"]: r for r in c.execute(
                "SELECT * FROM speakers WHERE id IN (?, ?) AND merged_into IS NULL", (source, target))}
            if len(rows) != 2:
                return False
            s, t = rows[source], rows[target]
            ws, wt = s["weight"], t["weight"]
            merged = _normalize(_vec(s["embedding"]) * ws + _vec(t["embedding"]) * wt)
            c.execute("UPDATE speakers SET embedding=?, weight=?, name=COALESCE(name, ?), updated_at=? WHERE id=?",
                      (_blob(merged), min(ws + wt, WEIGHT_CAP), s["name"], now_iso(), target))
            c.execute("UPDATE speakers SET merged_into=?, updated_at=? WHERE id=?", (target, now_iso(), source))
            c.execute("UPDATE speakers SET merged_into=? WHERE merged_into=?", (target, source))
            c.execute("UPDATE segment_speakers SET speaker_id=? WHERE speaker_id=?", (target, source))
            c.execute("UPDATE utterances SET auto_speaker_id=? WHERE auto_speaker_id=?", (target, source))
            c.execute("UPDATE utterances SET manual_speaker_id=? WHERE manual_speaker_id=?", (target, source))
            return True

    def list_speakers(self) -> list[dict[str, Any]]:
        rows = self.query(
            """SELECT sp.id, sp.name, sp.ignored, sp.created_at, sp.updated_at,
                      COUNT(ss.segment_id) AS segments, COALESCE(SUM(ss.seconds), 0) AS seconds,
                      MAX(s.started_at) AS last_seen, COUNT(DISTINCT substr(s.started_at, 1, 10)) AS days
               FROM speakers sp
               LEFT JOIN segment_speakers ss ON ss.speaker_id = sp.id
               LEFT JOIN segments s ON s.id = ss.segment_id
               WHERE sp.merged_into IS NULL
               GROUP BY sp.id ORDER BY seconds DESC""")
        out = []
        for r in rows:
            d = dict(r)
            d["display_name"] = speaker_display_name(d["id"], d["name"])
            d["named"] = bool(d["name"])
            d["ignored"] = bool(d["ignored"])
            # 名前のない声のうち、よく聞くもの (名前を付ける候補)
            d["candidate"] = not d["named"] and not d["ignored"] and (
                d["days"] >= CANDIDATE_DAYS or d["seconds"] >= CANDIDATE_SECONDS)
            out.append(d)
        return out

    def replace_segment_speakers(self, seg_id: str, rows: list[dict[str, Any]]) -> None:
        with self.tx() as c:
            c.execute("DELETE FROM segment_speakers WHERE segment_id=?", (seg_id,))
            for r in rows:
                c.execute(
                    """INSERT INTO segment_speakers (segment_id, label, speaker_id, seconds, similarity, embedding)
                       VALUES (?, ?, ?, ?, ?, ?)""",
                    (seg_id, r["label"], r.get("speaker_id"), r["seconds"], r.get("similarity"),
                     _blob(r["embedding"]) if r.get("embedding") is not None else None))

    def ensure_segment_speaker(self, seg_id: str, label: str, seconds: float) -> None:
        """話者分離の区間にはあるが識別されなかった (発話が短い) ラベルの行を作る。"""
        with self.tx() as c:
            c.execute("""INSERT OR IGNORE INTO segment_speakers (segment_id, label, speaker_id, seconds)
                         VALUES (?, ?, NULL, ?)""", (seg_id, label, seconds))

    def assign_segment_speaker(self, seg_id: str, label: str, speaker_id: int | None) -> bool:
        """人がラベルの話者を指定する (None は「不明」)。"""
        with self.tx() as c:
            return c.execute("UPDATE segment_speakers SET speaker_id=?, similarity=NULL, manual=1 "
                             "WHERE segment_id=? AND label=?", (speaker_id, seg_id, label)).rowcount > 0

    def set_label_speaker(self, seg_id: str, label: str, speaker_id: int | None, similarity: float | None) -> None:
        """学習したモデルでラベルの話者を付け直す (人が指定したラベルは変えない)。"""
        with self.tx() as c:
            c.execute("UPDATE segment_speakers SET speaker_id=?, similarity=? WHERE segment_id=? AND label=? AND manual=0",
                      (speaker_id, similarity, seg_id, label))

    def label_rows(self) -> list[dict[str, Any]]:
        """声の特徴があるラベルの一覧 (学習・付け直し用)。"""
        rows = self.query("""SELECT ss.segment_id, ss.label, ss.speaker_id, ss.seconds, ss.manual, ss.embedding
                             FROM segment_speakers ss WHERE ss.embedding IS NOT NULL""")
        return [{**dict(r), "embedding": _vec(r["embedding"])} for r in rows]

    def segment_speaker_embedding(self, seg_id: str, label: str) -> tuple[np.ndarray, float] | None:
        rows = self.query("SELECT embedding, seconds FROM segment_speakers WHERE segment_id=? AND label=?", (seg_id, label))
        if not rows or rows[0]["embedding"] is None:
            return None
        return _vec(rows[0]["embedding"]), rows[0]["seconds"]

    def speaker_map(self, seg_id: str) -> dict[str, dict[str, Any]]:
        """{label: {speaker_id, speaker(表示名), seconds}}"""
        rows = self.query(
            """SELECT ss.label, ss.speaker_id, ss.seconds, sp.name FROM segment_speakers ss
               LEFT JOIN speakers sp ON sp.id = ss.speaker_id WHERE ss.segment_id=?""", (seg_id,))
        return {r["label"]: {"speaker_id": r["speaker_id"], "speaker": speaker_display_name(r["speaker_id"], r["name"]),
                             "seconds": r["seconds"]} for r in rows}

    # --- markers --------------------------------------------------------

    def put_marker(self, marker_id: str, kind: str, at: str, device_id: str | None) -> None:
        with self.tx() as c:
            c.execute(
                """INSERT INTO markers (id, kind, at, device_id, received_at) VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, at=excluded.at, device_id=excluded.device_id""",
                (marker_id, kind, at, device_id, now_iso()))

    def list_markers(self, start: str | None = None, end: str | None = None) -> list[dict[str, Any]]:
        sql, params = "SELECT id, kind, at, device_id FROM markers WHERE 1=1", []
        if start:
            sql += " AND at >= ?"
            params.append(start)
        if end:
            sql += " AND at < ?"
            params.append(end)
        return [dict(r) for r in self.query(sql + " ORDER BY at", params)]

    def get_marker(self, marker_id: str) -> dict[str, Any] | None:
        rows = self.query("SELECT id, kind, at, device_id FROM markers WHERE id=?", (marker_id,))
        return dict(rows[0]) if rows else None

    def delete_marker(self, marker_id: str) -> bool:
        with self.tx() as c:
            return c.execute("DELETE FROM markers WHERE id=?", (marker_id,)).rowcount > 0

    # --- 状態・集計 -----------------------------------------------------

    def set_kv(self, key: str, value: str) -> None:
        with self.tx() as c:
            c.execute("INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                      (key, value))

    def get_kv(self, key: str) -> str | None:
        rows = self.query("SELECT value FROM kv WHERE key=?", (key,))
        return rows[0]["value"] if rows else None

    def stats_rows(self) -> list[dict[str, Any]]:
        """集計用に、全セグメントの時刻・長さ・話し声の手がかりを軽く読む。"""
        rows = self.query("""
            SELECT s.id, s.started_at, s.received_at, s.duration_seconds, s.audio_bytes,
                   s.diarization_status, s.server_stt_status,
                   (SELECT COALESCE(SUM(json_extract(j.value, '$.end') - json_extract(j.value, '$.start')), 0)
                      FROM json_each(COALESCE(s.turns_json, '[]')) j) AS turn_seconds,
                   EXISTS(SELECT 1 FROM transcripts t WHERE t.segment_id = s.id) AS has_transcript,
                   EXISTS(SELECT 1 FROM transcripts t WHERE t.segment_id = s.id AND length(trim(t.text)) > 0) AS has_text
            FROM segments s ORDER BY s.started_at""")
        return [dict(r) for r in rows]

    def transcript_counts(self) -> dict[str, int]:
        return {r["origin"]: r["n"] for r in self.query(
            "SELECT origin, COUNT(*) AS n FROM transcripts WHERE length(trim(text)) > 0 GROUP BY origin")}

    # --- 発話 -----------------------------------------------------------

    UTTERANCE_SELECT = """
        SELECT u.id, u.segment_id, u.start_s, u.end_s, u.label, u.manual, u.manual_speaker_id, u.auto_speaker_id,
               u.score, u.embedding, ss.speaker_id AS label_speaker_id, COALESCE(ss.manual, 0) AS label_manual,
               s.started_at, s.audio_path
        FROM utterances u
        JOIN segments s ON s.id = u.segment_id
        LEFT JOIN segment_speakers ss ON ss.segment_id = u.segment_id AND ss.label = u.label"""

    @staticmethod
    def _utterance(row: sqlite3.Row) -> dict[str, Any]:
        d = dict(row)
        d["embedding"] = _vec(d["embedding"]) if d["embedding"] else None
        d["speaker_id"] = effective_speaker(d)
        return d

    def utterances_for(self, seg_id: str) -> list[dict[str, Any]]:
        rows = self.query(self.UTTERANCE_SELECT + " WHERE u.segment_id=? ORDER BY u.start_s", (seg_id,))
        return [self._utterance(r) for r in rows]

    def get_utterance(self, uid: int) -> dict[str, Any] | None:
        rows = self.query(self.UTTERANCE_SELECT + " WHERE u.id=?", (uid,))
        return self._utterance(rows[0]) if rows else None

    def all_utterances(self, *, with_embedding: bool = False) -> list[dict[str, Any]]:
        cond = " WHERE length(u.embedding) > 0" if with_embedding else ""
        return [self._utterance(r) for r in self.query(self.UTTERANCE_SELECT + cond + " ORDER BY s.started_at, u.start_s")]

    def replace_auto_utterances(self, seg_id: str, rows: list[dict[str, Any]]) -> None:
        """話者分離の結果から作った発話を入れ替える (人が指定した発話は残す)。"""
        with self.tx() as c:
            c.execute("DELETE FROM utterances WHERE segment_id=? AND manual=0", (seg_id,))
            for r in rows:
                c.execute("""INSERT INTO utterances (segment_id, start_s, end_s, label, embedding, updated_at)
                             VALUES (?, ?, ?, ?, ?, ?)""",
                          (seg_id, r["start"], r["end"], r.get("label"),
                           _blob(r["embedding"]) if r.get("embedding") is not None else b"", now_iso()))

    def add_manual_utterance(self, seg_id: str, start: float, end: float, label: str | None,
                             speaker_id: int | None, embedding: np.ndarray | None = None) -> int:
        """人が範囲を指定して話者を付ける。同じ範囲 (半分以上重なる) の指定は置き換える。"""
        with self.tx() as c:
            for r in c.execute("SELECT id, start_s, end_s FROM utterances WHERE segment_id=? AND manual=1", (seg_id,)):
                overlap = min(end, r["end_s"]) - max(start, r["start_s"])
                if overlap > 0 and overlap >= 0.5 * min(end - start, r["end_s"] - r["start_s"]):
                    c.execute("DELETE FROM utterances WHERE id=?", (r["id"],))
            cur = c.execute("""INSERT INTO utterances (segment_id, start_s, end_s, label, embedding, manual,
                                                       manual_speaker_id, updated_at) VALUES (?, ?, ?, ?, ?, 1, ?, ?)""",
                            (seg_id, start, end, label, _blob(embedding) if embedding is not None else None,
                             speaker_id, now_iso()))
            return int(cur.lastrowid)

    def set_utterance_manual(self, uid: int, speaker_id: int | None) -> bool:
        with self.tx() as c:
            return c.execute("UPDATE utterances SET manual=1, manual_speaker_id=?, updated_at=? WHERE id=?",
                             (speaker_id, now_iso(), uid)).rowcount > 0

    def set_utterance_embedding(self, uid: int, embedding: np.ndarray | None) -> None:
        with self.tx() as c:
            # 特徴が取れなかったものは空にして、何度も計算しない
            c.execute("UPDATE utterances SET embedding=? WHERE id=?",
                      (_blob(embedding) if embedding is not None else b"", uid))

    def update_utterance_scores(self, updates: list[tuple[int, int | None, float | None]]) -> None:
        """[(id, auto_speaker_id, score)] をまとめて書く。"""
        with self.tx() as c:
            c.executemany("UPDATE utterances SET auto_speaker_id=?, score=? WHERE id=?",
                          [(a, s, i) for i, a, s in updates])

    def manual_utterances_without_embedding(self, min_seconds: float, limit: int = 20) -> list[dict[str, Any]]:
        rows = self.query(self.UTTERANCE_SELECT + """ WHERE u.manual=1 AND u.embedding IS NULL
                          AND u.end_s - u.start_s >= ? LIMIT ?""", (min_seconds, limit))
        return [self._utterance(r) for r in rows]

    def segments_without_utterances(self, limit: int = 10) -> list[dict[str, Any]]:
        """話者分離は済んでいるが、発話ごとの声の特徴をまだ作っていない録音 (以前の版で処理したもの)。"""
        rows = self.query("""SELECT * FROM segments s WHERE s.diarization_status='done'
                             AND COALESCE(s.turns_json, '[]') != '[]'
                             AND NOT EXISTS (SELECT 1 FROM utterances u WHERE u.segment_id = s.id AND u.manual=0)
                             ORDER BY s.started_at DESC LIMIT ?""", (limit,))
        return [dict(r) for r in rows]

    def speaker_names(self) -> dict[int, str]:
        """{話者 ID: 表示名} (統合済みの話者は含まない)"""
        return {r["id"]: speaker_display_name(r["id"], r["name"])
                for r in self.query("SELECT id, name FROM speakers WHERE merged_into IS NULL")}

    def background_embeddings(self, limit: int = 2000) -> list[np.ndarray]:
        """名前のない人 (「その他」と話者不明) の発話の声の特徴。名前のある人の線を決めるのに、他人の例として使う。"""
        named = set(self.named_speakers())
        out = [u["embedding"] for u in reversed(self.all_utterances(with_embedding=True))
               if u["speaker_id"] not in named and u["end_s"] - u["start_s"] >= 1.5]
        return out[:limit]

    def named_speakers(self) -> dict[int, str]:
        return {r["id"]: r["name"] for r in self.query(
            "SELECT id, name FROM speakers WHERE merged_into IS NULL AND name IS NOT NULL AND name != ''")}

    def embedding_dim(self) -> int | None:
        """声の特徴の次元 (モデルで決まる)"""
        for sql in ("SELECT embedding FROM speakers WHERE merged_into IS NULL LIMIT 1",
                    "SELECT embedding FROM utterances WHERE length(embedding) > 0 LIMIT 1"):
            rows = self.query(sql)
            if rows and rows[0]["embedding"]:
                return len(_vec(rows[0]["embedding"]))
        return None

    def speaker_exists(self, speaker_id: int) -> bool:
        return bool(self.query("SELECT 1 FROM speakers WHERE id=? AND merged_into IS NULL", (speaker_id,)))

    # --- 用語集 ---------------------------------------------------------

    @staticmethod
    def _vocab(row: sqlite3.Row) -> dict[str, Any]:
        d = dict(row)
        d["aliases"] = json.loads(d.pop("aliases_json") or "[]")
        return d

    def list_vocabulary(self) -> list[dict[str, Any]]:
        return [self._vocab(r) for r in self.query("SELECT * FROM vocabulary ORDER BY reading IS NULL, reading, term")]

    def get_vocabulary(self, vid: int) -> dict[str, Any] | None:
        rows = self.query("SELECT * FROM vocabulary WHERE id=?", (vid,))
        return self._vocab(rows[0]) if rows else None

    def put_vocabulary(self, vid: int | None, term: str, reading: str | None, aliases: list[str],
                       note: str | None) -> int:
        """追加 (vid=None) または更新。同じ表記が既にあれば ValueError"""
        with self.tx() as c:
            same = c.execute("SELECT id FROM vocabulary WHERE term=?", (term,)).fetchone()
            if same is not None and same["id"] != vid:
                raise ValueError(term)
            values = (term, reading, json.dumps(aliases, ensure_ascii=False), note, now_iso())
            if vid is None:
                cur = c.execute("""INSERT INTO vocabulary (term, reading, aliases_json, note, updated_at, created_at)
                                   VALUES (?, ?, ?, ?, ?, ?)""", (*values, now_iso()))
                vid = int(cur.lastrowid)
            elif c.execute("UPDATE vocabulary SET term=?, reading=?, aliases_json=?, note=?, updated_at=? WHERE id=?",
                           (*values, vid)).rowcount == 0:
                raise KeyError(vid)
        self.vocabulary_version += 1
        return vid

    def delete_vocabulary(self, vid: int) -> bool:
        with self.tx() as c:
            deleted = c.execute("DELETE FROM vocabulary WHERE id=?", (vid,)).rowcount > 0
        self.vocabulary_version += 1
        return deleted


def effective_speaker(u: dict[str, Any]) -> int | None:
    """発話の話者: 人の指定 → モデルの判断 → 話者分離のラベルの話者"""
    if u.get("manual"):
        return u.get("manual_speaker_id")
    if u.get("auto_speaker_id") is not None:
        return u["auto_speaker_id"]
    return u.get("label_speaker_id")
