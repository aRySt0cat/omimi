"""文字起こしの聞き比べ: iPhone (Apple の音声認識) と自宅サーバ (Whisper) のどちらが正しいかを、人が聞いて決める。

同じ時間の範囲の 2 つの文字起こしを、どちらのものか分からないように A / B で並べ (目隠し)、
人が音声を聞いて良い方を選ぶ。結果を集計して、どちらを優先して使うかを決める材料にする。
A / B の割り当ては範囲ごとに決まった乱数で、投票のときにサーバ側で元に戻す。
"""

from __future__ import annotations

import hashlib
import random
from typing import Any

from .db import Database, now_iso

APPLE, WHISPER = "apple", "whisper"
CHOICES = ("a", "b", "same", "neither")
# 判断に必要な投票の数 (同じくらい・どちらも違うを除く)
MIN_DECIDED = 20
KV_PREFERENCE = "stt_preference"

def _texts(pieces: list[dict[str, Any]], start: float, end: float) -> str:
    """範囲に半分以上入る区間の文"""
    out = []
    for p in pieces:
        length = max(p["end"] - p["start"], 1e-3)
        overlap = min(end, p["end"]) - max(start, p["start"])
        if overlap > 0 and overlap >= 0.5 * length:
            out.append(p["text"].strip())
    return " ".join(t for t in out if t)


