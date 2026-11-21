import Foundation
import Darwin
import os

enum JITStatus {
    static func method(_ i: cli_jit_info) -> String {
        withUnsafeBytes(of: i.method) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
    static func error(_ i: cli_jit_info) -> String {
        withUnsafeBytes(of: i.error) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
    static func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

    static func describe(_ i: cli_jit_info) -> [String: String] {
        [
            "cs_debugged": "\(i.cs_debugged != 0)",
            "debugger_attached": "\(cli_debugger_attached() != 0)",
            "simulator": "\(i.simulator != 0)",
            "pool_ready": "\(i.pool_ready != 0)",
            "pool_rx": hex(i.pool_rx), "pool_rw": hex(i.pool_rw),
            "pool_size_mb": "\(i.pool_size >> 20)",
            "exe_window": i.window_base != 0 ? hex(i.window_base) : "not reserved",
            "address_space": "\(hex(i.map_min))-\(hex(i.map_max))",
            "method": method(i), "error": error(i),
        ]
    }

    /// Whether the address map is the extended one (512 GB) granted by
    /// com.apple.developer.kernel.extended-virtual-addressing.
    static func extendedVA(_ i: cli_jit_info) -> Bool { i.map_max >= 0x8000000000 }
}

enum MemoryStats {
    static func taskVMInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }

    static var physFootprint: UInt64 { taskVMInfo()?.phys_footprint ?? 0 }
    static var available: UInt64 { UInt64(os_proc_available_memory()) }

    static func mb(_ v: UInt64) -> String { String(format: "%.0f MB", Double(v) / 1_048_576) }

    static func snapshot() -> [String: String] {
        var d: [String: String] = [
            "phys_footprint": mb(physFootprint),
            "available": mb(available),
            "physical_memory": mb(ProcessInfo.processInfo.physicalMemory),
        ]
        if let i = taskVMInfo() {
            d["vm_min"] = JITStatus.hex(i.min_address)
            d["vm_max"] = JITStatus.hex(i.max_address)
            d["footprint_peak"] = mb(UInt64(max(0, i.ledger_phys_footprint_peak)))
        }
        return d
    }
}
