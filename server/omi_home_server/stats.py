"""データの蓄積状況と、夜の整理の流れの進み具合。Web の「蓄積」と iPhone の「まとめ」で使う。"""

from __future__ import annotations

import shutil
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

from .config import Settings
from .db import Database, now_iso, parse_iso
from .exporter import MIN_SPEECH_SECONDS, local_tz
from .nightly import last_run, target_day
from .notes import NotesStore

IPHONE_NOTES_PULL = "iphone_notes_pull_at"


def classify(row: dict[str, Any]) -> bool | None:
    """話し声があるか (exporter.has_speech と同じ判断を、集計用の軽い行で行う)。"""
    if row["has_text"]:
        return True
    if row["diarization_status"] == "done":
        return (row["turn_seconds"] or 0) >= MIN_SPEECH_SECONDS
    if row["server_stt_status"] == "done" or row["has_transcript"]:
        return False
    return None


def talk_seconds(row: dict[str, Any], speech: bool | None) -> float:
    """話した時間。Web と iPhone の「記録」と同じく、話し声のある録音の長さを足す。"""
    return float(row["duration_seconds"] or 0) if speech else 0.0


def _dir_bytes(path: Path) -> int:
    if not path.is_dir():
        return 0
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def compute(db: Database, settings: Settings, days: int = 30, *, today: date | None = None) -> dict[str, Any]:
    tz = local_tz(settings)
    notes = NotesStore(settings.data_dir)
    rows = db.stats_rows()

    per_day: dict[date, Counter[str]] = defaultdict(Counter)
    totals: Counter[str] = Counter()
    for row in rows:
        speech = classify(row)
        talk = talk_seconds(row, speech)
        d = parse_iso(row["started_at"]).astimezone(tz).date()
        c = per_day[d]
        for key, value in (("segments", 1), ("recorded_seconds", row["duration_seconds"] or 0),
                           ("speech_segments", speech is True), ("silent_segments", speech is False),
                           ("pending_segments", speech is None), ("speech_seconds", talk),
                           ("audio_bytes", row["audio_bytes"] or 0)):
            c[key] += value
            totals[key] += value
    for m in db.list_markers():
        d = parse_iso(m["at"]).astimezone(tz).date()
        per_day[d]["markers"] += 1
        per_day[d][f"markers_{m['kind']}"] += 1
        totals["markers"] += 1
        totals[f"markers_{m['kind']}"] += 1

    today = today or datetime.now(tz).date()
    window = [today - timedelta(days=i) for i in range(max(1, min(days, 366)))]
    day_rows = []
    for d in window:
        c = per_day.get(d, Counter())
        day_rows.append({
            "date": d.isoformat(),
            "segments": c["segments"],
            "speech_segments": c["speech_segments"],
            "silent_segments": c["silent_segments"],
            "pending_segments": c["pending_segments"],
            "recorded_seconds": round(c["recorded_seconds"], 1),
            "speech_seconds": round(c["speech_seconds"], 1),
            "markers": c["markers"],
            "note": notes.has_day(d.isoformat()),
        })

    queues = db.queue_counts()
    pending = sum(q.get("queued", 0) + q.get("running", 0) for q in queues.values())
    speakers = db.list_speakers()
    note_list = notes.list()
    db_bytes = sum(p.stat().st_size for p in settings.data_dir.glob("omi.sqlite3*") if p.is_file())
    try:
        disk = shutil.disk_usage(settings.data_dir)
        disk_info = {"disk_free_bytes": disk.free, "disk_total_bytes": disk.total}
    except OSError:
        disk_info = {"disk_free_bytes": None, "disk_total_bytes": None}

    recorded_days = sorted(d for d, c in per_day.items() if c["segments"])
    # 「今夜」に整理する日 (午前 5 時前なら前の日)
    tonight = target_day(tz) if today == datetime.now(tz).date() else today
    tonight_note = next((n for n in note_list if n.get("date") == tonight.isoformat()), None)
    return {
        "generated_at": now_iso(),
        "timezone": datetime.now(tz).strftime("%z"),
        "today": today.isoformat(),
        "totals": {
            "segments": totals["segments"],
            "speech_segments": totals["speech_segments"],
            "silent_segments": totals["silent_segments"],
            "pending_segments": totals["pending_segments"],
            "recorded_seconds": round(totals["recorded_seconds"], 1),
            "speech_seconds": round(totals["speech_seconds"], 1),
            "days": len(recorded_days),
            "first_day": recorded_days[0].isoformat() if recorded_days else None,
            "last_at": rows[-1]["started_at"] if rows else None,
            "transcripts": db.transcript_counts(),
            "speakers": len(speakers),
            "named_speakers": sum(1 for s in speakers if s.get("name")),
            "markers": {k: totals[f"markers_{k}"] for k in ("highlight", "split", "memo")},
        },
        "storage": {
            "audio_bytes": totals["audio_bytes"],
            "db_bytes": db_bytes,
            "timeline_bytes": _dir_bytes(settings.data_dir / "timeline"),
            "notes_bytes": notes.total_bytes(),
            **disk_info,
        },
        "queues": {**queues, "pending": pending},
        "notes": {
            "count": len(note_list),
            "days": sum(1 for n in note_list if n["kind"] == "day"),
            "latest_updated_at": max((n["updated_at"] for n in note_list), default=None),
        },
        # 夜の整理の流れ: iPhone から届く → サーバで処理 → AI で整理 → iPhone に届く
        "pipeline": {
            "last_received_at": max((r["received_at"] for r in rows), default=None),
            "pending": pending,
            "day": tonight.isoformat(),
            "received_today": sum(1 for r in rows if parse_iso(r["received_at"]).astimezone(tz).date() == tonight),
            "note": {"name": tonight_note["name"], "updated_at": tonight_note["updated_at"]} if tonight_note else None,
            "last_run": last_run(settings.data_dir),
            "iphone_notes_pull_at": db.get_kv(IPHONE_NOTES_PULL),
        },
        "days": day_rows,
    }
