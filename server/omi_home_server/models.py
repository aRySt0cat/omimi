"""話者分離用モデルの取得と検証。

モデルは k2-fsa/sherpa-onnx の GitHub Releases で配布されている ONNX ファイルを使う
(pyannote segmentation-3.0: MIT / WeSpeaker ResNet34: Apache-2.0)。
SHA-256 を固定して改ざんを検知する。オフライン環境では同じパスに手動で置けばよい。
"""

from __future__ import annotations

import hashlib
import logging
import shutil
import tarfile
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class ModelSpec:
    name: str
    url: str
    # ダウンロードするファイルの SHA-256
    sha256: str
    # 配置先 (models ディレクトリからの相対パス)
    dest: str
    # アーカイブ内のファイル (tar.bz2 の場合)
    member: str | None = None
    # 配置後のファイルの SHA-256 (アーカイブの場合は展開後のファイル)
    file_sha256: str | None = None

    @property
    def expected_file_sha256(self) -> str:
        return self.file_sha256 or self.sha256


SEGMENTATION = ModelSpec(
    name="pyannote-segmentation-3.0",
    url="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/"
        "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",
    sha256="24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488",
    dest="sherpa-onnx-pyannote-segmentation-3-0/model.onnx",
    member="sherpa-onnx-pyannote-segmentation-3-0/model.onnx",
    file_sha256="220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079",
)

EMBEDDING = ModelSpec(
    name="wespeaker-voxceleb-resnet34-LM",
    url="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/"
        "wespeaker_en_voxceleb_resnet34_LM.onnx",
    sha256="e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012",
    dest="wespeaker_en_voxceleb_resnet34_LM.onnx",
)

ALL = (SEGMENTATION, EMBEDDING)


class ModelUnavailable(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify(spec: ModelSpec, path: Path) -> bool:
    """配置済みのファイルが配布物と同じか (手動で置いた場合の確認用)。"""
    return path.exists() and _sha256(path) == spec.expected_file_sha256


def ensure(spec: ModelSpec, model_dir: Path, allow_download: bool) -> Path:
    """モデルファイルのパスを返す。無ければ取得する。"""
    dest = model_dir / spec.dest
    if dest.exists():
        return dest
    if not allow_download:
        raise ModelUnavailable(f"{spec.name} がありません。{spec.url} を取得して {dest} に置いてください")
    model_dir.mkdir(parents=True, exist_ok=True)
    log.info("downloading %s from %s", spec.name, spec.url)
    with tempfile.TemporaryDirectory(dir=model_dir) as tmp:
        download = Path(tmp) / "download"
        with urllib.request.urlopen(spec.url, timeout=60) as r, download.open("wb") as f:
            shutil.copyfileobj(r, f)
        digest = _sha256(download)
        if digest != spec.sha256:
            raise ModelUnavailable(f"{spec.name} のハッシュが一致しません ({digest})")
        if spec.member:
            with tarfile.open(download, "r:bz2") as tar:
                member = tar.getmember(spec.member)
                if not member.isfile():
                    raise ModelUnavailable(f"{spec.member} がアーカイブにありません")
                src = tar.extractfile(member)
                assert src is not None
                extracted = Path(tmp) / "extracted"
                with extracted.open("wb") as f:
                    shutil.copyfileobj(src, f)
            download = extracted
        if _sha256(download) != spec.expected_file_sha256:
            raise ModelUnavailable(f"{spec.name} の展開後のハッシュが一致しません")
        dest.parent.mkdir(parents=True, exist_ok=True)
        download.replace(dest)
    log.info("saved %s to %s", spec.name, dest)
    return dest
