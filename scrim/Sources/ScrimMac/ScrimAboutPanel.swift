import AppKit
import SwiftUI

@MainActor
final class ScrimAboutPanel {
    private var window: NSPanel?

    func show() {
        let panel = window ?? makePanel()
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let versionLabel = version.map { version in
            build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
        } ?? "Development build"
        let artwork = bundle.url(forResource: "ScrimIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        let repository = Self.repositoryURL(bundle.object(forInfoDictionaryKey: "ScrimRepositoryURL") as? String
            ?? "https://github.com/jquyatt/FreeShow")
        let content = NSHostingView(rootView: ScrimAboutView(version: versionLabel, artwork: artwork, repository: repository))
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "About Scrim"
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        // Keep operator controls on the primary screen, never on the HDMI feed.
        if let frame = NSScreen.screens.first?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        return panel
    }

    nonisolated static func repositoryURL(_ value: String?) -> URL? {
        guard let value, let components = URLComponents(string: value),
              components.scheme == "https", components.host?.lowercased() == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else { return nil }
        let slug = components.path.split(separator: "/")
        guard slug.count == 2,
              slug.allSatisfy({ $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) } }),
              components.percentEncodedPath == "/\(slug[0])/\(slug[1])" else { return nil }
        return url
    }
}

private struct ScrimAboutView: View {
    let version: String
    let artwork: NSImage?
    let repository: URL?

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let artwork {
                    Image(nsImage: artwork).resizable()
                } else {
                    Image(nsImage: ScrimMenuIcon.makeImage()).resizable().renderingMode(.template)
                }
            }
            .scaledToFit()
            .frame(width: 84, height: 84)
            .accessibilityHidden(true)

            Text("Scrim").font(.title.bold())
            Text(version).foregroundStyle(.secondary)
            Text("Native macOS output renderer for FreeShow")
                .padding(.top, 5)
            Text("Created by Jake Wyatt")
            if let repository {
                Link("View Scrim on GitHub", destination: repository)
                    .padding(.top, 5)
            } else {
                Text("GitHub repository not yet configured")
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(width: 360)
        .fixedSize(horizontal: true, vertical: true)
    }
}
