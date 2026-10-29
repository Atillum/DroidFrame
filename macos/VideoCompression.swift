import Foundation
import AVFoundation

struct CompressionJob {
    let source: URL
    let removeOriginal: Bool
}

struct CompressionResult {
    let source: URL
    let saved: URL
    let originalBytes: Int64
    let finalBytes: Int64
    let error: String?
}

final class VideoCompressor {
    let executable: URL
    var onChange: (() -> Void)?
    var onResult: ((CompressionResult) -> Void)?
    private var jobs: [CompressionJob] = []
    private var active: Process?
    private var progressBuffer = ""
    private var duration = 1.0
    private(set) var progress = 0.0
    private(set) var summary = ""
    var isBusy: Bool { active != nil || !jobs.isEmpty }

    init(executable: URL) { self.executable = executable }

    func enqueue(_ job: CompressionJob) {
        jobs.append(job)
        if active == nil { startNext() }
        onChange?()
    }

    private func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func nextOutput(_ source: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent + "_compressed"
        var candidate = source.deletingLastPathComponent().appendingPathComponent(base + ".mp4")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = source.deletingLastPathComponent().appendingPathComponent(base + "-\(index).mp4")
            index += 1
        }
        return candidate
    }
    private func consume(_ bytes: Data) {
        progressBuffer += String(decoding: bytes, as: UTF8.self)
        while let end = progressBuffer.firstIndex(of: "\n") {
            let line = String(progressBuffer[..<end]); progressBuffer.removeSubrange(...end)
            if line.hasPrefix("out_time_us="), let value = Double(line.dropFirst(12)) {
                progress = min(99, max(0, value / 1_000_000 / duration * 100))
                summary = "Сжатие: \(Int(progress))%" + (jobs.isEmpty ? "" : " · в очереди: \(jobs.count)")
                onChange?()
            }
        }
    }

    private func startNext() {
        guard active == nil, !jobs.isEmpty else { return }
        let job = jobs.removeFirst()
        let identifier = UUID().uuidString
        let temporary = job.source.deletingLastPathComponent().appendingPathComponent(".compression-\(identifier).mp4")
        let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("RealmeCompression-\(identifier).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errorHandle = try? FileHandle(forWritingTo: log)
        let originalBytes = size(job.source)
        let sourceDuration = AVURLAsset(url: job.source).duration.seconds
        duration = sourceDuration.isFinite && sourceDuration > 0 ? sourceDuration : 1
        progress = 0; progressBuffer = ""; summary = "Подготовка сжатия…"
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
            "-i", job.source.path, "-map", "0:v:0", "-map", "0:a:0?",
            "-vcodec", "libx264", "-crf", "28", "-preset", "fast",
            "-pix_fmt", "yuv420p", "-vf", "fps=30,tpad=stop_mode=clone:stop_duration=\(duration)",
            "-t", String(duration), "-movflags", "+faststart",
            "-acodec", "aac", "-b:a", "96k", "-progress", "pipe:1", "-nostats", temporary.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        environment.removeValue(forKey: "DYLD_LIBRARY_PATH")
        process.environment = environment
        let output = Pipe(); process.standardOutput = output
        process.standardError = errorHandle ?? FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self = self, self.active === process else { return }
                self.consume(data)
            }
        }
        active = process
        process.terminationHandler = { [weak self] child in
            output.fileHandleForReading.readabilityHandler = nil
            try? errorHandle?.close()
            guard let self = self else { return }
            let result: CompressionResult
            do {
                guard child.terminationStatus == 0 else {
                    let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? "FFmpeg не завершил сжатие"
                    throw NSError(domain: "Compression", code: Int(child.terminationStatus), userInfo: [NSLocalizedDescriptionKey:String(detail.suffix(700))])
                }
                try self.validate(original: job.source, compressed: temporary)
                let finalBytes = self.size(temporary)
                if finalBytes >= originalBytes {
                    try FileManager.default.removeItem(at: temporary)
                    result = CompressionResult(source: job.source, saved: job.source, originalBytes: originalBytes, finalBytes: originalBytes, error: nil)
                } else {
                    let destination = self.nextOutput(job.source)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    if job.removeOriginal { try? FileManager.default.removeItem(at: job.source) }
                    result = CompressionResult(source: job.source, saved: destination, originalBytes: originalBytes, finalBytes: finalBytes, error: nil)
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                result = CompressionResult(source: job.source, saved: job.source, originalBytes: originalBytes, finalBytes: originalBytes, error: error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: log)
            DispatchQueue.main.async {
                self.active = nil
                if result.error != nil { self.progress = 0; self.summary = "Сжатие не удалось — исходник сохранён" }
                else if result.saved == result.source { self.progress = 100; self.summary = "Запись уже компактная — оставлен исходник" }
                else { self.progress = 100; self.summary = "Готово: \(self.formatted(result.originalBytes)) → \(self.formatted(result.finalBytes))" }
                self.onResult?(result)
                if !self.jobs.isEmpty { self.startNext() }
                self.onChange?()
            }
        }
        do { try process.run(); onChange?() }
        catch {
            active = nil; output.fileHandleForReading.readabilityHandler = nil
            try? errorHandle?.close(); try? FileManager.default.removeItem(at: log)
            summary = "Сжатие не запустилось — исходник сохранён"
            onResult?(CompressionResult(source: job.source, saved: job.source, originalBytes: originalBytes, finalBytes: originalBytes, error: error.localizedDescription))
            if !jobs.isEmpty { startNext() }
            onChange?()
        }
    }

    private func validate(original: URL, compressed: URL) throws {
        let before = AVURLAsset(url: original, options: [AVURLAssetPreferPreciseDurationAndTimingKey:true])
        let after = AVURLAsset(url: compressed, options: [AVURLAssetPreferPreciseDurationAndTimingKey:true])
        guard size(compressed) > 1024, let originalVideo = before.tracks(withMediaType: .video).first,
              let video = after.tracks(withMediaType: .video).first,
              after.duration.seconds.isFinite, after.duration.seconds > 0,
              abs(before.duration.seconds-after.duration.seconds) <= max(1, before.duration.seconds*0.02),
              abs(originalVideo.naturalSize.width) == abs(video.naturalSize.width),
              abs(originalVideo.naturalSize.height) == abs(video.naturalSize.height),
              before.tracks(withMediaType: .audio).isEmpty || !after.tracks(withMediaType: .audio).isEmpty else {
            throw NSError(domain: "Compression", code: 2, userInfo: [NSLocalizedDescriptionKey:"Сжатый файл не прошёл проверку длительности, изображения или звука"])
        }
    }
}
