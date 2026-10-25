"""自宅サーバの話者分離と同じモデル (sherpa-onnx の ONNX) を、iPhone で動く Core ML に変換する。

- 区切り用: pyannote segmentation-3.0 (10 秒の音声 → 589 フレーム × 7 クラスの対数確率)
- 声の特徴用: WeSpeaker ResNet34 (Kaldi 互換の 80 次元 fbank → 256 次元)

変換は Mac で一度だけ行う (アプリは変換済みの .mlpackage を同梱する。実行時に外部と通信しない)。
変換後に ONNX (onnxruntime) と出力を比べ、差が大きければ失敗にする。

使い方 (変換用の仮想環境。サーバの環境とは分ける):
    uv venv --python 3.12 /tmp/coreml-venv
    VIRTUAL_ENV=/tmp/coreml-venv uv pip install coremltools "torch==2.7.0" onnx onnx2torch onnxruntime numpy
    /tmp/coreml-venv/bin/python ios/Tools/convert_speaker_models.py \
        --models server/data/models --out ios/Omimi/Models
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
import torch
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
from onnx import numpy_helper
from onnx2torch import convert
from torch import nn


@register_torch_op
def prod(context, node):
    """統計プーリングの「時間方向の長さ」(形の積) に使われる torch.prod"""
    x = _get_inputs(context, node)[0]
    context.add(mb.reduce_prod(x=x, keep_dims=False, name=node.name))

SEGMENTATION = "sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
EMBEDDING = "wespeaker_en_voxceleb_resnet34_LM.onnx"
WINDOW = 160_000
# 区切り用モデルに一度に入れる窓の数
BATCH = 8
# 声の特徴を取る長さ (fbank のフレーム数, 10 ms ごと)。iPhone では 60 秒までにする
# (9 フレーム未満は統計プーリングの分散が求まらず、サーバでも特徴を取れない)
MIN_FRAMES, MAX_FRAMES = 9, 6000


class PyanNet(nn.Module):
    """pyannote segmentation-3.0 (SincNet → 4 層の双方向 LSTM → 全結合)。重みは ONNX から読む。"""

    def __init__(self, path: Path):
        super().__init__()
        g = onnx.load(str(path)).graph
        w = {i.name: torch.from_numpy(numpy_helper.to_array(i).copy()) for i in g.initializer}
        nodes = list(g.node)

        def scalar_inputs(op: str, index: int) -> list[str]:
            return [n.input[index] for n in nodes if n.op_type == op]

        wav_scale, wav_bias = scalar_inputs("InstanceNormalization", 1)[0], scalar_inputs("InstanceNormalization", 2)[0]
        self.wav_norm = nn.InstanceNorm1d(1, eps=1e-5, affine=True)
        self.wav_norm.weight.data = w[wav_scale].reshape(1)
        self.wav_norm.bias.data = w[wav_bias].reshape(1)
        self.conv0 = nn.Conv1d(1, 80, 251, stride=10, bias=False)
        self.conv0.weight.data = w["/sincnet/conv1d.0/Concat_2_output_0"]
        self.conv1 = nn.Conv1d(80, 60, 5)
        self.conv1.weight.data, self.conv1.bias.data = w["sincnet.conv1d.1.weight"], w["sincnet.conv1d.1.bias"]
        self.conv2 = nn.Conv1d(60, 60, 5)
        self.conv2.weight.data, self.conv2.bias.data = w["sincnet.conv1d.2.weight"], w["sincnet.conv1d.2.bias"]
        self.norms = nn.ModuleList()
        for i, c in enumerate((80, 60, 60)):
            norm = nn.InstanceNorm1d(c, eps=1e-5, affine=True)
            norm.weight.data, norm.bias.data = w[f"sincnet.norm1d.{i}.weight"], w[f"sincnet.norm1d.{i}.bias"]
            self.norms.append(norm)
        self.pool = nn.MaxPool1d(3, 3)
        self.act = nn.LeakyReLU(0.01)

        self.lstm = nn.LSTM(60, 128, num_layers=4, bidirectional=True, batch_first=True)
        lstm_nodes = [n for n in nodes if n.op_type == "LSTM"]
        for layer, n in enumerate(lstm_nodes):
            W, R, B = (w[n.input[i]] for i in (1, 2, 3))
            for d, suffix in enumerate(("", "_reverse")):
                # ONNX のゲートの順 (i, o, f, c) を PyTorch の順 (i, f, g, o) に並べ替える
                def reorder(x: torch.Tensor) -> torch.Tensor:
                    i, o, f, c = x.chunk(4, 0)
                    return torch.cat([i, f, c, o], 0)
                getattr(self.lstm, f"weight_ih_l{layer}{suffix}").data = reorder(W[d])
                getattr(self.lstm, f"weight_hh_l{layer}{suffix}").data = reorder(R[d])
                getattr(self.lstm, f"bias_ih_l{layer}{suffix}").data = reorder(B[d][:512])
                getattr(self.lstm, f"bias_hh_l{layer}{suffix}").data = reorder(B[d][512:])

        matmuls = [n.input[1] for n in nodes if n.op_type == "MatMul"]
        adds = [n.input[0] for n in nodes if n.op_type == "Add"]
        self.linear0 = nn.Linear(256, 128)
        self.linear1 = nn.Linear(128, 128)
        self.classifier = nn.Linear(128, 7)
        for layer, m, b in zip((self.linear0, self.linear1, self.classifier), matmuls, adds):
            layer.weight.data = w[m].T.contiguous()
            layer.bias.data = w[b]

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.wav_norm(x)
        x = self.act(self.norms[0](self.pool(torch.abs(self.conv0(x)))))
        x = self.act(self.norms[1](self.pool(self.conv1(x))))
        x = self.act(self.norms[2](self.pool(self.conv2(x))))
        x, _ = self.lstm(x.transpose(1, 2))
        x = self.act(self.linear0(x))
        x = self.act(self.linear1(x))
        return torch.log_softmax(self.classifier(x), dim=-1)


def onnx_run(path: Path, x: np.ndarray) -> np.ndarray:
    sess = ort.InferenceSession(str(path))
    return sess.run(None, {sess.get_inputs()[0].name: x})[0]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def convert_segmentation(src: Path, out: Path) -> dict:
    net = PyanNet(src).eval()
    rng = np.random.RandomState(0)
    x = (rng.randn(2, 1, WINDOW) * 0.1).astype(np.float32)
    with torch.no_grad():
        ref = onnx_run(src, x)
        mine = net(torch.from_numpy(x)).numpy()
    diff = float(np.abs(ref - mine).max())
    print(f"segmentation: PyTorch vs ONNX max diff {diff:.2e}")
    assert diff < 1e-3, diff

    traced = torch.jit.trace(net, torch.from_numpy(x[:1]))
    # LSTM の積み重ねは半精度だと誤差がたまるので、単精度のまま (CPU で動く。10 秒あたり数 ms)
    model = ct.convert(
        traced,
        # 束ねる数は 1 か 8 (可変長にすると iPhone で読み込めない)
        inputs=[ct.TensorType(name="audio", shape=ct.EnumeratedShapes(shapes=[(1, 1, WINDOW), (BATCH, 1, WINDOW)],
                                                                       default=(1, 1, WINDOW)))],
        outputs=[ct.TensorType(name="log_probs")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
    )
    model.short_description = "pyannote segmentation-3.0 (MIT). 16 kHz の 10 秒 → 589 フレームの話者の組み合わせ (7 クラス) の対数確率"
    model.user_defined_metadata.update(source_sha256=sha256(src), window_size=str(WINDOW), window_shift="16000",
                                       receptive_field_size="991", receptive_field_shift="270",
                                       num_speakers="3", num_classes="7")
    model.save(str(out))
    batch = np.concatenate([x] * (BATCH // 2))
    assert model.predict({"audio": batch})["log_probs"].shape == (BATCH, 589, 7)
    got = model.predict({"audio": x[:1]})["log_probs"]
    cdiff = float(np.abs(got - ref[:1]).max())
    agree = float((got.argmax(-1) == ref[:1].argmax(-1)).mean())
    print(f"segmentation: Core ML vs ONNX max diff {cdiff:.2e}, argmax agreement {agree:.4f}")
    assert agree > 0.99
    return {"max_diff": cdiff, "argmax_agreement": agree}


def convert_embedding(src: Path, out: Path) -> dict:
    net = convert(str(src)).eval()
    rng = np.random.RandomState(1)
    x = (rng.randn(1, 500, 80) * 3 + 8).astype(np.float32)
    traced = torch.jit.trace(net, torch.from_numpy(x))
    model = ct.convert(
        traced,
        inputs=[ct.TensorType(name="feats", shape=(1, ct.RangeDim(MIN_FRAMES, MAX_FRAMES, default=500), 80))],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )
    model.short_description = "WeSpeaker ResNet34 (VoxCeleb, CC BY 4.0). Kaldi 互換 80 次元 fbank → 256 次元の声の特徴"
    model.user_defined_metadata.update(source_sha256=sha256(src), output_dim="256", sample_rate="16000",
                                       normalize_samples="0")
    model.save(str(out))
    worst = 1.0
    for frames in (20, 120, 500, 1000, 3000):
        x = (rng.randn(1, frames, 80) * 3 + 8).astype(np.float32)
        ref = onnx_run(src, x)[0]
        got = model.predict({"feats": x})["embedding"][0]
        cos = float(np.dot(ref, got) / np.linalg.norm(ref) / np.linalg.norm(got))
        worst = min(worst, cos)
        print(f"embedding: {frames} frames, cosine vs ONNX {cos:.5f}")
    assert worst > 0.995, worst
    return {"min_cosine": worst}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", type=Path, required=True, help="サーバのモデルのフォルダ (server/data/models)")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    report = {
        "segmentation": convert_segmentation(args.models / SEGMENTATION, args.out / "SpeakerSegmentation.mlpackage"),
        "embedding": convert_embedding(args.models / EMBEDDING, args.out / "SpeakerEmbedding.mlpackage"),
    }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
