import AppKit
import KeyNavSystem

let arguments = CommandLine.arguments

/// Prints what this binary can actually do. Launched through `open`, it reports the app's own identity.
func writeDiagnosis(to path: String?) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let report = Permissions.report()
    let data = (try? encoder.encode(report)) ?? Data()
    if let path {
        try? data.write(to: URL(fileURLWithPath: path))
    } else {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(report.status == .ready ? 0 : 2)
}

if arguments.contains("--diagnose") {
    writeDiagnosis(to: nil)
}
if let index = arguments.firstIndex(of: "--diagnose-file"), arguments.indices.contains(index + 1) {
    writeDiagnosis(to: arguments[index + 1])
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(arguments: arguments)
    app.delegate = delegate
    // No Dock icon or app-switcher entry until Settings opens.
    app.setActivationPolicy(.accessory)
    app.run()
}
