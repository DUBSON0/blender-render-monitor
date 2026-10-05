import Foundation

/// Mirrors the JSON written by `blender/render_monitor.py`.
struct JobStatus: Codable, Equatable {
    struct FrameTime: Codable, Equatable {
        let frame: Int
        let seconds: Double
        let finishedAt: Double
    }

    let pid: Int32
    let blenderVersion: String?
    let background: Bool?
    let startedAt: Double
    let updatedAt: Double
    let status: String
    let currentFrame: Int
    let currentFrameStartedAt: Double?
    let framesRendered: Int
    let lastCompletedFrame: Int?
    let sample: Int?
    let samples: Int?
    /// Cycles' own estimate of the time left on the current frame, as of `statsAt`.
    let frameRemaining: Double?
    let statsAt: Double?
    let frameTimes: [FrameTime]
    let blendFile: String
    let scene: String
    let engine: String
    let outputPath: String
    let resolution: [Int]?
    let frameStart: Int
    let frameEnd: Int
    let frameStep: Int
    /// False when the job was read from a Blender log and its .blend frame range isn't known (yet).
    var rangeKnown: Bool? = nil
    /// Set when the job was read from a Blender log rather than reported by the hook.
    var logPath: String? = nil
}

struct RenderJob: Identifiable, Equatable {
    enum State {
        case rendering, idle, finished, cancelled, stopped

        var label: String {
            switch self {
            case .rendering: "Rendering"
            case .idle: "Idle"
            case .finished: "Finished"
            case .cancelled: "Cancelled"
            case .stopped: "Stopped"
            }
        }

        var isActive: Bool { self == .rendering }
    }

    let info: JobStatus
    let isAlive: Bool
    /// The hook's status file; nil for jobs read from a Blender log.
    let statusFile: URL?

    var id: String { "\(info.pid)-\(Int(info.startedAt))" }
    var hasRange: Bool { info.rangeKnown ?? true }
    var frameCounter: String { hasRange ? "\(info.currentFrame)/\(info.frameEnd)" : "\(info.currentFrame)" }

    var title: String {
        var name = (info.blendFile as NSString).lastPathComponent
        if name.isEmpty, let log = info.logPath { name = (log as NSString).lastPathComponent }
        let base = name.isEmpty ? "Untitled" : (name as NSString).deletingPathExtension
        return info.scene == "Scene" ? base : "\(base) · \(info.scene)"
    }

    /// Last two components of the output path, e.g. `final_frames_v5/frame_`.
    var outputName: String {
        let parts = info.outputPath.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    private var step: Int { max(1, info.frameStep) }
    var totalFrames: Int? { hasRange ? max(0, (info.frameEnd - info.frameStart) / step + 1) : nil }
    var isMidFrame: Bool { info.status == "rendering" && info.currentFrameStartedAt != nil }
    private var finishedLastFrame: Bool {
        !hasRange || (info.lastCompletedFrame ?? Int.min) + step > info.frameEnd
    }

    func state(now: Date) -> State {
        let sinceUpdate = now.timeIntervalSince1970 - info.updatedAt
        switch info.status {
        case "cancelled":
            return .cancelled
        case "rendering":
            return isAlive ? .rendering : .stopped
        default:
            if !isAlive { return finishedLastFrame ? .finished : .stopped }
            if finishedLastFrame { return .finished }
            // Scripts that render frame by frame complete one render job per frame.
            return sinceUpdate < 120 ? .rendering : .idle
        }
    }

    /// Frames still to render, including the one in progress.
    var framesLeft: Int? {
        guard hasRange else { return nil }
        let from = isMidFrame ? info.currentFrame : (info.lastCompletedFrame ?? info.frameStart - step) + step
        guard from <= info.frameEnd else { return 0 }
        return (info.frameEnd - max(from, info.frameStart)) / step + 1
    }

    /// Average of the most recent frames, so the estimate follows changes in scene complexity.
    var averageFrameSeconds: Double? {
        let recent = info.frameTimes.suffix(10)
        guard !recent.isEmpty else { return nil }
        return recent.map(\.seconds).reduce(0, +) / Double(recent.count)
    }

    var lastFrameSeconds: Double? { info.frameTimes.last?.seconds }

    func currentFrameElapsed(now: Date) -> Double? {
        guard isMidFrame, let start = info.currentFrameStartedAt else { return nil }
        return max(0, now.timeIntervalSince1970 - start)
    }

    var sampleFraction: Double? {
        guard isMidFrame, let s = info.sample, let n = info.samples, n > 0, s > 0 else { return nil }
        return min(1, Double(s) / Double(n))
    }

    /// Fraction of the frame range that is done, counting the part of the current frame already rendered.
    var progress: Double {
        guard let total = totalFrames, let left = framesLeft, total > 0 else { return 0 }
        let done = Double(total - left) + (sampleFraction ?? 0)
        return min(1, max(0, done / Double(total)))
    }

    func secondsRemaining(now: Date) -> Double? {
        guard let left = framesLeft else { return nil }
        guard left > 0 else { return 0 }
        let elapsed = currentFrameElapsed(now: now)
        var perFrame = averageFrameSeconds
        var currentRemaining: Double?
        if isMidFrame, let reported = info.frameRemaining, let at = info.statsAt {
            let left = max(0, reported - (now.timeIntervalSince1970 - at))
            currentRemaining = left
            if let elapsed { perFrame = perFrame ?? elapsed + left }
        } else if let elapsed, let fraction = sampleFraction, elapsed > 2 {
            let estimatedFrame = elapsed / fraction
            currentRemaining = estimatedFrame - elapsed
            perFrame = perFrame ?? estimatedFrame
        }
        guard let perFrame else { return nil }
        if isMidFrame {
            let current = currentRemaining ?? max(perFrame - (elapsed ?? 0), 0)
            return current + Double(left - 1) * perFrame
        }
        return Double(left) * perFrame
    }
}

enum Format {
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let s = Int(seconds.rounded())
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        if s < 86400 { return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60) }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }

    static func clock(_ date: Date, relativeTo now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }
}
