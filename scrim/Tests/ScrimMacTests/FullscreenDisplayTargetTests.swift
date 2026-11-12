import Testing
@testable import ScrimMac

private let operatorScreen = FullscreenDisplayTarget.Display(id: 1, identity: "operator", eligible: false)
private let hdmi = FullscreenDisplayTarget.Display(id: 2, identity: "hdmi", eligible: true)
private let spare = FullscreenDisplayTarget.Display(id: 3, identity: "spare", eligible: true)

@Test func fullscreenWaitsRatherThanUsingOperatorScreen() {
    var automatic = FullscreenDisplayTarget(requestedIndex: nil)
    #expect(automatic.resolve([operatorScreen]) == nil)
    #expect(automatic.resolve([operatorScreen, hdmi]) == hdmi.id)

    var indexed = FullscreenDisplayTarget(requestedIndex: 1)
    #expect(indexed.resolve([operatorScreen]) == nil)
    #expect(indexed.resolve([operatorScreen, hdmi]) == hdmi.id)

    var primary = FullscreenDisplayTarget(requestedIndex: 0)
    #expect(primary.resolve([operatorScreen, hdmi]) == nil)
}

@Test func fullscreenReattachesOnlyToOriginalDisplayIdentity() {
    var target = FullscreenDisplayTarget(requestedIndex: 1)
    #expect(target.resolve([operatorScreen, hdmi, spare]) == hdmi.id)
    #expect(target.resolve([operatorScreen, spare]) == nil)
    let reusedID = FullscreenDisplayTarget.Display(id: hdmi.id, identity: "other", eligible: true)
    #expect(target.resolve([operatorScreen, reusedID]) == nil)
    let returned = FullscreenDisplayTarget.Display(id: 4, identity: "hdmi", eligible: true)
    #expect(target.resolve([operatorScreen, spare, returned]) == returned.id)
    let nowPrimary = FullscreenDisplayTarget.Display(id: 4, identity: "hdmi", eligible: false)
    #expect(target.resolve([nowPrimary, spare]) == nil)
    #expect(target.resolve([operatorScreen, hdmi, returned]) == nil)
}

@Test func explicitDisplayAssignmentsStayIndependentAcrossHotplug() {
    var first = FullscreenDisplayTarget(requestedIndex: nil, identity: "hdmi")
    var second = FullscreenDisplayTarget(requestedIndex: nil, identity: "spare")
    #expect(first.resolve([operatorScreen, spare]) == nil)
    #expect(second.resolve([operatorScreen, spare]) == spare.id)
    let returned = FullscreenDisplayTarget.Display(id: 22, identity: "hdmi", eligible: true)
    #expect(first.resolve([operatorScreen, spare, returned]) == returned.id)
    #expect(second.resolve([operatorScreen, spare, returned]) == spare.id)
    #expect(second.resolve([operatorScreen, returned]) == nil)
    #expect(first.resolve([operatorScreen, returned]) == returned.id)
}
