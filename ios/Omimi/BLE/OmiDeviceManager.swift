import CoreBluetooth
import Foundation
import OmiKit
import os

struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var rssi: Int
}

enum DeviceLinkState: Equatable, Sendable {
    case unsupported     // シミュレータなど
    case bluetoothOff
    case unauthorized
    case idle            // 登録デバイスなし
    case waiting         // 登録デバイスの接続待ち (圏外など。iOS が自動で再接続する)
    case connecting
    case connected       // 接続済み・音声未購読
    case streaming       // 音声受信中
}

struct StreamInfo: Sendable {
    var deviceID: UUID
    var deviceName: String
    var codec: OmiCodec
    var firmware: String?
    /// 1 notification の最大ペイロード (ATT MTU - 3)
    var maxPayload: Int
}

/// Omi との BLE 通信。CoreBluetooth の状態復元を使い、アプリがバックグラウンドで
/// 終了されても iOS がデバイスの通知でアプリを再起動して受信を続けられるようにする。
///
/// すべての処理は `queue` 上で行い、コールバックも `queue` 上で呼ぶ。
final class OmiDeviceManager: NSObject, @unchecked Sendable {
    static let restoreIdentifier = "omimi.central"

    let queue = DispatchQueue(label: "omi.ble", qos: .userInitiated)
    private let log = Logger(subsystem: "omimi", category: "BLE")
    private var central: CBCentralManager!

    private var peripheral: CBPeripheral?
    private var targetID: UUID?
    private var targetName: String?
    private var wantsAudio = true
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var codec: OmiCodec?
    private var firmware: String?
    private var isStreaming = false
    private var deviceLED: Int?
    private var deviceMicGain: Int?

    // コールバック (queue 上で呼ばれる)
    var onState: ((DeviceLinkState) -> Void)?
    var onDiscover: ((DiscoveredDevice) -> Void)?
    var onStreamStart: ((StreamInfo) -> Void)?
    var onStreamEnd: (() -> Void)?
    var onAudio: ((Data) -> Void)?
    var onBattery: ((Int) -> Void)?
    var onButton: ((OmiButtonEvent) -> Void)?
    var onLinkInfo: ((_ mtu: Int) -> Void)?
    /// 本体の設定 (ランプの明るさ, マイクの感度) を読んだ・書いた
    var onDeviceSettings: ((_ led: Int?, _ micGain: Int?) -> Void)?

    nonisolated(unsafe) private static let audioService = CBUUID(string: OmiGATT.audioService)
    nonisolated(unsafe) private static let audioData = CBUUID(string: OmiGATT.audioData)
    nonisolated(unsafe) private static let audioCodec = CBUUID(string: OmiGATT.audioCodec)
    nonisolated(unsafe) private static let timeSyncService = CBUUID(string: OmiGATT.timeSyncService)
    nonisolated(unsafe) private static let timeSyncWrite = CBUUID(string: OmiGATT.timeSyncWrite)
    nonisolated(unsafe) private static let buttonService = CBUUID(string: OmiGATT.buttonService)
    nonisolated(unsafe) private static let buttonState = CBUUID(string: OmiGATT.buttonState)
    nonisolated(unsafe) private static let settingsService = CBUUID(string: OmiGATT.settingsService)
    nonisolated(unsafe) private static let ledDimRatio = CBUUID(string: OmiGATT.ledDimRatio)
    nonisolated(unsafe) private static let micGain = CBUUID(string: OmiGATT.micGain)
    nonisolated(unsafe) private static let hapticService = CBUUID(string: OmiGATT.hapticService)
    nonisolated(unsafe) private static let hapticWrite = CBUUID(string: OmiGATT.hapticWrite)
    nonisolated(unsafe) private static let batteryService = CBUUID(string: OmiGATT.batteryService)
    nonisolated(unsafe) private static let batteryLevel = CBUUID(string: OmiGATT.batteryLevel)
    nonisolated(unsafe) private static let deviceInfoService = CBUUID(string: OmiGATT.deviceInfoService)
    nonisolated(unsafe) private static let firmwareRevision = CBUUID(string: OmiGATT.firmwareRevision)

    nonisolated(unsafe) private static let services = [audioService, timeSyncService, buttonService, settingsService,
                                                       hapticService, batteryService, deviceInfoService]

