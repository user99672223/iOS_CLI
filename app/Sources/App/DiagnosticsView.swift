import SwiftUI
import Darwin

/// Live diagnostics, refreshed once a second while visible.
struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sampler = DiagnosticsSampler()

    var body: some View {
        List {
            Section("JIT") {
                row("State", sampler.jitState)
                row("CS_DEBUGGED", yes(sampler.jit.cs_debugged != 0))
                row("Debugger attached", yes(sampler.debuggerAttached))
                row("Pool", sampler.jit.pool_ready != 0 ? "\(sampler.jit.pool_size >> 20) MB at \(JITStatus.hex(sampler.jit.pool_rx))" : "not created")
                row("Method", JITStatus.method(sampler.jit).isEmpty ? "—" : JITStatus.method(sampler.jit))
                row("Exe window 0x140000000", sampler.jit.window_base != 0 ? "reserved" : "not reserved")
                if !JITStatus.error(sampler.jit).isEmpty { Text(JITStatus.error(sampler.jit)).font(.caption).foregroundStyle(.red) }
            }
            Section("Memory") {
                row("Footprint", MemoryStats.mb(sampler.footprint))
                row("Available", MemoryStats.mb(sampler.available))
                row("Address space", sampler.addressSpace)
                row("Extended virtual addressing", yes(sampler.extendedVA))
                row("Increased memory limit", sampler.increasedLimit)
            }
            Section("CPU") {
                row("Total", String(format: "%.0f%%", sampler.cpuTotal))
                row("Thermal state", sampler.thermal)
                ForEach(sampler.topThreads, id: \.name) { t in
                    row(t.name, String(format: "%.0f%%", t.cpu))
                }
            }
            Section("Windows processes") {
                if sampler.processes.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(sampler.processes, id: \.self) { p in
                    Text(p).font(.caption.monospaced()).lineLimit(3)
                }
            }
            Section("Versions") {
                row("Wine", "11.4 (Madeira port)")
                row("Claude Code", ToolInstaller.installedClaudeVersion ?? "—")
                row("Git", ToolInstaller.installedGitVersion ?? "—")
                row("Running in LiveContainer", yes(JITEnabler.inLiveContainer))
                row("Background run", BackgroundKeeper.shared.isKeeping ? "active" : "idle")
            }
            Section {
                ScrollView(.horizontal) {
                    Text(sampler.logTail.isEmpty ? "(empty)" : sampler.logTail)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
                ShareLink(item: AppPaths.wineLog) { Label("Share the log", systemImage: "square.and.arrow.up") }
            } header: { Text("Latest log lines") }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear { sampler.start() }
        .onDisappear { sampler.stop() }
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).font(.callout.monospacedDigit()).multilineTextAlignment(.trailing) }
    }
    private func yes(_ b: Bool) -> String { b ? "Yes" : "No" }
}

@MainActor
final class DiagnosticsSampler: ObservableObject {
    struct ThreadCPU { var name: String; var cpu: Double }

    @Published var jit = cli_jit_info()
    @Published var jitState = ""
    @Published var debuggerAttached = false
    @Published var footprint: UInt64 = 0
    @Published var available: UInt64 = 0
    @Published var addressSpace = ""
    @Published var extendedVA = false
    @Published var increasedLimit = ""
    @Published var cpuTotal = 0.0
    @Published var topThreads: [ThreadCPU] = []
    @Published var thermal = ""
    @Published var processes: [String] = []
    @Published var logTail = ""
    private var timer: Timer?

    func start() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func sample() {
        var info = cli_jit_info()
        cli_jit_query(&info)
        jit = info
        switch JITEnabler.state {
        case .simulator: jitState = "Simulator"
        case .ready: jitState = "On (debugger attached)"
        case .enabledDetached: jitState = info.pool_ready != 0 ? "On" : "On, no debugger"
        case .off: jitState = "Off"
        }
        debuggerAttached = cli_debugger_attached() != 0
        footprint = MemoryStats.physFootprint
        available = MemoryStats.available
        if let vm = MemoryStats.taskVMInfo() {
            addressSpace = "\(JITStatus.hex(vm.min_address)) – \(JITStatus.hex(vm.max_address))"
            extendedVA = vm.max_address >= 0x80_0000_0000
        }
        // The default jetsam limit on a 6 GB iPhone is ~3 GB; the entitlement raises it.
        let limit = footprint + available
        increasedLimit = String(format: "%.1f GB limit%@", Double(limit) / 1_073_741_824,
                                limit > 3_400_000_000 ? " (raised)" : "")
        let threads = Self.threadCPU()
        cpuTotal = threads.reduce(0) { $0 + $1.cpu }
        topThreads = Array(threads.sorted { $0.cpu > $1.cpu }.prefix(5).filter { $0.cpu >= 1 })
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Nominal"
        case .fair: thermal = "Fair"
        case .serious: thermal = "Serious"
        case .critical: thermal = "Critical"
        @unknown default: thermal = "Unknown"
        }
        var buf = [CChar](repeating: 0, count: 16384)
        let n = cli_list_processes(&buf, Int32(buf.count))
        processes = n > 0 ? String(cString: buf).split(separator: "\n").map { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            return f.count >= 3 ? "\(f[0])  (\(f[2]) s)\n\(f[1])" : String(line)
        } : []
        logTail = Self.tail(AppPaths.wineLog, lines: 30)
    }

    static func tail(_ url: URL, lines: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 16384 ? size - 16384 : 0)
        let s = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        return SignInFlow.redact(s.split(separator: "\n").suffix(lines).joined(separator: "\n"))
    }

    /// CPU per thread from task_threads/thread_info.
    static func threadCPU() -> [ThreadCPU] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var out: [ThreadCPU] = []
        for i in 0..<Int(count) {
            var basic = thread_basic_info()
            var n = mach_msg_type_number_t(THREAD_BASIC_INFO_COUNT)
            let kr = withUnsafeMutablePointer(to: &basic) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &n)
                }
            }
            guard kr == KERN_SUCCESS, basic.flags & TH_FLAGS_IDLE == 0 else { mach_port_deallocate(mach_task_self_, list[i]); continue }
            var name = "thread \(i)"
            var ext = thread_extended_info()
            var en = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<natural_t>.size)
            if withUnsafeMutablePointer(to: &ext, {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(en)) {
                    thread_info(list[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &en)
                }
            }) == KERN_SUCCESS {
                let n = withUnsafeBytes(of: ext.pth_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                if !n.isEmpty { name = n }
            }
            out.append(ThreadCPU(name: name, cpu: Double(basic.cpu_usage) / Double(TH_USAGE_SCALE) * 100))
            mach_port_deallocate(mach_task_self_, list[i])
        }
        return out
    }
}
