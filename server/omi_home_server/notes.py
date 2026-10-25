"""AI エージェントが書いたノート (<data>/notes/*.md) の一覧と読み出し。

エージェントは夜の整理で次のようなファイルを書く (書式は static/nightly-prompt.md を参照):

<data>/notes/YYYY-MM-DD.md   その日のまとめ (iPhone の「まとめ」と「記録」に出る)
<data>/notes/todo.md         日をまたいで続く「やること」など、日付のないノート
<data>/notes/<dir>/<name>.md  2 階層まで

サーバは基本的に読むだけ。iPhone が自分で ChatGPT に頼んで書いたまとめ (その日のまとめと todo.md) だけ、
`PUT /api/v1/notes/{name}` で受け取って置く。
"""

from __future__ import annotations

import hashlib
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DAY_NOTE = re.compile(r"^(\d{4}-\d{2}-\d{2})\.md$")
MAX_NOTE_BYTES = 1024 * 1024
MAX_DEPTH = 3
SUMMARY_CHARS = 140
_PUNCT = set("-_. ")


def valid_name(name: str) -> bool:
    """`todo.md` や `people/田中.md` のような相対パスだけを許す (.. や隠しファイルは不可)。"""
    if not name or len(name) > 200 or not name.endswith(".md") or "\\" in name:
        return False
    parts = name.split("/")
    if len(parts) > MAX_DEPTH:
        return False
    for part in parts:
        if not part or part.startswith(".") or len(part) > 100:
            return False
        if not all(ch.isalnum() or ch in _PUNCT for ch in part):
            return False
    return True


def _plain(text: str) -> str:
    """一覧に出す 1 行用に、Markdown の記号を落とす。"""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[*_`~]+", "", text)
    return " ".join(text.split())


def summarize(text: str) -> tuple[str | None, str | None]:
    """(題名, 要約) を取り出す。題名は最初の `# `、要約は最初の引用 (`> `) か最初の段落。"""
    title = None
    quote: list[str] = []
    paragraph: list[str] = []
    in_code = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        if title is None and line.startswith("# "):
            title = _plain(line[2:])
            continue
        if line.startswith(">"):
            quote.append(line.lstrip("> ").strip())
            continue
        if quote:
            break
        if not line:
            if paragraph:
                break
            continue
        if line.startswith(("#", "-", "*", "|", "<!--", "1.")) or re.match(r"^\d+\.", line):
            if paragraph:
                break
            continue
        paragraph.append(line)
    summary = _plain(" ".join(quote or paragraph)) or None
    if summary and len(summary) > SUMMARY_CHARS:
        summary = summary[:SUMMARY_CHARS - 1] + "…"
    return title, summary


class NotesStore:
    def __init__(self, data_dir: Path):
        self.dir = data_dir / "notes"

    def path_for(self, name: str) -> Path | None:
        if not valid_name(name):
            return None
        path = (self.dir / name).resolve()
        if not path.is_relative_to(self.dir.resolve()):
            return None
        return path

    def _entry(self, path: Path) -> dict[str, Any] | None:
        try:
            st = path.stat()
            if st.st_size > MAX_NOTE_BYTES:
                return None
            data = path.read_bytes()
        except OSError:
            return None
        name = path.relative_to(self.dir).as_posix()
        if not valid_name(name):
            return None
        text = data.decode("utf-8", errors="replace")
        title, summary = summarize(text)
        day = DAY_NOTE.match(name)
        return {
            "name": name,
            "kind": "day" if day else "note",
            "date": day.group(1) if day else None,
            "title": title or (day.group(1) if day else name.removesuffix(".md")),
            "summary": summary,
            "updated_at": datetime.fromtimestamp(st.st_mtime, timezone.utc)
                                  .isoformat(timespec="seconds").replace("+00:00", "Z"),
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }

    def list(self) -> list[dict[str, Any]]:
        """日のまとめ (新しい順) → その他のノート (名前順)。"""
        if not self.dir.is_dir():
            return []
        entries = [e for p in self.dir.rglob("*.md") if p.is_file() and (e := self._entry(p))]
        days = sorted((e for e in entries if e["kind"] == "day"), key=lambda e: e["date"], reverse=True)
        others = sorted((e for e in entries if e["kind"] != "day"), key=lambda e: e["name"])
        return days + others

    def write(self, name: str, text: str) -> dict[str, Any]:
        """iPhone が書いたまとめを置く (その日のまとめと todo.md だけ)"""
        if not (DAY_NOTE.match(name) or name == "todo.md"):
            raise ValueError("書けるのは YYYY-MM-DD.md と todo.md だけです")
        data = text.encode("utf-8")
        if len(data) > MAX_NOTE_BYTES:
            raise ValueError("まとめが大きすぎます")
        path = self.path_for(name)
        assert path is not None
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".md.tmp")
        tmp.write_bytes(data)
        tmp.replace(path)
        entry = self._entry(path)
        assert entry is not None
        return entry

    def read(self, name: str) -> dict[str, Any] | None:
        path = self.path_for(name)
        if path is None or not path.is_file():
            return None
        entry = self._entry(path)
        if entry is None:
            return None
        entry["text"] = path.read_text(encoding="utf-8", errors="replace")
        return entry

    def has_day(self, day: str) -> bool:
        return (self.dir / f"{day}.md").is_file()

    def total_bytes(self) -> int:
        if not self.dir.is_dir():
            return 0
        return sum(p.stat().st_size for p in self.dir.rglob("*") if p.is_file())
