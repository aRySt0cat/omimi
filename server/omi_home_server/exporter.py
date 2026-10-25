"""AI エージェント (Codex など) が読みやすい形での書き出し。

<data>/timeline/YYYY-MM-DD.md     その日の会話を時系列に並べた Markdown (話者・言語・印つき)
<data>/timeline/YYYY-MM-DD.jsonl  同じ内容の構造化データ (1 行 1 レコード)
<data>/AGENTS.md                  データの置き場所と読み方の説明 (エージェント向け)

録音・文字起こし・話者・印が変わるたびに、その日のファイルを作り直す。
"""

from __future__ import annotations

import json
import logging
from collections import Counter
from datetime import date, datetime, timedelta, timezone, tzinfo
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

from .config import Settings
from .db import Database, parse_iso

log = logging.getLogger(__name__)

AGENTS_TEMPLATE = Path(__file__).parent / "static" / "AGENTS.md"
MARKER_LABELS = {"highlight": ("⭐", "注目"), "split": ("✂️", "区切り"), "memo": ("📝", "メモ")}
WEEKDAYS = "月火水木金土日"
# 印を録音に対応付けるときの前後の余裕 (秒)
MARKER_SLACK = 2.0


def local_tz(settings: Settings) -> tzinfo:
    if settings.timezone:
        return ZoneInfo(settings.timezone)
    return datetime.now().astimezone().tzinfo or timezone.utc


def local_day(iso: str, tz: tzinfo) -> date:
    return parse_iso(iso).astimezone(tz).date()


# 発話区間の合計がこれ未満なら物音とみなす
MIN_SPEECH_SECONDS = 1.0


def has_speech(seg: dict[str, Any], transcripts: list[dict[str, Any]]) -> bool | None:
    """話し声があるか。話者分離も文字起こしもまだなら None。"""
    if any(t["pieces"] for t in transcripts):
        return True
    turns = json.loads(seg.get("turns_json") or "[]")
    if seg.get("diarization_status") == "done":
        return sum(t["end"] - t["start"] for t in turns) >= MIN_SPEECH_SECONDS
    if seg.get("server_stt_status") == "done" or transcripts:
        return False
    return None


def choose_transcript(transcripts: list[dict[str, Any]], prefer: str = "whisper") -> dict[str, Any] | None:
    """既定ではサーバ (Whisper, 話者の区間ごと) を優先し、なければ端末 (Apple) の文字起こし。
    聞き比べで Apple の方が良いと決めたら (prefer="apple")、端末の文字起こしを優先する。"""
    by_origin = {t["origin"]: t for t in transcripts}
    for origin in (("device", "server") if prefer == "apple" else ("server", "device")):
        t = by_origin.get(origin)
        if t and t["pieces"]:
            return t
    return None


def _fmt_time(dt: datetime) -> str:
    return dt.strftime("%H:%M:%S")


def _fmt_duration(seconds: float) -> str:
    s = int(round(seconds))
    if s >= 3600:
        return f"{s // 3600}時間{s % 3600 // 60}分"
    if s >= 60:
        return f"{s // 60}分{s % 60}秒"
    return f"{s}秒"


