import Cocoa
import CoreGraphics
import AVFoundation
import Speech

// =============================================================================
// VoiceOn — 「英数」キー長押し中だけマイクで音声認識（Speechフレームワーク）し、
//           離した時点でカーソル位置に認識結果を打ち込むメニューバー常駐アプリ。
//
//   - 認識結果を「文字キー入力」として送り込むため、ターミナル等ほぼ全アプリで動く
//   - 録音の開始/停止を完全制御（純粋な push-to-talk）
//   - オンデバイス認識を使うので完全無料・オフライン・通信なし
//   - 録音中はマウスカーソルに音量連動インジケータ（またはGIF）を表示
//
// 必要な権限: アクセシビリティ / マイク / 音声認識
// =============================================================================

// MARK: - 設定

enum Config {
    static let triggerKeycode: Int64 = 102      // 英数 (kVK_JIS_Eisu)
    static let holdThresholdMs: Int = 200       // これ以上の長押しで録音開始
    static let localeIdentifier = "ja-JP"

    // ⌘ダブルタップ＆ホールド（US配列でも使える汎用トリガー）
    static let cmdGestureEnabled = true
    static let cmdDoubleTapWindowMs = 400       // 1回目タップ→2回目押下までの猶予
    static let cmdTapMaxMs = 350                // タップとみなす最大押下時間
    /// 表示中セグメントがこの文字数以上で先頭が変わった場合のみ「新セグメント」と判定し、
    /// 前を確定して追記する（消さない）。これ未満の短い断片は言い直しとみなして置き換え、
    /// 二重登録を防ぐ。
    static let segmentMinChars: Int = 3

    // --- 録音中のマウスカーソル表示 ---
    /// カーソルに重ねるアニメGIF等のファイルパス。指定すればそれを表示、
    /// nil なら下の「点滅する丸」にフォールバックする。
    static let cursorAnimationFile: String? = nil   // 例: "~/path/to/cursor.gif" の絶対パス
    static let animationSize = NSSize(width: 48, height: 48)

    // フォールバックの「音量連動ドット」
    static let levelQuietColor: NSColor = .systemBlue  // 静かなときの色
    static let levelLoudColor: NSColor = .systemRed    // 大きいときの色
    static let levelGain: Float = 28                   // 感度（大きいほど小さな音で反応）
    static let levelCurve: Float = 0.6                  // <1 で低音量を持ち上げる（小さいほど敏感）
    static let dotDiameter: CGFloat = 22               // 基準の直径（音量で拡大）
    static let dotAlphaMax: CGFloat = 0.9              // 最大不透明度
}

let kSynthMagic: Int64 = 0x564F_4943 // "VOIC"

// MARK: - 音声認識

