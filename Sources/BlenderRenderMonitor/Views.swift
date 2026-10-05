import SwiftUI

struct ContentView: View {
    let store: JobStore

    var body: some View {
        Group {
            if store.jobs.isEmpty {
                EmptyStateView(store: store)
            } else {
                List(store.jobs) { job in
                    JobRow(store: store, job: job)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 220)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Copy --python Argument") { store.copyHookArgument() }
                    Button("Show Hook Script in Finder") { store.revealHook() }
                } label: {
                    Label("Blender Hook", systemImage: "puzzlepiece.extension")
                }
                Button {
                    store.clearFinished()
                } label: {
                    Label("Clear Finished", systemImage: "trash")
                }
                .help("Remove renders whose Blender process has exited")
                .disabled(!store.jobs.contains { !$0.isAlive })
            }
        }
    }
}

struct JobRow: View {
    let store: JobStore
    let job: RenderJob
    @State private var showDetail = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let now = store.now
        let state = job.state(now: now)
        HStack(alignment: .center, spacing: 12) {
            StateIcon(state: state)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.title).font(.headline).lineLimit(1)
                    Text(job.outputName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.head)
                }
                ProgressView(value: job.progress)
                    .tint(state == .rendering ? .accentColor : .secondary)
                HStack {
                    Text(frameText)
                    if job.sampleFraction != nil, let s = job.info.sample, let n = job.info.samples {
                        Text("· sample \(s)/\(n)")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            VStack(alignment: .trailing, spacing: 2) {
                if state == .rendering {
                    Text(Format.duration(job.secondsRemaining(now: now)))
                        .font(.title3.monospacedDigit())
                    Text("remaining").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(state.label).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if !Task.isCancelled { showDetail = true }
                }
            } else {
                showDetail = false
            }
        }
        .popover(isPresented: $showDetail, arrowEdge: .trailing) {
            JobDetail(store: store, jobID: job.id)
        }
    }

    private var frameText: String {
        let frame = job.isMidFrame ? job.info.currentFrame : (job.info.lastCompletedFrame ?? job.info.currentFrame)
        return "Frame \(frame) of \(job.info.frameStart)–\(job.info.frameEnd)"
    }
}

struct JobDetail: View {
    let store: JobStore
    let jobID: String

    var body: some View {
        if let job = store.job(id: jobID) {
            let now = store.now
            let remaining = job.secondsRemaining(now: now)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                Text(job.title).font(.headline).gridCellColumns(2)
                Divider().gridCellColumns(2)
                row("Time per frame", Format.duration(job.averageFrameSeconds)
                    + (job.info.frameTimes.count > 1 ? "  (avg of last \(min(10, job.info.frameTimes.count)))" : ""))
                row("Last frame", Format.duration(job.lastFrameSeconds))
                if let elapsed = job.currentFrameElapsed(now: now) {
                    row("Current", currentFrameText(job, elapsed: elapsed))
                }
                row("Frames left", "\(job.framesLeft) of \(job.totalFrames)")
                row("Time left", Format.duration(remaining))
                if let remaining, job.state(now: now) == .rendering {
                    row("Finishes", Format.clock(now.addingTimeInterval(remaining), relativeTo: now))
                }
                Divider().gridCellColumns(2)
                row("Rendered", "\(job.info.framesRendered) frame\(job.info.framesRendered == 1 ? "" : "s") this session")
                row("Running for", Format.duration(now.timeIntervalSince1970 - job.info.startedAt))
                row("Engine", engineText(job))
                row("Output", job.info.outputPath)
                row("Process", "PID \(job.info.pid)" + (job.isAlive ? "" : " (exited)")
                    + (job.info.background == true ? ", headless" : ""))
            }
            .font(.callout.monospacedDigit())
            .padding(14)
            .frame(width: 380)
        } else {
            Text("This render is gone.").padding()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    private func currentFrameText(_ job: RenderJob, elapsed: Double) -> String {
        var text = "frame \(job.info.currentFrame), \(Format.duration(elapsed)) so far"
        if job.sampleFraction != nil, let s = job.info.sample, let n = job.info.samples {
            text += ", sample \(s)/\(n)"
        }
        return text
    }

    private func engineText(_ job: RenderJob) -> String {
        let engine = job.info.engine.replacingOccurrences(of: "BLENDER_", with: "").capitalized
        guard let res = job.info.resolution, res.count == 2 else { return engine }
        return "\(engine), \(res[0])×\(res[1])"
    }
}

struct StateIcon: View {
    let state: RenderJob.State

    var body: some View {
        Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: state == .rendering)
            .frame(width: 28)
    }

    private var symbol: String {
        switch state {
        case .rendering: "play.circle.fill"
        case .idle: "pause.circle"
        case .finished: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .stopped: "exclamationmark.circle"
        }
    }

    private var color: Color {
        switch state {
        case .rendering: .accentColor
        case .finished: .green
        case .stopped: .orange
        case .idle, .cancelled: .secondary
        }
    }
}

struct EmptyStateView: View {
    let store: JobStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No Blender renders yet").font(.headline)
            Text("Blender reports progress through a small hook script. Load it before your own script:")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("blender -b file.blend --python \"\(JobStore.hookURL.path)\" -a")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("For interactive Blender, install the same file as an add-on.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Copy --python Argument") { store.copyHookArgument() }
                Button("Show Hook Script") { store.revealHook() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MenuBarContent: View {
    let store: JobStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.activeJobs.isEmpty {
            Text("No active renders")
        }
        ForEach(store.activeJobs) { job in
            Text("\(job.title): frame \(job.info.currentFrame)/\(job.info.frameEnd), "
                + "\(Format.duration(job.secondsRemaining(now: store.now))) left")
        }
        Divider()
        Button("Show Renders") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("r")
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct MenuBarLabel: View {
    let store: JobStore

    var body: some View {
        let active = store.activeJobs
        if let first = active.first {
            let soonest = active.compactMap { $0.secondsRemaining(now: store.now) }.min()
            let text = active.count == 1
                ? "\(first.info.currentFrame)/\(first.info.frameEnd) · \(Format.duration(soonest))"
                : "\(active.count) renders · \(Format.duration(soonest))"
            Label(text, systemImage: "film")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "film")
        }
    }
}
