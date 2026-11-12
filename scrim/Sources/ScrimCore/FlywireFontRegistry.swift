import CoreText
import Foundation

/// Registers authoring fonts available to the prototype process before CoreText
/// resolves a published PostScript face. Packaged builds can put the same files
/// in a `fonts` resource directory; source builds discover FreeShow's public fonts.
public enum FlywireFontRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered = false

    public static func registerAvailableFonts() {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        registered = true

        let environment = ProcessInfo.processInfo.environment["SCRIM_FONT_DIRECTORY"].map(URL.init(fileURLWithPath:))
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let candidates = [
            environment,
            Bundle.main.resourceURL?.appendingPathComponent("fonts", isDirectory: true),
            current.appendingPathComponent("public/fonts", isDirectory: true),
            current.appendingPathComponent("../public/fonts", isDirectory: true),
            current.appendingPathComponent("../../public/fonts", isDirectory: true)
        ].compactMap { $0 }.map { $0.standardizedFileURL }

        var visited = Set<URL>()
        for directory in candidates where visited.insert(directory).inserted {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for file in files where ["otf", "ttf", "woff2"].contains(file.pathExtension.lowercased()) {
                var error: Unmanaged<CFError>?
                _ = CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error)
                if let error { _ = error.takeRetainedValue() }
            }
        }
    }
}