final class SpeechEngine {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Config.localeIdentifier))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// 確定済みテキスト（区切りで確定した分を貯める）
    private var committedText = ""
    /// 現在のセグメントの最新テキスト
    private var segmentText = ""
    private var finishing = false
    private(set) var isRunning = false
    private var smoothedLevel: Float = 0

    var onError: ((String) -> Void)?
    /// マイク音量（0〜1）をリアルタイムに通知
    var onLevel: ((Float) -> Void)?

    func start() {
        guard !isRunning else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            onError?("音声認識が利用できません（言語設定/接続を確認）")
            return
        }

        committedText = ""
        segmentText = ""
        finishing = false
        smoothedLevel = 0

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.request?.append(buffer)
            let lv = self.computeLevel(buffer)
            if let cb = self.onLevel { DispatchQueue.main.async { cb(lv) } }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("マイク開始に失敗: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            request = nil
            isRunning = false
            return
        }

        isRunning = true
        startRecognitionTask()
    }

    /// 認識リクエスト/タスクを作成（区切り後の再スタートでも使う）
    private func startRecognitionTask() {
        guard let recognizer = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true   // 句読点の自動付与
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                DispatchQueue.main.async { self.handleResult(text: text, isFinal: isFinal) }
            }
            if error != nil {
                DispatchQueue.main.async { self.finalizeSession() }
            }
        }
    }

    /// ※ メインスレッドで呼ばれる。録音中は挿入せず、テキストを貯めるだけ。
    private func handleResult(text: String, isFinal: Bool) {
        guard isRunning else { return }

        if !text.isEmpty {
            // 共通プレフィックスが0かつ現セグメントが十分長い＝新セグメント → 前を確定。
            // それ以外（言い直し/伸長）は現セグメントを置き換え。
            let common = Self.commonPrefixCount(segmentText, text)
            if common == 0 && segmentText.count >= Config.segmentMinChars {
                committedText += segmentText   // 前のセグメントを確定
            }
            segmentText = text                 // 現セグメントを更新
        }

        if isFinal {
            if finishing {
                finalizeSession()
            } else {
                // 区切り（無音）でセグメント確定 → 認識を再スタートして継続
                committedText += segmentText
                segmentText = ""
                task = nil
                request = nil
                startRecognitionTask()
            }
        }
    }

    private static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        let aa = Array(a), bb = Array(b)
        var i = 0
        while i < aa.count, i < bb.count, aa[i] == bb[i] { i += 1 }
        return i
    }

    func stop() {
        guard isRunning else { return }
        finishing = true
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()

        // 最終結果が来ない場合の保険（2秒後に確定）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.finalizeSession()
        }
    }

    /// 録音終了・確定テキストを一括挿入してリセット（多重呼び出しに安全）
    private func finalizeSession() {
        DispatchQueue.main.async {
            guard self.isRunning else { return }
            self.isRunning = false
            self.finishing = false
            self.task?.cancel()
            self.task = nil
            self.request = nil
            let finalText = self.committedText + self.segmentText
            self.committedText = ""
            self.segmentText = ""
            if !finalText.isEmpty {
                TextInserter.insert(finalText)   // 離した瞬間にまとめて挿入
            }
        }
    }

    /// バッファのRMSから音量レベル(0〜1)を算出。速いアタック・遅いディケイで平滑化。
    /// ※ オーディオスレッドで呼ばれる
    private func computeLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return smoothedLevel }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return smoothedLevel }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        let rms = sqrtf(sum / Float(n))
        let raw = min(1, rms * Config.levelGain)
        let target = powf(raw, Config.levelCurve)   // 低音量を持ち上げて感度UP
        smoothedLevel = max(target, smoothedLevel * 0.85)
        return smoothedLevel
    }
}

// MARK: - テキスト挿入（CGEvent で Unicode を打ち込む）

enum TextInserter {
    static func insert(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in text {
            let utf16 = Array(String(ch).utf16)
            for keyDown in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: keyDown) else { continue }
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                e.flags = []
                e.setIntegerValueField(.eventSourceUserData, value: kSynthMagic)
                e.post(tap: .cghidEventTap)
            }
        }
    }
}

// MARK: - トリガー（英数 長押し / 短押しは透過）

final class TriggerController {
    private var holdFired = false
    private var pressGeneration = 0
    let engine = SpeechEngine()
    var onStateChange: ((Bool) -> Void)?

    // --- ⌘ ダブルタップ＆ホールド用 ---
    private var cmdDown = false
    private var cmdDownTime = Date()
    private var dirtyDuringCmd = false        // ⌘押下中に他キー/他修飾が入った＝ショートカット
    private var awaitingSecondUntil: Date?    // 1回目タップ後、2回目押下を待つ期限
    private var cmdHoldGen = 0
    private var cmdActive = false             // ⌘ホールドで録音中