def pairs_for(segment_id: str, transcripts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """1 つの録音の、同じ範囲の Apple と Whisper の文字起こしの組。

    範囲は Whisper の区間 (話者分離の発話ごと) を基本にし、Whisper が何も書かなかった Apple の区間も加える
    (Whisper の聞き逃しや、Apple の空耳を比べられるように)。
    """
    by_origin = {t["origin"]: t for t in transcripts}
    device, server = by_origin.get("device"), by_origin.get("server")
    if not device or not server or "whisper" not in (server.get("engine") or ""):
        return []
    apple, whisper = device["pieces"], server["pieces"]
    regions: list[tuple[float, float]] = [(p["start"], p["end"]) for p in whisper if p["text"].strip()]
    for p in apple:
        if not p["text"].strip():
            continue
        mid = (p["start"] + p["end"]) / 2
        if not any(s - 0.3 <= mid <= e + 0.3 for s, e in regions):
            regions.append((p["start"], p["end"]))
    out = []
    for start, end in sorted(regions):
        a, w = _texts(apple, start - 0.3, end + 0.3), _texts(whisper, start - 0.3, end + 0.3)
        if not a and not w:
            continue
        out.append({"id": f"{segment_id}@{start:.2f}", "segment_id": segment_id, "start": round(start, 2),
                    "end": round(end, 2), APPLE: a, WHISPER: w, "identical": _norm(a) == _norm(w)})
    return out


def _norm(text: str) -> str:
    """句読点・空白の違いは同じとみなす"""
    return "".join(ch for ch in text if ch.isalnum()).lower()


def apple_is_a(pair_id: str) -> bool:
    """A / B の割り当て (範囲ごとに決まった、偏りのない乱数)"""
    return hashlib.sha256(pair_id.encode()).digest()[0] % 2 == 0


def blind(pair: dict[str, Any]) -> dict[str, Any]:
    a_first = apple_is_a(pair["id"])
    return {"id": pair["id"], "segment_id": pair["segment_id"], "start": pair["start"], "end": pair["end"],
            "a": pair[APPLE] if a_first else pair[WHISPER], "b": pair[WHISPER] if a_first else pair[APPLE]}


def candidate_segments(db: Database) -> list[dict[str, Any]]:
    rows = db.query(
        """SELECT s.id, s.started_at FROM segments s
           WHERE EXISTS (SELECT 1 FROM transcripts t WHERE t.segment_id = s.id AND t.origin = 'device')
             AND EXISTS (SELECT 1 FROM transcripts t WHERE t.segment_id = s.id AND t.origin = 'server'
                         AND t.engine LIKE '%whisper%')
           ORDER BY s.started_at DESC""")
    return [dict(r) for r in rows]


def all_pairs(db: Database) -> list[dict[str, Any]]:
    out = []
    for seg in candidate_segments(db):
        for p in pairs_for(seg["id"], db.transcripts_for(seg["id"])):
            p["started_at"] = seg["started_at"]
            out.append(p)
    return out


def voted_ids(db: Database) -> set[str]:
    return {r["pair_id"] for r in db.query("SELECT pair_id FROM stt_votes")}


def next_pairs(db: Database, count: int = 10, seed: int | None = None) -> dict[str, Any]:
    """まだ聞いていない、文字起こしが違う組 (いろいろな録音から少しずつ)"""
    pairs = all_pairs(db)
    voted = voted_ids(db)
    todo = [p for p in pairs if not p["identical"] and p["id"] not in voted]
    rng = random.Random(seed)
    rng.shuffle(todo)
    # 同じ録音ばかりにならないよう、録音ごとに 1 つずつ順に取る
    by_seg: dict[str, list[dict[str, Any]]] = {}
    for p in todo:
        by_seg.setdefault(p["segment_id"], []).append(p)
    picked: list[dict[str, Any]] = []
    while len(picked) < count and any(by_seg.values()):
        for seg in list(by_seg):
            if by_seg[seg] and len(picked) < count:
                picked.append(by_seg[seg].pop())
    return {"pairs": [{**blind(p), "started_at": p["started_at"]} for p in picked],
            "remaining": len(todo), "summary": summary(db, pairs)}


def vote(db: Database, pair_id: str, choice: str) -> dict[str, Any]:
    if choice not in CHOICES:
        raise ValueError(f"choice must be one of {CHOICES}")
    segment_id, _, _ = pair_id.rpartition("@")
    pair = next((p for p in pairs_for(segment_id, db.transcripts_for(segment_id)) if p["id"] == pair_id), None)
    if pair is None:
        raise KeyError(pair_id)
    a_first = apple_is_a(pair_id)
    winner = {"a": APPLE if a_first else WHISPER, "b": WHISPER if a_first else APPLE}.get(choice, choice)
    with db.tx() as c:
        c.execute(
            """INSERT INTO stt_votes (pair_id, segment_id, start_s, end_s, apple_text, whisper_text, winner, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(pair_id) DO UPDATE SET winner=excluded.winner, created_at=excluded.created_at""",
            (pair_id, segment_id, pair["start"], pair["end"], pair[APPLE], pair[WHISPER], winner, now_iso()))
    return {"winner": winner, "summary": summary(db)}


def undo(db: Database, pair_id: str) -> None:
    with db.tx() as c:
        c.execute("DELETE FROM stt_votes WHERE pair_id=?", (pair_id,))


def summary(db: Database, pairs: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    pairs = all_pairs(db) if pairs is None else pairs
    counts = {APPLE: 0, WHISPER: 0, "same": 0, "neither": 0}
    for r in db.query("SELECT winner, COUNT(*) AS n FROM stt_votes GROUP BY winner"):
        counts[r["winner"]] = r["n"]
    decided = counts[APPLE] + counts[WHISPER]
    verdict = None
    if decided >= MIN_DECIDED:
        share = counts[WHISPER] / decided
        # 6 割以上なら、その方が良いとみなす (それ未満は差がない)
        verdict = WHISPER if share >= 0.6 else APPLE if share <= 0.4 else "even"
    # 聞かなくても分かる違い: 片方だけが何かを書いた範囲 (聞き逃し・空耳・幻聴)
    only_apple = sum(1 for p in pairs if p[APPLE] and not p[WHISPER])
    only_whisper = sum(1 for p in pairs if p[WHISPER] and not p[APPLE])
    engines = db.query("SELECT DISTINCT engine FROM transcripts WHERE origin='server' AND engine LIKE '%whisper%'")
    return {
        "votes": counts, "decided": decided, "min_decided": MIN_DECIDED, "verdict": verdict,
        "pairs": len(pairs), "identical": sum(1 for p in pairs if p["identical"]),
        "segments": len({p["segment_id"] for p in pairs}),
        "only_apple": only_apple, "only_whisper": only_whisper,
        "whisper_engine": engines[0]["engine"] if engines else None,
        "preference": preference(db),
    }


def preference(db: Database) -> str:
    """書き出し (timeline/) と AI に渡す文字起こしで、どちらを優先するか (既定は Whisper)"""
    value = db.get_kv(KV_PREFERENCE)
    return value if value in (APPLE, WHISPER) else WHISPER


def set_preference(db: Database, value: str) -> None:
    if value not in (APPLE, WHISPER):
        raise ValueError("preference must be apple or whisper")
    db.set_kv(KV_PREFERENCE, value)
