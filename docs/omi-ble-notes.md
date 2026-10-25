# Omi BLE プロトコル調査メモ

公式リポジトリ [BasedHardware/omi](https://github.com/BasedHardware/omi) (2026-10-09 時点の `main`, MIT License) を読んで確認した内容。
対象は Omi CV1 (ファームウェア `omi/firmware/omi`, FW 3.0.21)。

## GATT

| UUID | 用途 | 備考 |
|---|---|---|
| `19B10000-E8F2-537E-4F6C-D104768A1214` | オーディオサービス | 広告に 128bit UUID が載るのでスキャンで絞り込める |
| `19B10001-…` | 音声 (NOTIFY) | `[packetIndex u16 LE][subIndex u8][Opus]` |
| `19B10002-…` | コーデック ID (READ) | CV1 は 21 (`opus_fs320`) |
| `19B10031-…` | 時刻同期 (WRITE) | u32 LE の epoch 秒。**接続ごとに書く** (未同期だと SD 録音を破棄する) |
| `30295780-4301-EABD-2904-2849ADFEAE43` | オフラインストレージ | |
| `30295781-…` | コマンド (WRITE) + データ (NOTIFY) | 下記リングプロトコル |
| `30295782-…` | 状態 (READ/NOTIFY) | 4×u32 LE `[used][unreadPackets][free][rtcValid]` |
| `23BA7925-0000-1000-7450-346EAC492E92` | ボタン (NOTIFY) | int32 LE: 1 単押し / 2 ダブル / 3 長押し / 4 押下 / 5 離す |
| `0x180F/0x2A19` | バッテリー | |
| `0x180A/0x2A26` | ファームウェアリビジョン | SD 同期のプロトコル切り替えに使う |

出典: `omi/firmware/omi/src/lib/core/transport.c`, `storage.c`, `button.c`, `app/lib/services/devices/models.dart`

## 音声

- Opus, 16 kHz, モノラル, 20 ms (320 サンプル) フレーム, CELT (RESTRICTED_LOWDELAY), 32 kbps VBR (`config.h`, `codec.c`)
- ファームウェアは 1 フレームを MTU-3 byte ごとに分割して送る (`push_to_gatt`)。iOS は MTU が 185 以上になるので実質 1 notification = 1 フレーム。
- MTU < 100 だと音声を送らない。
- **接続中かつ未購読のときはフレームを破棄する**。未接続のときだけ SD カードに保存する (`pusher()`)。
- 公式アプリは欠落を検出するだけで補完しない。本アプリは Opus の PLC 用 1 byte パケットを挿入して時間軸を保つ。
- **無音でマイクが休止する** (`mic.c` の T5838 ハードウェア AAD, `CONFIG_OMI_VAD_ABS_THRESHOLD=250`, `CONFIG_OMI_VAD_HOLD_MS=10000`)。平均振幅が閾値未満の状態が 10 秒続くと PDM を止め、音がすると再開する。その間は BLE でも SD でもフレームが出ない (パケット番号も進まない)。そのため受信フレーム数から時刻を計算するとずれる。本アプリは受信時刻を基準にし、30 秒以内の途切れは無音で埋め、それより長い途切れでセグメントを区切る。

## オフライン (SD カード) 同期 — 本アプリでは使わない (調査メモのみ)

FW ≥ 3.0.20 はリングバッファ方式 (`app/lib/services/wals/ring_storage_sync.dart`, `ring_protocol.dart`)。多バイト値は **ビッグエンディアン**。

コマンド (`30295781` に書く):

| | |
|---|---|
| `[0x10]` | INFO |
| `[0x11][start_seq u64]([count u32])` | READ |
| `[0x12][new_read_seq u64]` | ADVANCE (読んだところまで解放) |
| `[0x03]` | STOP |

通知 (`30295781`):

| | |
|---|---|
| `[0x01][status]` | ACK (0 OK, 9 未準備, 10 範囲外) |
| `[0x02][read_seq u64][write_seq u64][capacity u32][dropped u64][record_size u16=444]` | INFO |
| `[0x05][start_seq u64][count u32]` | READ 開始 |
| `[0x03][bytes…]` | データ (レコード境界とは無関係なバイト列) |
| `[0x04][status][next_seq u64]` | 完了 |

レコード = 444 byte = `[timestamp u32 BE][440 byte]`。440 byte の中身は `[len u8][opus]…` の繰り返し (len 0 はスキップ)。
1 レコードは約 5 フレーム (100 ms)。ファームウェアは READ 中も自分で read pointer を進めるので、ADVANCE が 10 を返しても `seq <= INFO.read_seq` なら成功扱いでよい。
FW 3.0.17–3.0.19 は同じオペコードで意味が違う複数ファイル方式なので、ファームウェアリビジョンで分岐する必要がある。

## 接続

- `BT_MAX_CONN=1`: 公式アプリと同時に接続できない。
- 公式 iOS アプリは `bluetooth-central` + CoreBluetooth 状態復元 + 切断時の即時再接続 (タイムアウトなし `connect`) で常時接続を維持している。本アプリも同じ方式。