class Exporter:
    def __init__(self, db: Database, settings: Settings):
        self.db = db
        self.settings = settings
        self.dir = settings.data_dir / "timeline"
        self.tz = local_tz(settings)

    def write_agents_guide(self) -> None:
        from .vocabulary import Vocabulary

        dest = self.settings.data_dir / "AGENTS.md"
        text = AGENTS_TEMPLATE.read_text(encoding="utf-8")
        if not dest.exists() or dest.read_text(encoding="utf-8") != text:
            dest.write_text(text, encoding="utf-8")
        Vocabulary.load(self.db).write(self.settings.data_dir)

    def day_of(self, iso: str) -> date:
        return local_day(iso, self.tz)

    def all_days(self) -> set[date]:
        return {self.day_of(t) for t in self.db.segment_days()}

    def export_day(self, day: date) -> None:
        from .worker import enrich  # 循環 import を避ける

        start = datetime.combine(day, datetime.min.time(), self.tz)
        end = start + timedelta(days=1)
        utc = lambda d: d.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")  # noqa: E731
        # 日をまたぐ録音も拾えるよう前日分も読み、開始時刻で振り分ける
        segments = [s for s in self.db.list_segments(utc(start - timedelta(hours=1)), utc(end), limit=100_000)
                    if self.day_of(s["started_at"]) == day]
        markers = [m for m in self.db.list_markers(utc(start), utc(end))]

        md_path = self.dir / f"{day.isoformat()}.md"
        jsonl_path = self.dir / f"{day.isoformat()}.jsonl"
        if not segments and not markers:
            md_path.unlink(missing_ok=True)
            jsonl_path.unlink(missing_ok=True)
            return

        from .compare import preference
        prefer = preference(self.db)
        records: list[tuple[datetime, int, dict[str, Any]]] = []  # (時刻, 並び順, レコード)
        speaker_seconds: Counter[str] = Counter()
        silent = 0
        spans: list[tuple[datetime, datetime, str]] = []
        for seg in segments:
            transcripts = enrich(self.db, seg, self.db.transcripts_for(seg["id"]))
            speech = has_speech(seg, transcripts)
            s_start = parse_iso(seg["started_at"]).astimezone(self.tz)
            s_end = parse_iso(seg["ended_at"]).astimezone(self.tz) if seg.get("ended_at") \
                else s_start + timedelta(seconds=seg.get("duration_seconds") or 0)
            spans.append((s_start, s_end, seg["id"]))
            chosen = choose_transcript(transcripts, prefer)
            speakers = sorted({p["speaker"] for p in (chosen or {}).get("pieces", []) if p.get("speaker")})
            if speech is False:
                silent += 1
            records.append((s_start, 0, {
                "type": "segment", "id": seg["id"], "start": s_start.isoformat(), "end": s_end.isoformat(),
                "duration_s": round(seg.get("duration_seconds") or 0, 1), "has_speech": speech,
                "speakers": speakers, "audio": seg.get("audio_path"),
                "transcript_source": chosen["origin"] if chosen else None,
            }))
            for p in (chosen or {}).get("pieces", []):
                t0 = s_start + timedelta(seconds=p["start"])
                if p.get("speaker"):
                    speaker_seconds[p["speaker"]] += max(0.0, p["end"] - p["start"])
                records.append((t0, 2, {
                    "type": "utterance", "segment_id": seg["id"], "start": t0.isoformat(),
                    "end": (s_start + timedelta(seconds=p["end"])).isoformat(),
                    "speaker": p.get("speaker"), "speaker_id": p.get("speaker_id"),
                    "language": p.get("language"), "text": p["text"], "source": chosen["origin"],
                }))
        for m in markers:
            at = parse_iso(m["at"]).astimezone(self.tz)
            seg_id = next((sid for a, b, sid in spans
                           if a - timedelta(seconds=MARKER_SLACK) <= at <= b + timedelta(seconds=MARKER_SLACK)), None)
            symbol, label = MARKER_LABELS.get(m["kind"], ("•", m["kind"]))
            records.append((at, 1, {"type": "marker", "id": m["id"], "kind": m["kind"], "label": label,
                                    "at": at.isoformat(), "segment_id": seg_id}))
        records.sort(key=lambda r: (r[0], r[1]))

        self.dir.mkdir(parents=True, exist_ok=True)
        tmp = jsonl_path.with_suffix(".jsonl.tmp")
        with tmp.open("w", encoding="utf-8") as f:
            for _, _, rec in records:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        tmp.replace(jsonl_path)

        tmp = md_path.with_suffix(".md.tmp")
        tmp.write_text(self._markdown(day, records, speaker_seconds, silent, len(segments)), encoding="utf-8")
        tmp.replace(md_path)

    def _markdown(self, day: date, records: list[tuple[datetime, int, dict[str, Any]]],
                  speaker_seconds: Counter[str], silent: int, total: int) -> str:
        kinds = Counter(r["kind"] for _, _, r in records if r["type"] == "marker")
        lines = [f"# {day.isoformat()} ({WEEKDAYS[day.weekday()]}) のライフログ", ""]
        lines.append(f"- 録音: 話し声あり {total - silent} 件 / 話し声なし {silent} 件 (省略)")
        if speaker_seconds:
            lines.append("- 話者: " + ", ".join(f"{name} ({_fmt_duration(sec)})"
                                               for name, sec in speaker_seconds.most_common()))
        if kinds:
            lines.append("- 印: " + " / ".join(f"{MARKER_LABELS[k][0]} {MARKER_LABELS[k][1]} {n}"
                                              for k, n in kinds.items() if k in MARKER_LABELS))
        lines.append(f"- タイムゾーン: {datetime.combine(day, datetime.min.time(), self.tz).strftime('%z')}")
        lines.append("")

        skip_segment: set[str] = set()
        for t, _, r in records:
            if r["type"] == "segment":
                if r["has_speech"] is False:
                    skip_segment.add(r["id"])
                    continue
                end = datetime.fromisoformat(r["end"])
                who = ", ".join(r["speakers"]) or "話者不明"
                lines += ["", f"## {_fmt_time(t)} – {_fmt_time(end)} · {_fmt_duration(r['duration_s'])} · {who}",
                          f"<!-- segment: {r['id']} source: {r['transcript_source']} -->", ""]
                if r["has_speech"] is None:
                    lines.append("_(処理中)_")
                elif r["transcript_source"] is None:
                    lines.append("_(短い発話のみ。文字起こしなし)_")
            elif r["type"] == "utterance":
                if r["segment_id"] in skip_segment:
                    continue
                lang = f" ({r['language']})" if r.get("language") else ""
                lines.append(f"- {_fmt_time(t)} **{r.get('speaker') or '不明'}**{lang}: {r['text']}")
            elif r["type"] == "marker":
                symbol, label = MARKER_LABELS.get(r["kind"], ("•", r["kind"]))
                note = {"highlight": "ここは大事", "split": "話題の切れ目",
                        "memo": "ここから本人のメモ・指示"}.get(r["kind"], "")
                if r["kind"] == "split":
                    lines += ["", f"--- {symbol} **{label}** {_fmt_time(t)} ({note}) ---", ""]
                else:
                    lines.append(f"- {_fmt_time(t)} {symbol} **{label}** ({note})")
        return "\n".join(lines).rstrip() + "\n"
