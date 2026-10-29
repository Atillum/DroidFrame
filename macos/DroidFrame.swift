import AppKit
import Foundation

enum CaptureMode { case preview, recording }
struct DetectedDevice: Equatable {
    let serial: String
    let name: String
    let state: String
}
func parseDeviceList(_ text: String) -> [DetectedDevice] {
    let expression = try! NSRegularExpression(pattern: "^(.+?)\\s+(device|unauthorized|offline)(?:\\s|$)")
    let modelExpression = try! NSRegularExpression(pattern: "model:([^\\s]+)")
    return text.components(separatedBy: .newlines).compactMap { line in
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range),
              let idRange = Range(match.range(at: 1), in: line),
              let stateRange = Range(match.range(at: 2), in: line) else { return nil }
        let id = String(line[idRange])
        let name = modelExpression.firstMatch(in: line, range: range).flatMap { Range($0.range(at: 1), in: line) }.map { String(line[$0]).replacingOccurrences(of: "_", with: " ") } ?? id
        return DetectedDevice(serial: id, name: name, state: String(line[stateRange]))
    }
}
func audioArguments(sdk: Int, selection: Int) -> [String] {
    if sdk < 30 || selection == 2 { return ["--no-audio"] }
    if selection == 1 { return ["--audio-source=mic", "--no-audio-playback"] }
    if sdk >= 33 { return ["--audio-source=playback", "--audio-dup", "--no-audio-playback"] }
    return ["--audio-source=output"]
}
func pngDimensions(_ data: Data) -> (Int, Int)? {
    guard data.count >= 24, data.starts(with: [137,80,78,71,13,10,26,10]) else { return nil }
    let width = data[16..<20].reduce(0) { ($0 << 8) | Int($1) }
    let height = data[20..<24].reduce(0) { ($0 << 8) | Int($1) }
    return width > 0 && height > 0 && width < 20000 && height < 20000 ? (width, height) : nil
}

final class FlippedPanel: NSView { override var isFlipped: Bool { true } }

