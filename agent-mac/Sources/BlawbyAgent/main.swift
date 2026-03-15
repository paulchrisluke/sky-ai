import AppKit

func resolveBlawbyHome() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".blawby", isDirectory: true)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
