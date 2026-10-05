import AppKit
import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class JobStore {
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/BlenderRenderMonitor")
    static let jobsDir = supportDir.appending(path: "jobs")
    static let hookURL = supportDir.appending(path: "render_monitor.py")

    private(set) var jobs: [RenderJob] = []
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?

    init() {
        installHook()
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var activeJobs: [RenderJob] { jobs.filter { $0.state(now: now).isActive } }

    func job(id: String) -> RenderJob? { jobs.first { $0.id == id } }

    func refresh() {
        now = Date()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.jobsDir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let loaded: [RenderJob] = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let info = try? decoder.decode(JobStatus.self, from: data) else { return nil }
            return RenderJob(info: info, isAlive: Self.isBlenderRunning(pid: info.pid), file: url)
        }
        let sorted = loaded.sorted { a, b in
            let aActive = a.state(now: now).isActive, bActive = b.state(now: now).isActive
            if aActive != bActive { return aActive }
            return a.info.startedAt > b.info.startedAt
        }
        if sorted != jobs { jobs = sorted }
    }

    /// Removes the status files of Blender processes that have exited.
    func clearFinished() {
        for job in jobs where !job.isAlive {
            try? FileManager.default.removeItem(at: job.file)
        }
        refresh()
    }

    func copyHookArgument() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("--python \"\(Self.hookURL.path)\"", forType: .string)
    }

    func revealHook() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.hookURL])
    }

    /// Keeps a copy of the Blender hook at a stable path that render scripts can reference.
    private func installHook() {
        guard let bundled = Bundle.main.url(forResource: "render_monitor", withExtension: "py"),
              let contents = try? Data(contentsOf: bundled) else { return }
        try? FileManager.default.createDirectory(at: Self.jobsDir, withIntermediateDirectories: true)
        if (try? Data(contentsOf: Self.hookURL)) != contents {
            try? contents.write(to: Self.hookURL, options: .atomic)
        }
    }

    private static func isBlenderRunning(pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return true }
        return String(cString: buffer).localizedCaseInsensitiveContains("blender")
    }
}
