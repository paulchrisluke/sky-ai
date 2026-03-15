import Foundation

func resolveBlawbyHome() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".blawby", isDirectory: true)
}
