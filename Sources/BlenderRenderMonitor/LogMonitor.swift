import Darwin
import Foundation

/// Follows Blender processes that were started without the hook, using what they print to their log file.
@MainActor
final class LogMonitor {
    private final class Tracker {
        let pid: pid_t
        let started: Date
        let args: [String]
        let cwd: String?
        let logPath: String
        var offset: UInt64 = 0
        var partial = ""
        var frames: [(frame: Int, elapsed: Double)] = []
        var blendPath: String?
        var lastOutput: String?
        var alive = true

        init(pid: pid_t, started: Date, args: [String], cwd: String?, logPath: String) {
            self.pid = pid
            self.started = started
            self.args = args
            self.cwd = cwd
            self.logPath = logPath
            blendPath = args.dropFirst().first { $0.hasSuffix(".blend") }.map { Self.resolve($0, cwd: cwd) }
        }

        static func resolve(_ path: String, cwd: String?) -> String {
            guard !path.hasPrefix("/"), let cwd else { return path }
            return (cwd as NSString).appendingPathComponent(path)
        }
    }

    private var trackers: [pid_t: Tracker] = [:]
    private let ranges = FrameRangeCache()

    private static let timestamp = #"^\s*(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)\s"#
    private static let savedRE = try! NSRegularExpression(pattern: timestamp + #".*\| Saved: '(.+)'"#)
    private static let appendRE = try! NSRegularExpression(pattern: timestamp + #".*Video append frame (\d+)"#)
    private static let readBlendRE = try! NSRegularExpression(pattern: #"Read blend: "(.+\.blend)""#)
    private static let savedBlendRE = try! NSRegularExpression(pattern: #"Saved as "(.+\.blend)""#)
    private static let trailingNumberRE = try! NSRegularExpression(pattern: #"(\d+)(?:\.[A-Za-z0-9]+)?$"#)

    func update(excluding hookPIDs: Set<pid_t>, now: Date) -> [RenderJob] {
        let running = Set(ProcessInspector.blenderPIDs())
        for (pid, tracker) in trackers where !running.contains(pid) {
            tracker.alive = false
        }
        for pid in running where trackers[pid] == nil && !hookPIDs.contains(pid) {
            guard let log = ProcessInspector.stdoutPath(pid: pid),
                  let started = ProcessInspector.startTime(pid: pid) else { continue }
            trackers[pid] = Tracker(pid: pid, started: started, args: ProcessInspector.arguments(pid: pid),
                                    cwd: ProcessInspector.cwd(pid: pid), logPath: log)
        }
        return trackers.values.compactMap { tracker in
            if hookPIDs.contains(tracker.pid) { return nil }
            if tracker.alive { read(tracker) }
            return job(for: tracker, now: now)
        }
    }

    func forgetExited() {
        trackers = trackers.filter { $0.value.alive }
    }

    private func read(_ t: Tracker) {
        guard let handle = FileHandle(forReadingAtPath: t.logPath) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < t.offset { t.offset = 0; t.frames = []; t.partial = "" }
        guard size > t.offset else { return }
        try? handle.seek(toOffset: t.offset)
        guard let data = try? handle.readToEnd() else { return }
        t.offset += UInt64(data.count)
        let lines = (t.partial + String(decoding: data, as: UTF8.self)).components(separatedBy: "\n")
        t.partial = lines.last ?? ""
        for line in lines.dropLast() { parse(line, into: t) }
    }

    private func parse(_ line: String, into t: Tracker) {
        let range = NSRange(line.startIndex..., in: line)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            Range(m.range(at: i), in: line).map { String(line[$0]) }
        }
        func elapsed(_ m: NSTextCheckingResult) -> Double {
            Double(group(m, 1) ?? "0")! * 3600 + Double(group(m, 2)!)! * 60 + Double(group(m, 3)!)!
        }
        if let m = Self.savedRE.firstMatch(in: line, range: range), let path = group(m, 4) {
            t.lastOutput = path
            let name = ((path as NSString).lastPathComponent as NSString)
            let nameRange = NSRange(location: 0, length: name.length)
            if let n = Self.trailingNumberRE.firstMatch(in: name as String, range: nameRange),
               let frame = Int(name.substring(with: n.range(at: 1))) {
                t.frames.append((frame, elapsed(m)))
            }
        } else if let m = Self.appendRE.firstMatch(in: line, range: range), let frame = group(m, 4).flatMap(Int.init) {
            t.frames.append((frame, elapsed(m)))
        } else if let m = Self.readBlendRE.firstMatch(in: line, range: range) ?? Self.savedBlendRE.firstMatch(in: line, range: range),
                  let path = group(m, 1) {
            t.blendPath = Tracker.resolve(path, cwd: t.cwd)
        }
    }

    private func job(for t: Tracker, now: Date) -> RenderJob? {
        guard let last = t.frames.last else { return nil }
        let start = t.started.timeIntervalSince1970
        let step = t.frames.count > 1 ? max(1, last.frame - t.frames[t.frames.count - 2].frame) : 1
        let times = zip(t.frames, t.frames.dropFirst()).suffix(100).map { prev, cur in
            JobStatus.FrameTime(frame: cur.frame, seconds: cur.elapsed - prev.elapsed, finishedAt: start + cur.elapsed)
        }
        let range = t.blendPath.flatMap { ranges.range(for: $0, blender: ProcessInspector.path(pid: t.pid)) }
        let info = JobStatus(
            pid: t.pid, blenderVersion: nil, background: t.args.contains("-b") || t.args.contains("--background"),
            startedAt: start, updatedAt: start + last.elapsed,
            status: t.alive ? "rendering" : "complete",
            currentFrame: last.frame + step, currentFrameStartedAt: t.alive ? start + last.elapsed : nil,
            framesRendered: t.frames.count, lastCompletedFrame: last.frame,
            sample: nil, samples: nil, frameRemaining: nil, statsAt: nil, frameTimes: times,
            blendFile: t.blendPath ?? "", scene: "Scene", engine: "",
            outputPath: t.lastOutput ?? t.logPath, resolution: nil,
            frameStart: range?.start ?? 0, frameEnd: range?.end ?? 0, frameStep: range?.step ?? step,
            rangeKnown: range != nil, logPath: t.logPath)
        return RenderJob(info: info, isAlive: t.alive, statusFile: nil)
    }
}

/// Asks Blender for a .blend file's frame range, once per file version.
@MainActor
final class FrameRangeCache {
    struct FrameRange { let start: Int, end: Int, step: Int }

    private var cache: [String: FrameRange?] = [:]

    func range(for blend: String, blender: String?) -> FrameRange? {
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: blend))?[.modificationDate] as? Date
        else { return nil }
        let key = "\(blend)|\(mtime.timeIntervalSince1970)"
        if let cached = cache[key] { return cached }
        guard let blender else { return nil }
        cache[key] = .some(nil)
        query(blend: blend, blender: blender, key: key)
        return nil
    }

    private func query(blend: String, blender: String, key: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: blender)
        process.arguments = ["-b", "--factory-startup", blend, "--python-expr",
                             "import bpy; s = bpy.context.scene; print('BRM_RANGE', s.frame_start, s.frame_end, s.frame_step)"]
        process.qualityOfService = .background
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let line = output.split(separator: "\n").first { $0.hasPrefix("BRM_RANGE") }
            let parts = line?.split(separator: " ").dropFirst().compactMap { Int($0) } ?? []
            Task { @MainActor in
                if parts.count == 3 {
                    self.cache[key] = FrameRange(start: parts[0], end: parts[1], step: max(1, parts[2]))
                }
            }
        }
        try? process.run()
    }
}

enum ProcessInspector {
    static func blenderPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(max(0, Int(n))).filter { pid in
            pid > 0 && path(pid: pid).map { ($0 as NSString).lastPathComponent.lowercased() == "blender" } == true
        }
    }

    static func path(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func arguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = 4
        while index < size && buffer[index] != 0 { index += 1 }  // executable path
        while index < size && buffer[index] == 0 { index += 1 }  // padding
        var args: [String] = []
        while args.count < argc && index < size {
            let end = buffer[index...].firstIndex(of: 0) ?? size
            args.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return args
    }

    static func cwd(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    static func startTime(pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// The regular file that the process's standard output goes to, if any.
    static func stdoutPath(pid: pid_t) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, 1, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty || path.hasPrefix("/dev/") ? nil : path
    }
}