    func handleKeyDown(keycode: Int64, autorepeat: Bool) -> Bool {
        // ⌘押下中に通常キーが押されたら、それはショートカット操作なのでジェスチャを汚す
        if cmdDown { dirtyDuringCmd = true }

        guard keycode == Config.triggerKeycode else { return false }
        if autorepeat { return true }

        holdFired = false
        pressGeneration += 1
        let gen = pressGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Config.holdThresholdMs)) { [weak self] in
            guard let self = self, gen == self.pressGeneration, !self.holdFired else { return }
            self.holdFired = true
            self.onStateChange?(true)
            self.engine.start()
        }
        return true
    }

    /// ⌘の状態変化を処理（command=⌘押下中か, extra=他の修飾キーが併用されているか）
    func handleFlags(command: Bool, extra: Bool) {
        guard Config.cmdGestureEnabled else { return }
        let now = Date()

        if command && !cmdDown {
            // ⌘ダウン
            cmdDown = true
            cmdDownTime = now
            dirtyDuringCmd = extra
            if let deadline = awaitingSecondUntil, now <= deadline, !extra {
                // 2回目の押下 → 長押し判定タイマー開始
                awaitingSecondUntil = nil
                cmdHoldGen += 1
                let g = cmdHoldGen
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Config.holdThresholdMs)) { [weak self] in
                    guard let self = self, self.cmdDown, g == self.cmdHoldGen,
                          !self.dirtyDuringCmd, !self.cmdActive else { return }
                    self.cmdActive = true
                    self.onStateChange?(true)
                    self.engine.start()
                }
            } else {
                awaitingSecondUntil = nil   // 1回目候補（離した時に判定）
            }
        } else if command && cmdDown {
            // ⌘押下中に他修飾が増えた → ショートカット扱い
            if extra { dirtyDuringCmd = true }
        } else if !command && cmdDown {
            // ⌘アップ
            cmdDown = false
            let duration = now.timeIntervalSince(cmdDownTime)
            if cmdActive {
                cmdActive = false
                onStateChange?(false)
                engine.stop()
                awaitingSecondUntil = nil
            } else if !dirtyDuringCmd && duration <= Double(Config.cmdTapMaxMs) / 1000.0 {
                // クリーンな短タップ → 2回目を待つ
                awaitingSecondUntil = now + Double(Config.cmdDoubleTapWindowMs) / 1000.0
            } else {
                awaitingSecondUntil = nil
            }
        }
    }

    func handleKeyUp(keycode: Int64) -> Bool {
        guard keycode == Config.triggerKeycode else { return false }
        pressGeneration += 1
        if holdFired {
            holdFired = false
            onStateChange?(false)
            engine.stop()
        } else {
            emitTriggerTap()
        }
        return true
    }

    private func emitTriggerTap() {
        let src = CGEventSource(stateID: .hidSystemState)
        let key = CGKeyCode(Config.triggerKeycode)
        for keyDown in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: keyDown)
            e?.flags = []
            e?.setIntegerValueField(.eventSourceUserData, value: kSynthMagic)
            e?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - マウスカーソル上のインジケータ（録音中）

/// カーソル追従ビューの共通インターフェース
protocol CursorEffect: AnyObject {
    func start()
    func stop()
}

/// アニメGIF等を再生するビュー
final class GifEffectView: NSImageView, CursorEffect {
    func start() { animates = true }
    func stop() { animates = false }
}

/// 音量に応じて色・濃さ・大きさが変わる丸（フォールバック）
final class LevelDotView: NSView, CursorEffect {
    /// 0（静か）〜1（大きい）
    var level: CGFloat = 0 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func start() { level = 0 }
    func stop() { level = 0 }

    override func draw(_ dirtyRect: NSRect) {
        let lv = max(0, min(1, level))
        let base = Self.blend(Config.levelQuietColor, Config.levelLoudColor, lv)
        let alpha = 0.25 + (Config.dotAlphaMax - 0.25) * lv
        base.withAlphaComponent(alpha).setFill()
        let d = Config.dotDiameter * (0.6 + 0.9 * lv)   // 音量で拡大
        let rect = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        NSBezierPath(ovalIn: rect).fill()
    }

    /// 2色を t(0〜1) で線形補間
    static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let ca = a.usingColorSpace(.sRGB) ?? a
        let cb = b.usingColorSpace(.sRGB) ?? b
        return NSColor(srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
                       green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
                       blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
                       alpha: 1)
    }
}

/// 透明・クリック透過パネルをマウスカーソルに追従させる
final class CursorIndicator {
    private var panel: NSPanel?
    private var effectView: (NSView & CursorEffect)?
    private var levelView: LevelDotView?   // 音量連動ドットのとき設定
    private var tracker: Timer?
    private var panelSize = NSSize(width: 48, height: 48)

    /// 0〜1 の音量レベルを反映
    func setLevel(_ level: Float) {
        levelView?.level = CGFloat(level)
    }

