import Testing
@testable import ScrimMac

@Test func aboutOnlyLinksToConfiguredGitHubRepository() {
    let repository = "https://github.com/example/scrim"
    #expect(ScrimAboutPanel.repositoryURL(repository)?.absoluteString == repository)
    #expect(ScrimAboutPanel.repositoryURL(nil) == nil)
    #expect(ScrimAboutPanel.repositoryURL("https://github.com/example") == nil)
    #expect(ScrimAboutPanel.repositoryURL("https://github.com/example/scrim/issues") == nil)
    #expect(ScrimAboutPanel.repositoryURL("https://github.com.example.com/example/scrim") == nil)
    #expect(ScrimAboutPanel.repositoryURL("https://github.com/example/%2e%2e") == nil)
    #expect(ScrimAboutPanel.repositoryURL("http://github.com/example/scrim") == nil)
}
