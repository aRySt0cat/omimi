#!/bin/zsh
# Mac (Apple Silicon) で自宅サーバを起動する。
# Tailscale のアドレスでだけ待ち受けるので、tailnet 内の端末 (iPhone 等) からしか接続できない。
set -eu
cd "${0:A:h}"

HOST="${OMI_HOST:-$(tailscale ip -4 | head -1)}"
PORT="${OMI_PORT:-8000}"

export OMI_DATA_DIR="${OMI_DATA_DIR:-$PWD/data}"
export OMI_STT_ENGINE="${OMI_STT_ENGINE:-faster-whisper}"
export OMI_STT_MODEL="${OMI_STT_MODEL:-large-v3-turbo}"
export OMI_STT_DEVICE="${OMI_STT_DEVICE:-cpu}"
export OMI_STT_COMPUTE_TYPE="${OMI_STT_COMPUTE_TYPE:-int8}"
export OMI_LANGUAGES="${OMI_LANGUAGES:-ja,en}"
export OMI_TRANSCRIBE_POLICY="${OMI_TRANSCRIBE_POLICY:-requested}"
export HF_HUB_DISABLE_TELEMETRY=1
# Hugging Face の新しい転送方式 (xet) はこの環境で止まることがあったので通常の HTTPS で取得する
export HF_HUB_DISABLE_XET=1
export DO_NOT_TRACK=1

echo "Omi home server: http://$HOST:$PORT  (data: $OMI_DATA_DIR)"
exec uv run --extra faster-whisper omi-server serve --host "$HOST" --port "$PORT"