    /// `application(_:didFinishLaunchingWithOptions:)` の中で生成すること (状態復元のため)。
    init(targetID: UUID?, wantsAudio: Bool) {
        super.init()
        self.targetID = targetID
        self.wantsAudio = wantsAudio
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    // MARK: - 操作 (どのスレッドからでも呼べる)

    func startScan() {
        queue.async { [self] in
            guard central.state == .poweredOn else { return }
            // Omi は 128bit のサービス UUID を広告しているのでサービスで絞り込める
            central.scanForPeripherals(withServices: [Self.audioService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func stopScan() {
        queue.async { [self] in central.stopScan() }
    }

    /// デバイスを登録して接続する。以後、切断されても自動的に再接続する。
    func connect(to id: UUID, name: String?) {
        queue.async { [self] in
            central.stopScan()
            if let p = peripheral, p.identifier != id { central.cancelPeripheralConnection(p) }
            targetID = id
            targetName = name
            connectTarget()
        }
    }

    /// 登録を解除して切断する。
    func forget() {
        queue.async { [self] in
            targetID = nil
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            endStream()
            peripheral = nil
            publishState()
        }
    }

    /// 録音の一時停止/再開。停止中は音声の購読を解除する (デバイス側では破棄される)。
    func setAudioEnabled(_ enabled: Bool) {
        queue.async { [self] in
            wantsAudio = enabled
            guard let p = peripheral, p.state == .connected, let audio = characteristics[Self.audioData] else { return }
            if enabled {
                if codec != nil { p.setNotifyValue(true, for: audio) } else if let c = characteristics[Self.audioCodec] { p.readValue(for: c) }
            } else {
                p.setNotifyValue(false, for: audio)
                endStream()
                publishState()
            }
        }
    }

    /// アプリの設定 (ランプ・マイクの感度) を本体に反映する。値が違うときだけ書く (本体のフラッシュに保存されるため)。
    func applyDeviceSettings() {
        queue.async { [self] in
            guard let p = peripheral, p.state == .connected else { return }
            let led = Prefs.ledBrightness
            if let c = characteristics[Self.ledDimRatio], let current = deviceLED, current != led, (0...100).contains(led) {
                p.writeValue(Data([UInt8(led)]), for: c, type: .withResponse)
                deviceLED = led
            }
            let gain = Prefs.micGain
            if let c = characteristics[Self.micGain], let current = deviceMicGain, gain >= 0, current != gain, gain <= 8 {
                p.writeValue(Data([UInt8(gain)]), for: c, type: .withResponse)
                deviceMicGain = gain
            }
            onDeviceSettings?(deviceLED, deviceMicGain)
        }
    }

    /// デバイスを振動させる。`pattern` は 1=100 ms, 2=300 ms, 3=500 ms の並び (0.6 秒間隔で鳴らす)。
    func vibrate(_ pattern: [UInt8]) {
        for (i, v) in pattern.enumerated() {
            queue.asyncAfter(deadline: .now() + .milliseconds(600 * i)) { [self] in
                guard let p = peripheral, p.state == .connected, let c = characteristics[Self.hapticWrite] else { return }
                p.writeValue(Data([v]), for: c, type: .withResponse)
            }
        }
    }

    // MARK: - 内部

    private func connectTarget() {
        guard central.state == .poweredOn, let id = targetID else { publishState(); return }
        let p = peripheral?.identifier == id ? peripheral : central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            log.error("peripheral \(id) not found; scan again")
            publishState()
            return
        }
        peripheral = p
        p.delegate = self
        switch p.state {
        case .connected:
            discover(p)
        case .connecting:
            break
        default:
            // タイムアウトしない接続要求。圏外から戻ったときに iOS が接続する (バックグラウンドでも)。
            central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: false])
        }
        publishState()
    }

    private func discover(_ p: CBPeripheral) {
        characteristics.removeAll()
        codec = nil
        deviceLED = nil
        deviceMicGain = nil
        p.discoverServices(Self.services)
    }

    private func endStream() {
        guard isStreaming else { return }
        isStreaming = false
        onStreamEnd?()
    }

    private func publishState() {
        let state: DeviceLinkState
        switch central.state {
        case .poweredOn:
            if isStreaming { state = .streaming }
            else if let p = peripheral, p.state == .connected { state = .connected }
            else if let p = peripheral, p.state == .connecting { state = targetID == nil ? .idle : .waiting }
            else { state = targetID == nil ? .idle : .waiting }
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default: state = .bluetoothOff
        }
        onState?(state)
    }

    private func startStreamIfReady(_ p: CBPeripheral) {
        guard wantsAudio, let codec, let audio = characteristics[Self.audioData] else { return }
        if audio.isNotifying {
            beginStream(p, codec: codec)
        } else {
            p.setNotifyValue(true, for: audio)
        }
    }

    private func beginStream(_ p: CBPeripheral, codec: OmiCodec) {
        guard !isStreaming else { return }
        isStreaming = true
        let name = p.name ?? targetName ?? "Omi"
        let maxPayload = p.maximumWriteValueLength(for: .withoutResponse)
        onStreamStart?(StreamInfo(deviceID: p.identifier, deviceName: name, codec: codec, firmware: firmware,
                                  maxPayload: maxPayload))
        onLinkInfo?(maxPayload + 3)
        publishState()
    }
}

extension OmiDeviceManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.info("central state \(central.state.rawValue)")
        if central.state == .poweredOn {
            connectTarget()
        } else {
            endStream()
            publishState()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // バックグラウンドで再起動された。iOS が保持していた接続を引き継ぐ。
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        log.info("restoring \(restored.count) peripherals")
        if let p = restored.first(where: { $0.identifier == targetID }) ?? restored.first {
            peripheral = p
            p.delegate = self
            if targetID == nil { targetID = p.identifier }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Omi"
        onDiscover?(DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("connected \(peripheral.identifier)")
        guard peripheral.identifier == targetID else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        discover(peripheral)
        publishState()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("failed to connect: \(error?.localizedDescription ?? "-")")
        queue.asyncAfter(deadline: .now() + 2) { [self] in connectTarget() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        log.info("disconnected \(peripheral.identifier) reconnecting=\(isReconnecting) \(error?.localizedDescription ?? "")")
        endStream()
        characteristics.removeAll()
        codec = nil
        if peripheral.identifier == targetID, !isReconnecting {
            // 切断中はデバイスが SD カードに録音する。戻ってきたら再接続する。
            queue.asyncAfter(deadline: .now() + 1) { [self] in connectTarget() }
        }
        publishState()
    }
}

extension OmiDeviceManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log.error("discover services: \(error.localizedDescription)"); return }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log.error("discover characteristics: \(error.localizedDescription)"); return }
        for c in service.characteristics ?? [] {
            characteristics[c.uuid] = c
            switch c.uuid {
            case Self.timeSyncWrite:
                // 接続のたびに時刻を合わせる (未同期だとデバイスはオフライン録音を破棄する)
                peripheral.writeValue(OmiTimeSync.payload(), for: c, type: .withResponse)
            case Self.audioCodec, Self.firmwareRevision, Self.ledDimRatio, Self.micGain:
                peripheral.readValue(for: c)
            case Self.batteryLevel:
                peripheral.readValue(for: c)
                peripheral.setNotifyValue(true, for: c)
            case Self.buttonState:
                // 現在値を読むと前回の操作 (「離した」など) が届いて誤って印になるので、通知だけを受ける
                peripheral.setNotifyValue(true, for: c)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.audioData:
            if isStreaming { onAudio?(value) }
        case Self.audioCodec:
            guard let id = value.first else { return }
            if let c = OmiCodec(rawValue: id), c.isOpus {
                codec = c
                startStreamIfReady(peripheral)
            } else {
                log.error("unsupported codec id \(id)")
            }
        case Self.firmwareRevision:
            firmware = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        case Self.batteryLevel:
            if let level = value.first { onBattery?(Int(level)) }
        case Self.ledDimRatio:
            if let v = value.first {
                deviceLED = Int(v)
                applyDeviceSettings()
            }
        case Self.micGain:
            if let v = value.first {
                deviceMicGain = Int(v)
                applyDeviceSettings()
            }
        case Self.buttonState:
            if let event = OmiButtonEvent(data: value) { onButton?(event) }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.audioData else { return }
        if let error { log.error("audio notify: \(error.localizedDescription)"); return }
        if characteristic.isNotifying, let codec, wantsAudio {
            beginStream(peripheral, codec: codec)
        } else if !characteristic.isNotifying {
            endStream()
            publishState()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Self.timeSyncWrite {
            if let error { log.error("time sync failed: \(error.localizedDescription)") } else { log.info("time synced") }
        }
    }
}