final class Studio: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let transitionTitle = NSTextField(labelWithString: "Подключаем телефон…")
    let transitionSpinner = NSProgressIndicator()
    var transitionShownAt: Date?
    let transitionDetail = NSTextField(wrappingLabelWithString: "Подготавливаем экран. Приложение работает — подожди немного.")
    var process: Process?
    var mode: CaptureMode = .preview
    var pending: CaptureMode?
    var ipcURL: URL!
    var focusID = UUID().uuidString
    var smokeClick = ""
    var testPhase = 0
    var testProgressQueued = false
    let testBegan = Date()
    var switching = false
    var quitting = false
    var started: Date?
    var recordingURL: URL?
    var compressionResult: CompressionResult?
    var compressionWasBusy = false
    var compressionDismissed = false
    var compressionFinishedAt: Date?
    var showCompressionFooter: Bool { !compressionDismissed && (compressor.isBusy || compressionFinishedAt != nil) }
    lazy var compressor: VideoCompressor = {
        let worker = VideoCompressor(executable: Bundle.main.resourceURL!.appendingPathComponent("ffmpeg/ffmpeg"))
        worker.onChange = { [weak self] in
            guard let self = self else { return }
            if worker.isBusy {
                if !self.compressionWasBusy { self.compressionDismissed = false }
                self.compressionWasBusy = true
                self.compressionFinishedAt = nil
            } else if self.compressionWasBusy {
                self.compressionWasBusy = false
                self.compressionFinishedAt = Date()
            }
            self.publishState()
            self.compressionProgress.doubleValue = worker.progress
            self.compressionSummary.stringValue = worker.summary
            self.refreshCompressionUI()
            if self.quitting && !worker.isBusy && self.process == nil { NSApp.terminate(nil) }
        }
        worker.onResult = { [weak self] result in
            guard let self = self else { return }
            self.compressionResult = result
            self.lastFile = result.saved
            if let error = result.error { fputs("Compression: \(error)\n", stderr) }
        }
        return worker
    }()
    let compression = NSPopUpButton()
    let deleteOriginal = NSButton(checkboxWithTitle: "Удалять исходник после проверки", target: nil, action: nil)
    let compressionClose = NSButton(title: "×", target: nil, action: nil)
    let compressionFooter = NSView()
    var compressionFooterHeight: NSLayoutConstraint!
    var compressionSummaryHeight: NSLayoutConstraint!
    let compressionProgress = NSProgressIndicator()
    let compressionSummary = NSTextField(wrappingLabelWithString: "")
    let compressionDetails = NSStackView()
    var detailFields: [NSTextField] = []
    var detailHeights: [NSLayoutConstraint] = []
    var lastFile: URL?
    var logURL: URL?
    var logHandle: FileHandle?
    var devices: [(String, String)] = []
    var desiredSerial: String?
    var activeSerial: String?
    var scanning = false
    var lastScan = Date.distantPast
    var autoConnectAllowed = true
    var metadata: [String: (Double, Int)] = [:]
    var testFolder: URL? {
        if let path = ProcessInfo.processInfo.environment["REALME_STUDIO_TEST_OUTPUT"], CommandLine.arguments.contains("--smoke-test") { return URL(fileURLWithPath: path) }
        return nil
    }
    let device = NSPopUpButton()
    let quality = NSPopUpButton()
    let sound = NSPopUpButton()
    let status = NSTextField(wrappingLabelWithString: "Проверяю подключение…")
    let clock = NSTextField(labelWithString: "00:00")
    let folderLabel = NSTextField(labelWithString: "")
    let record = NSButton(title: "●  Начать запись", target: nil, action: nil)
    let preview = NSButton(title: "Открыть экран телефона", target: nil, action: nil)
    let shot = NSButton(title: "Скриншот", target: nil, action: nil)
    var folder: URL {
        get {
            if let testFolder = testFolder { return testFolder }
            let fallback = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("DroidFrame").path
            return URL(fileURLWithPath: UserDefaults.standard.string(forKey: "outputFolder") ?? fallback, isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "outputFolder"); folderLabel.stringValue = folderDisplay; publishState() }
    }
    var folderDisplay: String {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!.appendingPathComponent("DroidFrame")
        return folder.standardizedFileURL == desktop.standardizedFileURL ? "Рабочий стол → DroidFrame" : (folder.path as NSString).abbreviatingWithTildeInPath
    }
    func showTransition(_ title: String) {
        transitionTitle.stringValue = title
        transitionDetail.stringValue = "Подготавливаем экран. Приложение работает — подожди немного."
        status.stringValue = title
        if let data = try? String(contentsOf: ipcURL.appendingPathComponent("geometry.txt"), encoding: .utf8) {
            let frame = NSRectFromString(data); if frame.width > 340 && frame.height > 200 { window.setFrame(frame, display: true) }
        } else { try? NSStringFromRect(window.frame).write(to: ipcURL.appendingPathComponent("geometry.txt"), atomically: true, encoding: .utf8) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        transitionShownAt = Date()
        if CommandLine.arguments.contains("--smoke-test") {
            let event:[String:Any] = ["time":Date().timeIntervalSince(testBegan),"title":title,"visible":window.isVisible,"frame":NSStringFromRect(window.frame)]
            if let data = try? JSONSerialization.data(withJSONObject:event) {
                let log = ipcURL.appendingPathComponent("transitions.jsonl")
                if !FileManager.default.fileExists(atPath:log.path) { FileManager.default.createFile(atPath:log.path,contents:nil) }
                if let handle = try? FileHandle(forWritingTo:log) { try? handle.seekToEnd(); try? handle.write(contentsOf:data+Data([10])); try? handle.close() }
            }
        }
        transitionSpinner.isHidden = false; transitionSpinner.startAnimation(nil)
        updateControls(); publishState()
        if CommandLine.arguments.contains("--smoke-test") {
            window.contentView?.layoutSubtreeIfNeeded()
            let buttons: [String:Any] = ["recordWidth":record.frame.width,"recordHeight":record.frame.height,"shotWidth":shot.frame.width,"shotHeight":shot.frame.height,"recordStyle":record.bezelStyle.rawValue,"shotStyle":shot.bezelStyle.rawValue,"recordSize":record.controlSize.rawValue,"shotSize":shot.controlSize.rawValue]
            if let data = try? JSONSerialization.data(withJSONObject:buttons) { try? data.write(to:ipcURL.appendingPathComponent("helper-buttons.json")) }
        }
    }
    var adb: String {
        if let custom = ProcessInfo.processInfo.environment["REALME_STUDIO_ADB"] { return custom }
        return Bundle.main.resourceURL!.appendingPathComponent("scrcpy/adb").path
    }
    var serial: String? {
        if let desired = desiredSerial, devices.contains(where: { $0.0 == desired }) { return desired }
        return device.indexOfSelectedItem >= 0 && device.indexOfSelectedItem < devices.count ? devices[device.indexOfSelectedItem].0 : nil
    }
    func label(_ text: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: size); l.textColor = color; return l
    }
    func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views); r.orientation = .horizontal; r.spacing = 10; return r
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ipcURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DroidFrame-IPC-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: ipcURL, withIntermediateDirectories: true)
        let appMenu = NSMenu(); let root = NSMenuItem(); appMenu.addItem(root)
        let submenu = NSMenu(); submenu.addItem(withTitle: "Завершить DroidFrame", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); root.submenu = submenu; NSApp.mainMenu = appMenu
        let cachedAspect = UserDefaults.standard.double(forKey: "lastAspect")
        let initialAspect = cachedAspect > 0.1 && cachedAspect < 10 ? cachedAspect : 0.45
        let initialHeight = min(740, (NSScreen.main?.visibleFrame.height ?? 820)-60)
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 340+round(initialHeight*initialAspect), height: initialHeight), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.title = "DroidFrame"; window.delegate = self; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let sidebar = NSView(); sidebar.translatesAutoresizingMaskIntoConstraints = false
        let right = NSView(); right.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(sidebar); window.contentView!.addSubview(right)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), sidebar.widthAnchor.constraint(equalToConstant: 340),
            sidebar.topAnchor.constraint(equalTo: window.contentView!.topAnchor), sidebar.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            right.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), right.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            right.topAnchor.constraint(equalTo: window.contentView!.topAnchor), right.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
        compressionFooter.translatesAutoresizingMaskIntoConstraints = false
        compressionFooter.wantsLayer = true; compressionFooter.layer?.backgroundColor = NSColor(white:0.16,alpha:1).cgColor
        sidebar.addSubview(compressionFooter)
        compressionFooterHeight = compressionFooter.heightAnchor.constraint(equalToConstant:0)
        NSLayoutConstraint.activate([compressionFooter.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor),compressionFooter.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor),compressionFooter.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor),compressionFooterHeight])
        compressionSummaryHeight = compressionSummary.heightAnchor.constraint(equalToConstant:18)
        compressionDetails.orientation = .vertical; compressionDetails.alignment = .leading; compressionDetails.spacing = 6
        for index in 0..<4 {
            if index > 0 {
                let line = NSBox(); line.boxType = .separator
                line.widthAnchor.constraint(equalToConstant:272).isActive = true
                line.heightAnchor.constraint(equalToConstant:1).isActive = true
                compressionDetails.addArrangedSubview(line)
            }
            let field = NSTextField(wrappingLabelWithString: "")
            field.widthAnchor.constraint(equalToConstant:272).isActive = true
            let height = field.heightAnchor.constraint(equalToConstant:18); height.isActive = true
            detailFields.append(field); detailHeights.append(height)
            compressionDetails.addArrangedSubview(field)
        }
        let footerStack = NSStackView(views:[compressionSummary,compressionDetails,compressionProgress]); footerStack.orientation = .vertical; footerStack.alignment = .leading; footerStack.spacing = 10; footerStack.translatesAutoresizingMaskIntoConstraints = false
        compressionFooter.addSubview(footerStack)
        compressionClose.target = self; compressionClose.action = #selector(dismissCompression)
        compressionClose.isBordered = false; compressionClose.toolTip = "Скрыть панель сжатия"
        compressionClose.setAccessibilityLabel("Скрыть панель сжатия")
        compressionClose.translatesAutoresizingMaskIntoConstraints = false
        compressionFooter.addSubview(compressionClose)
        NSLayoutConstraint.activate([compressionClose.topAnchor.constraint(equalTo:compressionFooter.topAnchor,constant:3),compressionClose.trailingAnchor.constraint(equalTo:compressionFooter.trailingAnchor,constant:-4),compressionClose.widthAnchor.constraint(equalToConstant:20),compressionClose.heightAnchor.constraint(equalToConstant:20)])
        NSLayoutConstraint.activate([footerStack.leadingAnchor.constraint(equalTo:compressionFooter.leadingAnchor,constant:24),footerStack.trailingAnchor.constraint(equalTo:compressionFooter.trailingAnchor,constant:-24),footerStack.topAnchor.constraint(equalTo:compressionFooter.topAnchor,constant:12),compressionSummary.widthAnchor.constraint(equalToConstant:272),compressionSummaryHeight])
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        sidebar.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor), scroll.topAnchor.constraint(equalTo: sidebar.topAnchor), scroll.bottomAnchor.constraint(equalTo: compressionFooter.topAnchor)])
        let document = FlippedPanel(frame: NSRect(x:0,y:0,width:340,height:900)); scroll.documentView = document
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24), stack.widthAnchor.constraint(equalToConstant:292), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 28)])
        transitionSpinner.style = .spinning; transitionSpinner.controlSize = .large; transitionSpinner.startAnimation(nil)
        transitionTitle.font = .systemFont(ofSize: 18, weight: .medium); transitionTitle.alignment = .center
        transitionDetail.font = .systemFont(ofSize: 12); transitionDetail.textColor = .secondaryLabelColor; transitionDetail.alignment = .center
        let transitionStack = NSStackView(views:[transitionSpinner,transitionTitle,transitionDetail]); transitionStack.orientation = .vertical; transitionStack.spacing = 20; transitionStack.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(transitionStack)
        NSLayoutConstraint.activate([transitionStack.centerXAnchor.constraint(equalTo: right.centerXAnchor), transitionStack.centerYAnchor.constraint(equalTo: right.centerYAnchor), transitionStack.widthAnchor.constraint(lessThanOrEqualTo: right.widthAnchor, constant: -32), transitionDetail.widthAnchor.constraint(lessThanOrEqualTo: right.widthAnchor, constant:-32)])
        window.center()
        stack.addArrangedSubview(label("DROIDFRAME", size: 21, color: .labelColor))
        stack.addArrangedSubview(label("Экран телефона. Всё под рукой.", size: 12))
        device.widthAnchor.constraint(equalToConstant: 292).isActive = true
        device.target = self; device.action = #selector(deviceChanged)
        stack.addArrangedSubview(device)
        status.font = .systemFont(ofSize: 12); status.textColor = .systemTeal; status.widthAnchor.constraint(equalToConstant: 292).isActive = true
        status.heightAnchor.constraint(equalToConstant: 46).isActive = true; stack.addArrangedSubview(status)
        clock.font = .monospacedDigitSystemFont(ofSize: 38, weight: .light); stack.addArrangedSubview(clock)
        stack.addArrangedSubview(label("Без ограничения длительности", size: 11))
        record.target = self; record.action = #selector(toggleRecording); record.bezelStyle = .rounded; record.controlSize = .regular; record.contentTintColor = .systemRed
        record.keyEquivalent = "r"; record.keyEquivalentModifierMask = [.command]
        record.widthAnchor.constraint(equalToConstant: 292).isActive = true; stack.addArrangedSubview(record)
        shot.target = self; shot.action = #selector(screenshot); shot.bezelStyle = .rounded
        shot.keyEquivalent = "s"; shot.keyEquivalentModifierMask = [.command, .shift]
        preview.target = self; preview.action = #selector(togglePreview); preview.bezelStyle = .rounded
        stack.addArrangedSubview(shot)
        for control in [record, shot] {
            control.controlSize = .regular; control.font = .systemFont(ofSize:13)
            control.widthAnchor.constraint(equalToConstant:292).isActive = true
            control.heightAnchor.constraint(equalToConstant:24).isActive = true
        }
        quality.addItems(withTitles: ["720p · экономно", "1080p · чётче", "Исходное разрешение"])
        quality.selectItem(at: 1)
        sound.addItems(withTitles: ["Звук телефона", "Микрофон", "Без звука"])
        stack.addArrangedSubview(row([label("Качество"), quality]))
        compression.addItems(withTitles: ["Без доп. сжатия", "Компактное видео"])
        compression.selectItem(at: min(1, max(0, UserDefaults.standard.integer(forKey: "compressionMode"))))
        deleteOriginal.state = UserDefaults.standard.bool(forKey: "compressionDeleteOriginal") ? .on : .off
        compression.target = self; compression.action = #selector(compressionChanged)
        deleteOriginal.target = self; deleteOriginal.action = #selector(compressionChanged)
        stack.addArrangedSubview(row([label("Сжатие"), compression]))
        stack.addArrangedSubview(deleteOriginal)
        compressionProgress.style = .bar
        compressionProgress.heightAnchor.constraint(equalToConstant:6).isActive = true
        compressionProgress.isIndeterminate = false; compressionProgress.minValue = 0; compressionProgress.maxValue = 100
        compressionProgress.widthAnchor.constraint(equalToConstant: 292).isActive = true
        compressionProgress.isHidden = true
        compressionSummary.font = .systemFont(ofSize:11); compressionSummary.textColor = .secondaryLabelColor
        stack.addArrangedSubview(row([label("Аудио"), sound]))
        stack.addArrangedSubview(button("Выбрать папку сохранения…", #selector(chooseFolder)))
        stack.addArrangedSubview(button("Открыть папку сохранения", #selector(openFolder)))
        folderLabel.stringValue = folderDisplay; folderLabel.textColor = .secondaryLabelColor; folderLabel.font = .systemFont(ofSize: 11); stack.addArrangedSubview(folderLabel)
        stack.addArrangedSubview(button("Показать последний файл", #selector(revealLast)))
        stack.addArrangedSubview(label("Скриншоты работают и во время записи.", size: 10))
        // The normal interface is attached directly to scrcpy; this window is only a connection fallback.
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if Date().timeIntervalSince(self.lastScan) > 2 { self.scanDevices() }
            self.receiveCommands()
            self.advanceSmokeTest()
            if let start = self.started { let seconds = Int(Date().timeIntervalSince(start)); self.clock.stringValue = String(format: "%02d:%02d:%02d", seconds/3600, (seconds/60)%60, seconds%60) }
            self.publishState()
        }
        if CommandLine.arguments.contains("--smoke-test") {
            if let index = Int(ProcessInfo.processInfo.environment["REALME_STUDIO_TEST_SOUND"] ?? "0"), (0..<3).contains(index) { sound.selectItem(at: index) }
            if let index = Int(ProcessInfo.processInfo.environment["REALME_STUDIO_TEST_QUALITY"] ?? "1"), (0..<3).contains(index) { quality.selectItem(at: index) }
            compression.selectItem(at: ProcessInfo.processInfo.environment["REALME_STUDIO_TEST_COMPRESSION"] == "1" ? 1 : 0)
            deleteOriginal.state = ProcessInfo.processInfo.environment["REALME_STUDIO_TEST_DELETE"] == "1" ? .on : .off
        }
        status.stringValue = "Подключаем телефон…"
        showTransition("Подключаем телефон…")
        refresh()
        if CommandLine.arguments.contains("--inspect-discovery") {
            DispatchQueue.main.asyncAfter(deadline: .now()+3) {
                print("Discovery status: \(self.status.stringValue)")
                print("Connected devices: \(self.devices.count)")
                print("ADB: \(self.adb)")
                NSApp.terminate(nil)
            }
        }
    }
    func advanceSmokeTest() {
        guard CommandLine.arguments.contains("--smoke-test"), testPhase < 4 else { return }
        if Date().timeIntervalSince(testBegan) > 150 {
            print("SMOKE ERROR: workflow timeout")
            testPhase = 4; NSApp.terminate(nil); return
        }
        if testPhase == 3 && mode == .preview && process != nil && !testProgressQueued,
           let fixture = ProcessInfo.processInfo.environment["REALME_STUDIO_TEST_PROGRESS_SOURCE"] {
            testProgressQueued = true
            compressor.enqueue(CompressionJob(source:URL(fileURLWithPath:fixture),removeOriginal:false))
        }
        if testPhase == 3 && showCompressionFooter && !compressor.isBusy,
           let finished = compressionFinishedAt, Date().timeIntervalSince(finished) >= 9 {
            smokeClick = "dismissCompression"
        }
        let seconds = started.map { Date().timeIntervalSince($0) } ?? 0
        if testPhase == 0 && process != nil && mode == .preview && !switching {
            smokeClick = "record"; testPhase = 1
        } else if testPhase == 1 && mode == .recording && !switching && seconds >= 3 {
            smokeClick = "screenshot"; testPhase = 2
        } else if testPhase == 2 && mode == .recording && lastFile?.pathExtension == "png" && seconds >= 7 {
            smokeClick = CommandLine.arguments.contains("--close-during-record") ? "close" : "stop"; testPhase = 3
        } else if testPhase == 3 && mode == .preview && !switching && !compressor.isBusy && !showCompressionFooter && lastFile?.pathExtension == "mp4" {
            print("IPC test directory: \(ipcURL.path)")
            print("Helper visible windows: \(NSApp.windows.filter { $0.isVisible }.count)")
            testPhase = 4; NSApp.terminate(nil)
        }
    }
    @objc func dismissCompression() { compressionDismissed = true; publishState() }
    var compressionFooterText: String {
        guard !compressor.isBusy, showCompressionFooter, let result = compressionResult else { return compressor.summary }
        let title = result.error == nil ? "✓ Готово" : "Сжатие не удалось — исходник сохранён"
        let location = (result.saved.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let size = ByteCountFormatter.string(fromByteCount: result.finalBytes, countStyle: .file)
        return "\(title)\nФайл: \(result.saved.lastPathComponent)\nПапка: \(location)\nРазмер: \(size)"
    }
    var compressionDetailsData: [String:String] {
        guard !compressor.isBusy, let result = compressionResult else { return [:] }
        return ["title":result.error == nil ? "✓ Готово" : "Сжатие не удалось — исходник сохранён", "file":result.saved.lastPathComponent, "folder":(result.saved.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath, "size":ByteCountFormatter.string(fromByteCount:result.finalBytes,countStyle:.file)]
    }
    func refreshCompressionUI() {
        guard compressionFooterHeight != nil else { return }
        let visible = showCompressionFooter
        compressionFooter.isHidden = !visible; compressionFooterHeight.constant = 0
        compressionProgress.isHidden = false
        compressionProgress.doubleValue = compressor.progress
        compressionSummary.stringValue = compressionFooterText
        let textBounds = (compressionFooterText as NSString).boundingRect(with:NSSize(width:262,height:CGFloat.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:compressionSummary.font ?? NSFont.systemFont(ofSize:11)])
        let cellHeight = compressionSummary.cell?.cellSize(forBounds:NSRect(x:0,y:0,width:272,height:CGFloat.greatestFiniteMagnitude)).height ?? 0
        compressionSummaryHeight.constant = max(18,ceil(max(textBounds.height,cellHeight))+8)
        let data = compressionDetailsData
        let detailed = !data.isEmpty
        compressionSummary.isHidden = detailed; compressionDetails.isHidden = !detailed
        var detailsHeight: CGFloat = 39 // Three rules and six gaps.
        for (index, key) in ["title","file","folder","size"].enumerated() {
            let prefix = ["","Файл: ","Папка: ","Размер: "][index]
            let text = prefix + (data[key] ?? "")
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byCharWrapping
            let value = NSMutableAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.secondaryLabelColor,.paragraphStyle:paragraph])
            value.addAttribute(.font,value:NSFont.boldSystemFont(ofSize:11),range:NSRange(location:0,length:index == 0 ? (text as NSString).length : (prefix as NSString).length))
            let field = detailFields[index]; field.attributedStringValue = value; field.toolTip = text
            let bounds = value.boundingRect(with:NSSize(width:262,height:CGFloat.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading])
            let cell = field.cell?.cellSize(forBounds:NSRect(x:0,y:0,width:272,height:CGFloat.greatestFiniteMagnitude)).height ?? 0
            detailHeights[index].constant = max(18,ceil(max(bounds.height,cell))+8)
            detailsHeight += detailHeights[index].constant
        }
        compressionFooterHeight.constant = visible ? (detailed ? detailsHeight : compressionSummaryHeight.constant)+50 : 0
        compressionSummary.toolTip = compressionResult?.saved.path
    }
    func publishState() {
        guard let ipcURL = ipcURL else { return }
        refreshCompressionUI()
        folderLabel.stringValue = folderDisplay; folderLabel.toolTip = folder.path
        let value: [String: Any] = ["recording": process != nil && mode == .recording,
            "switching": switching, "screenshotBusy": !shot.isEnabled,
            "quality": quality.indexOfSelectedItem, "sound": sound.indexOfSelectedItem,
            "compression": compression.indexOfSelectedItem, "deleteOriginal": deleteOriginal.state == .on,
            "compressionDetails": compressionDetailsData, "compressionVisible": showCompressionFooter, "compressing": compressor.isBusy, "compressionProgress": compressor.progress, "compressionSummary": compressionFooterText, "compressionResultPath": compressionResult?.saved.path ?? "",
            "time": clock.stringValue, "status": status.stringValue, "focus": focusID,
            "smokeClick": smokeClick,
            "devices": devices.map { ["serial": $0.0, "name": $0.1] },
            "selectedDevice": activeSerial ?? serial ?? "", "folderDisplay": folderDisplay, "folderPath":folder.path]
        if let bytes = try? JSONSerialization.data(withJSONObject: value) {
            try? bytes.write(to: ipcURL.appendingPathComponent("state.json"), options: .atomic)
        }
    }
    func receiveCommands() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: ipcURL, includingPropertiesForKeys: nil) else { return }
        for url in urls.filter({ $0.lastPathComponent.hasPrefix("command.") }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let bytes = try? Data(contentsOf: url), let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { continue }
            try? FileManager.default.removeItem(at: url)
            switch value["action"] as? String {
            case "ready":
                switching = false
                status.stringValue = mode == .recording ? "● Идёт запись. Для сохранения нажми «Стоп»." : "Телефон подключён. Можно записывать видео и делать скриншоты."
                if CommandLine.arguments.contains("--smoke-test") { print("Ready at \(String(format:"%.2f",Date().timeIntervalSince(testBegan)))s; transition was visible: \(window.isVisible)") }
                updateControls(); publishState(); window.orderOut(nil)
            case "record": toggleRecording()
            case "screenshot": screenshot()
            case "dismissCompression": dismissCompression()
            case "files": openFolder()
            case "last": revealLast()
            case "folder": chooseFolder()
            case "quit": NSApp.terminate(nil)
            case "device":
                if mode != .recording, !switching, let id = value["serial"] as? String, let index = devices.firstIndex(where: { $0.0 == id }) {
                    desiredSerial = id; device.selectItem(at: index); request(.preview)
                }
            case "settings":
                if mode != .recording {
                    if let index = value["quality"] as? Int, (0..<3).contains(index) { quality.selectItem(at: index) }
                    if let index = value["sound"] as? Int, (0..<3).contains(index) { sound.selectItem(at: index) }
                    if let index = value["compression"] as? Int, (0..<2).contains(index) { compression.selectItem(at: index) }
                    if let checked = value["deleteOriginal"] as? Bool { deleteOriginal.state = checked ? .on : .off }
                    compressionChanged()
                }
            default: break
            }
        }
    }

    func runADB(_ args: [String], completion: @escaping (Int32, Data) -> Void) {
        let executable = adb
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
            let pipe = Pipe(); p.standardOutput = pipe
            let err = Pipe(); p.standardError = err
            // stderr is small for these bounded ADB operations.
            do { try p.run()
                DispatchQueue.global().asyncAfter(deadline: .now()+20) { if p.isRunning { p.terminate() } }
                let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); let error = err.fileHandleForReading.readDataToEndOfFile(); DispatchQueue.main.async { completion(p.terminationStatus, p.terminationStatus == 0 ? bytes : error) } }
            catch { DispatchQueue.main.async { completion(-1, Data(error.localizedDescription.utf8)) } }
        }
    }
    @objc func refresh() { autoConnectAllowed = true; scanDevices() }
    func scanDevices() {
        guard !scanning, !quitting else { return }
        scanning = true; lastScan = Date()
        let previous = serial
        runADB(["devices", "-l"]) { code, bytes in
            self.scanning = false
            guard !self.quitting else { return }
            let detected = parseDeviceList(String(decoding: bytes, as: UTF8.self))
            let ready = detected.filter { $0.state == "device" }
            let oldIDs = self.devices.map { $0.0 }
            self.devices = ready.map { ($0.serial, $0.name) }
            if oldIDs != self.devices.map({ $0.0 }) { self.autoConnectAllowed = true }
            self.device.removeAllItems(); self.device.addItems(withTitles: self.devices.map { $0.1 })
            if let old = self.desiredSerial ?? self.activeSerial ?? previous, let index = self.devices.firstIndex(where: { $0.0 == old }) { self.device.selectItem(at: index) }
            if self.process == nil && !self.switching {
                if self.devices.isEmpty {
                    if !self.window.isVisible { self.window.makeKeyAndOrderFront(nil) }
                    self.transitionTitle.stringValue = "Ожидаем подключения"
                    self.transitionDetail.stringValue = "Подключи телефон по USB и подтверди отладку."
                    self.transitionSpinner.stopAnimation(nil); self.transitionSpinner.isHidden = true
                    if detected.contains(where: { $0.state == "unauthorized" }) {
                        self.status.stringValue = "Разблокируй телефон и подтверди «Разрешить отладку» на его экране."
                    } else if detected.contains(where: { $0.state == "offline" }) {
                        self.status.stringValue = "Телефон offline. Переподключи USB или беспроводную отладку."
                    } else {
                        self.status.stringValue = "Подключи Android-телефон по USB и включи отладку. Устройство появится автоматически."
                    }
                } else if self.autoConnectAllowed { self.request(.preview) }
            }
            self.updateControls(); self.publishState()
        }
    }
    @objc func deviceChanged() {
        if device.indexOfSelectedItem >= 0 && device.indexOfSelectedItem < devices.count { desiredSerial = devices[device.indexOfSelectedItem].0 }
        if process == nil { request(.preview) }
    }
    func request(_ next: CaptureMode) {
        guard serial != nil else { status.stringValue = "Сначала подключи телефон и нажми ↻."; return }
        if switching { return }
        if let p = process { switching = true; pending = next; showTransition(next == .recording ? "Подготавливаем запись…" : "Возвращаем экран телефона…"); p.interrupt() }
        else { launch(next) }
    }
    func launch(_ next: CaptureMode) {
        guard let id = serial, !quitting else { return }
        switching = true
        if let info = metadata[id] { startScrcpy(next, id: id, aspect: info.0, sdk: info.1); return }
        status.stringValue = "Определяю экран подключённого телефона…"; publishState()
        runADB(["-s", id, "shell", "getprop ro.build.version.sdk; wm size; dumpsys display 2>/dev/null | grep -m1 -E 'mOverrideDisplayInfo|mDisplayInfo'; true"]) { _, bytes in
            let text = String(decoding: bytes, as: UTF8.self)
            let sdk = text.components(separatedBy: .newlines).compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.first ?? 30
            func dimensions(_ pattern: String, last: Bool = false) -> Double? {
                guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
                let matches = re.matches(in: text, range:NSRange(text.startIndex..., in:text))
                guard let match = last ? matches.last : matches.first, let w = Range(match.range(at:1),in:text), let h = Range(match.range(at:2),in:text),
                      let width = Double(text[w]), let height = Double(text[h]), width > 0, height > 0 else { return nil }
                return width/height
            }
            if let aspect = dimensions("real\\s+(\\d+)\\s*x\\s*(\\d+)") ?? dimensions("size:\\s*(\\d+)x(\\d+)", last:true) {
                guard !self.quitting, self.serial == id else { self.switching = false; return }
                self.metadata[id] = (aspect, sdk); UserDefaults.standard.set(aspect, forKey:"lastAspect")
                self.startScrcpy(next, id:id, aspect:aspect, sdk:sdk)
            } else {
                self.runADB(["-s",id,"exec-out","screencap","-p"]) { _, image in
                    guard !self.quitting, self.serial == id else { self.switching = false; return }
                    let aspect = pngDimensions(image).map { Double($0.0)/Double($0.1) } ?? 0.5
                    self.metadata[id] = (aspect,sdk); UserDefaults.standard.set(aspect, forKey:"lastAspect")
                    self.startScrcpy(next,id:id,aspect:aspect,sdk:sdk)
                }
            }
        }
    }
    func startScrcpy(_ next: CaptureMode, id: String, aspect: Double, sdk: Int) {
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { show(error.localizedDescription); return }
        let p = Process(); mode = next; switching = true
        showTransition(next == .recording ? "Запускаем запись…" : "Подключаем экран телефона…")
        try? FileManager.default.removeItem(at: ipcURL.appendingPathComponent("toolbar.json"))
        p.executableURL = Bundle.main.resourceURL!.appendingPathComponent("scrcpy/scrcpy")
        var args = ["--serial", id, "--window-title=DroidFrame", "--window-x=360", "--window-y=50", "--window-height=740", "--video-codec=h264", "--max-fps=30", "--video-bit-rate=8M", "--stay-awake", "--audio-codec=aac"]
        let size = ["1600", "2400", "0"][quality.indexOfSelectedItem]
        args += ["--max-size=\(size)"]
        if next == .recording {
            let url = folder.appendingPathComponent("DroidFrame-\(stamp()).mp4"); recordingURL = url; args += ["--record=\(url.path)"]
            args += audioArguments(sdk: sdk, selection: sound.indexOfSelectedItem)
        } else { args += ["--no-audio"] }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment; env["ADB"] = adb
        env["SDL_MAC_BACKGROUND_APP"] = "1"
        env["DYLD_INSERT_LIBRARIES"] = Bundle.main.resourceURL!.appendingPathComponent("DroidFrameToolbar.dylib").path
        env["REALME_STUDIO_IPC"] = ipcURL.path
        env["REALME_STUDIO_ASPECT"] = String(aspect)
        if CommandLine.arguments.contains("--smoke-test") { env["REALME_STUDIO_TEST"] = "1" }
        env["SCRCPY_SERVER_PATH"] = Bundle.main.resourceURL!.appendingPathComponent("scrcpy/scrcpy-server").path; p.environment = env
        let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DroidFrame-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        logHandle = handle; logURL = log; p.standardOutput = handle; p.standardError = handle
        let capturedFile = recordingURL
        let shouldCompress = next == .recording && compression.indexOfSelectedItem == 1
        let shouldDelete = deleteOriginal.state == .on
        p.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self = self, self.process === child else { return }
                let elapsed = self.started.map { Date().timeIntervalSince($0) } ?? 0
                try? self.logHandle?.close(); self.logHandle = nil; self.process = nil; self.started = nil; self.switching = false
                if next == .recording, let file = capturedFile, FileManager.default.fileExists(atPath: file.path) {
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > 1024 {
                        do { try finalizeMP4(file, elapsed: elapsed) }
                        catch { fputs("Duration finalization: \(error)\n", stderr) }
                        self.lastFile = file; self.status.stringValue = "Сохранено: \(file.lastPathComponent)"
                        if shouldCompress { self.compressor.enqueue(CompressionJob(source: file, removeOriginal: shouldDelete)) }
                    }
                }
                let requested = self.pending; self.pending = nil
                self.updateControls()
                if self.quitting {
                    if CommandLine.arguments.contains("--smoke-test") {
                        print("Closed safely. IPC test directory: \(self.ipcURL.path)")
                        print("Last saved file: \(self.lastFile?.lastPathComponent ?? "none")")
                    }
                    if self.compressor.isBusy {
                        self.status.stringValue = "Завершаю сжатие перед выходом…"
                        self.window.makeKeyAndOrderFront(nil); self.publishState()
                    } else { NSApp.terminate(nil) }
                    return
                }
                if let requested = requested {
                    self.switching = true
                    DispatchQueue.main.asyncAfter(deadline: .now()+1) { if !self.quitting { self.launch(requested) } }
                }
                else if child.terminationStatus != 0 && child.terminationReason != .uncaughtSignal {
                    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    self.status.stringValue = "Соединение завершилось. Проверь телефон и нажми «Открыть экран»."
                    self.autoConnectAllowed = false
                    self.window.makeKeyAndOrderFront(nil)
                    if CommandLine.arguments.contains("--smoke-test") { self.show(String(text.suffix(1800))) }
                } else { NSApp.terminate(nil) }
            }
        }
        do {
            try p.run(); process = p; activeSerial = id
            if CommandLine.arguments.contains("--smoke-test") {
                var observed = Set<Int>()
                let policyFile = ipcURL.appendingPathComponent("dock-policy-\(p.processIdentifier).json")
                Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
                    guard p.isRunning else { timer.invalidate(); return }
                    if let app = NSRunningApplication(processIdentifier: p.processIdentifier) {
                        observed.insert(app.activationPolicy.rawValue)
                        if let data = try? JSONSerialization.data(withJSONObject: observed.sorted()) { try? data.write(to: policyFile, options: .atomic) }
                    }
                }
            }
            started = next == .recording ? Date() : nil
            status.stringValue = next == .recording ? "Запускаем запись…" : "Подключаем экран телефона…"
            updateControls()
            publishState()
        } catch { try? handle.close(); process = nil; status.stringValue = "Не удалось запустить scrcpy"; show(error.localizedDescription) }
    }
    func stamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"; return f.string(from: Date()) }
    func updateControls() {
        let recording = process != nil && mode == .recording
        record.title = recording ? "■ Стоп и сохранить" : "● Начать запись"
        quality.isEnabled = !recording; sound.isEnabled = !recording; device.isEnabled = process == nil
        compression.isEnabled = !recording; deleteOriginal.isEnabled = !recording && compression.indexOfSelectedItem == 1
        record.isEnabled = serial != nil && !switching; shot.isEnabled = serial != nil && !switching
        preview.title = process != nil ? "Закрыть экран" : "Открыть экран"
        preview.isEnabled = !recording && !switching
        preview.isHidden = switching || process == nil
        deleteOriginal.isHidden = compression.indexOfSelectedItem == 0
    }
    @objc func toggleRecording() {
        guard !switching else { return }
        if process != nil && mode == .recording { switching = true; pending = .preview; showTransition("Сохраняем запись…"); process?.interrupt(); record.isEnabled = false }
        else { request(.recording) }
    }
    @objc func togglePreview() {
        if let p = process { pending = nil; p.interrupt() } else { request(.preview) }
    }
    @objc func screenshot() {
        guard let id = activeSerial ?? serial else { return }
        let url = folder.appendingPathComponent("Screenshot-\(stamp()).png")
        shot.isEnabled = false
        runADB(["-s", id, "exec-out", "screencap", "-p"]) { code, bytes in
            self.shot.isEnabled = true
            guard code == 0, bytes.starts(with: [137,80,78,71,13,10,26,10]) else { self.show("Скриншот не получен. Проверь подключение телефона."); return }
            do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try bytes.write(to: url, options: .atomic); self.lastFile = url; self.status.stringValue = self.mode == .recording && self.process != nil ? "● Запись идёт. Скриншот сохранён." : "Скриншот сохранён: \(url.lastPathComponent)" }
            catch { self.show(error.localizedDescription) }
        }
    }
    @objc func compressionChanged() {
        UserDefaults.standard.set(compression.indexOfSelectedItem, forKey: "compressionMode")
        UserDefaults.standard.set(deleteOriginal.state == .on, forKey: "compressionDeleteOriginal")
        updateControls(); publishState()
    }
    @objc func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Сохранять сюда"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
    @objc func openFolder() { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); NSWorkspace.shared.open(folder) }
    @objc func revealLast() { if let url = lastFile { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { openFolder() } }
    func show(_ message: String) {
        if CommandLine.arguments.contains("--smoke-test") { fputs("SMOKE ERROR: \(message)\n", stderr); return }
        let alert = NSAlert(); alert.messageText = "DroidFrame"; alert.informativeText = message; alert.runModal()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let p = process { quitting = true; pending = nil; status.stringValue = "Завершаю и сохраняю…"; p.interrupt(); return .terminateCancel }
        if compressor.isBusy {
            quitting = true; pending = nil; status.stringValue = "Завершаю сжатие перед выходом…"
            window.makeKeyAndOrderFront(nil); return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if process != nil { focusID = UUID().uuidString; publishState() } else { window.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main
struct StudioLauncher {
    static func main() {
        if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--compress-file" {
            let worker = VideoCompressor(executable: Bundle.main.resourceURL!.appendingPathComponent("ffmpeg/ffmpeg"))
            var finished = false; var failed = false
            worker.onResult = { result in
                failed = result.error != nil
                print("Saved: \(result.saved.path); bytes: \(result.originalBytes) → \(result.finalBytes); error: \(result.error ?? "none")")
                finished = true
            }
            worker.enqueue(CompressionJob(source: URL(fileURLWithPath: CommandLine.arguments[2]), removeOriginal: CommandLine.arguments.contains("--remove-original")))
            while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            exit(failed ? 1 : 0)
        }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--finalize-video" {
            do { try finalizeMP4(URL(fileURLWithPath: CommandLine.arguments[2]), elapsed: Double(CommandLine.arguments[3]) ?? 0); print("Finalized") }
            catch { fputs("\(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--unit-test") {
            let fixtures = "List of devices attached\nR58M123 device product:a model:SM_S928B transport_id:1\nadb-pixel (2)._adb-tls-connect._tcp device model:Pixel_9\nemulator-5554\tdevice model:sdk_gphone64_arm64\nUSB9 unauthorized usb:1-1\nUSB10 offline\n"
            let parsed = parseDeviceList(fixtures)
            precondition(parsed.count == 5)
            precondition(parsed[0].name == "SM S928B")
            precondition(parsed[1].serial == "adb-pixel (2)._adb-tls-connect._tcp" && parsed[1].name == "Pixel 9")
            precondition(parsed[3].state == "unauthorized" && parsed[4].state == "offline")
            precondition(parseDeviceList("List of devices attached\n\n").isEmpty)
            var png = Data([137,80,78,71,13,10,26,10] + Array(repeating: UInt8(0), count: 8))
            png.append(contentsOf: [0,0,4,56,0,0,9,96])
            precondition(pngDimensions(png)!.0 == 1080 && pngDimensions(png)!.1 == 2400)
            precondition(pngDimensions(Data()) == nil)
            precondition(audioArguments(sdk: 29, selection: 0) == ["--no-audio"])
            precondition(audioArguments(sdk: 30, selection: 0) == ["--audio-source=output"])
            precondition(audioArguments(sdk: 32, selection: 0) == ["--audio-source=output"])
            precondition(audioArguments(sdk: 33, selection: 0).contains("--audio-dup"))
            precondition(audioArguments(sdk: 36, selection: 1).contains("--audio-source=mic"))
            precondition(audioArguments(sdk: 36, selection: 2) == ["--no-audio"])
            print("PASS: device discovery, multiple devices, wireless serial, unauthorized/offline, PNG dimensions, audio compatibility Android 10–16")
            exit(0)
        }
        let application = NSApplication.shared
        let delegate = Studio()
        application.delegate = delegate
        application.run()
    }
}
