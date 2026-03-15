import AppKit

func resolveBlawbyHome() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".blawby", isDirectory: true)
}

let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
EnvLoader.load(from: currentDir.appendingPathComponent(".env"))

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