    func show() {
        if panel == nil { setup() }
        reposition()
        panel?.orderFrontRegardless()
        effectView?.start()
        tracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.reposition()
        }
    }

    func hide() {
        tracker?.invalidate(); tracker = nil
        effectView?.stop()
        panel?.orderOut(nil)
    }

    private func setup() {
        // アニメファイルが指定・読込できれば GIF、ダメなら音量連動ドット
        let view: (NSView & CursorEffect)
        if let path = Config.cursorAnimationFile, let image = NSImage(contentsOfFile: path) {
            panelSize = Config.animationSize
            let gif = GifEffectView(frame: NSRect(origin: .zero, size: panelSize))
            gif.image = image
            gif.imageScaling = .scaleProportionallyUpOrDown
            gif.animates = false
            view = gif
            levelView = nil
        } else {
            panelSize = NSSize(width: 56, height: 56)
            let dot = LevelDotView(frame: NSRect(origin: .zero, size: panelSize))
            view = dot
            levelView = dot
        }

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = view
        panel = p
        effectView = view
    }

    private func reposition() {
        guard let panel = panel else { return }
        let m = NSEvent.mouseLocation // マウスを中心に
        panel.setFrameOrigin(NSPoint(x: m.x - panelSize.width / 2,
                                     y: m.y - panelSize.height / 2))
    }
}

// MARK: - イベントタップ

let controller = TriggerController()
var eventTap: CFMachPort?

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if event.getIntegerValueField(.eventSourceUserData) == kSynthMagic {
        return Unmanaged.passUnretained(event)
    }
    switch type {
    case .keyDown:
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if controller.handleKeyDown(keycode: kc, autorepeat: repeated) { return nil }
    case .keyUp:
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        if controller.handleKeyUp(keycode: kc) { return nil }
    case .flagsChanged:
        let raw = event.flags.rawValue
        let command = raw & CGEventFlags.maskCommand.rawValue != 0
        let extra = raw & (CGEventFlags.maskShift.rawValue
                           | CGEventFlags.maskControl.rawValue
                           | CGEventFlags.maskAlternate.rawValue
                           | CGEventFlags.maskSecondaryFn.rawValue) != 0
        controller.handleFlags(command: command, extra: extra)
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

func startEventTap() -> Bool {
    let mask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) |
        (1 << CGEventType.keyUp.rawValue) |
        (1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: eventTapCallback,
        userInfo: nil
    ) else { return false }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let cursorIndicator = CursorIndicator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        controller.onStateChange = { [weak self] active in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.statusItem.button?.title = active ? "🔴" : "🎙️"
                if active { self.cursorIndicator.show() } else { self.cursorIndicator.hide() }
            }
        }
        controller.engine.onLevel = { [weak self] level in
            self?.cursorIndicator.setLevel(level)   // onLevel は既にメインスレッド
        }
        controller.engine.onError = { msg in
            DispatchQueue.main.async {
                let a = NSAlert(); a.messageText = "音声認識エラー"; a.informativeText = msg; a.runModal()
            }
        }

        requestPermissions { [weak self] in
            guard let self = self else { return }
            guard AXIsProcessTrusted() else {
                self.showAccessibilityAlert(); return
            }
            if !startEventTap() {
                let a = NSAlert(); a.messageText = "キーボード監視を開始できませんでした"
                a.informativeText = "アクセシビリティ権限を確認して再起動してください。"; a.runModal()
            }
        }
    }

    private func requestPermissions(_ done: @escaping () -> Void) {
        // アクセシビリティはプロンプトのみ（付与は設定アプリで）
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        SFSpeechRecognizer.requestAuthorization { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { done() }
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"
        let menu = NSMenu()
        menu.addItem(withTitle: "VoiceOn — 「英数」長押しで音声入力", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let open = NSMenuItem(title: "アクセシビリティ設定を開く", action: #selector(openAX), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openAX() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAccessibilityAlert() {
        let a = NSAlert()
        a.messageText = "アクセシビリティ権限が必要です"
        a.informativeText = "システム設定 > プライバシーとセキュリティ > アクセシビリティ で VoiceOn を許可し、再起動してください。"
        a.addButton(withTitle: "設定を開く"); a.addButton(withTitle: "閉じる")
        if a.runModal() == .alertFirstButtonReturn { openAX() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
