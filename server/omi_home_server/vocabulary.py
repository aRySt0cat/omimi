"""用語集: 人名・専門用語など、文字起こしで間違えやすい語。

- 文字起こしのヒント: サーバの Whisper (hotwords) と iPhone の Apple 音声認識 (contextualStrings) に渡す
- 表示・書き出しの補正: 登録した「よく間違う表記」を正しい表記に置き換える (元の文字起こしは残す)
- AI のまとめ: <data>/vocabulary.md を読ませ、聞き間違いを直して書かせる
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# 置き換えに使う「よく間違う表記」の最短の長さ (1 文字は誤って置き換えやすいので使わない)
MIN_ALIAS_CHARS = 2
# Whisper に渡すヒントの上限 (長すぎると出力に混ざりやすい)
MAX_HOTWORDS_CHARS = 400


@dataclass
class Vocabulary:
    entries: list[dict[str, Any]] = field(default_factory=list)

    def __post_init__(self) -> None:
        pairs = []
        for e in self.entries:
            for alias in e.get("aliases") or []:
                alias = alias.strip()
                if len(alias) >= MIN_ALIAS_CHARS and alias != e["term"]:
                    pairs.append((alias, e["term"]))
        # 長いものから置き換える (短いものが長いものの一部を壊さないように)
        pairs.sort(key=lambda p: -len(p[0]))
        self._map = dict(pairs)
        self._pattern = re.compile("|".join(re.escape(a) for a, _ in pairs)) if pairs else None

    @classmethod
    def load(cls, db: Any) -> "Vocabulary":
        """DB の用語集 (同じ版ならキャッシュを使う)"""
        cached = getattr(db, "_vocabulary_cache", None)
        version = getattr(db, "vocabulary_version", 0)
        if cached is not None and cached[0] == version:
            return cached[1]
        vocab = cls(db.list_vocabulary())
        db._vocabulary_cache = (version, vocab)
        return vocab

    def __bool__(self) -> bool:
        return bool(self.entries)

    def correct(self, text: str) -> str:
        """よく間違う表記を正しい表記に置き換える"""
        if not self._pattern or not text:
            return text
        return self._pattern.sub(lambda m: self._map[m.group(0)], text)

    def hotwords(self) -> str | None:
        """Whisper に渡すヒント (正しい表記を並べる)"""
        words: list[str] = []
        size = 0
        for e in self.entries:
            if size + len(e["term"]) + 1 > MAX_HOTWORDS_CHARS:
                break
            words.append(e["term"])
            size += len(e["term"]) + 1
        return " ".join(words) or None

    def markdown(self) -> str:
        lines = ["# 用語集", "",
                 "人名・専門用語など、文字起こしで間違えやすい語です。まとめでは「正しい表記」を使い、",
                 "文字起こしの中の「よく間違う表記」や、読みが近い別の語は、文脈に合えば正しい表記に直して読んでください。", "",
                 "| 正しい表記 | 読み | よく間違う表記 | 説明 |", "|---|---|---|---|"]
        cell = lambda s: (s or "").replace("|", "\\|").replace("\n", " ")  # noqa: E731
        for e in self.entries:
            lines.append(f"| {cell(e['term'])} | {cell(e.get('reading'))} | {cell('、'.join(e.get('aliases') or []))} | {cell(e.get('note'))} |")
        return "\n".join(lines) + "\n"

    def write(self, data_dir: Path) -> None:
        """<data>/vocabulary.md (AI 向け)。用語が無ければ消す"""
        path = data_dir / "vocabulary.md"
        if not self.entries:
            path.unlink(missing_ok=True)
            return
        tmp = path.with_suffix(".md.tmp")
        tmp.write_text(self.markdown(), encoding="utf-8")
        tmp.replace(path)
