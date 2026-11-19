import XCTest

final class InsulinProfileTests: XCTestCase {
    private func profile() -> InsulinProfile {
        InsulinProfile(name: "Main", isMain: true, segments: [
            ProfileSegment(startMinute: 360, basalUnitsPerHour: 1, sensitivityMgdlPerUnit: 50),
            ProfileSegment(startMinute: 660, basalUnitsPerHour: 0.8, sensitivityMgdlPerUnit: 45),
            ProfileSegment(startMinute: 960, basalUnitsPerHour: 0.9, sensitivityMgdlPerUnit: 40),
        ])
    }

    func testSegmentLookupWrapsPastMidnight() {
        let p = profile()
        XCTAssertEqual(p.segment(atMinute: 400)?.basalUnitsPerHour, 1)
        XCTAssertEqual(p.segment(atMinute: 660)?.basalUnitsPerHour, 0.8)
        XCTAssertEqual(p.segment(atMinute: 100)?.basalUnitsPerHour, 0.9)
        XCTAssertEqual(p.endMinute(of: p.sortedSegments[2]), 360)
    }

    func testValidation() {
        var p = profile()
        XCTAssertTrue(p.issues.isEmpty)
        p.segments[0].sensitivityMgdlPerUnit = 0
        p.segments[1].startMinute = 360
        XCTAssertEqual(p.issues.count, 2)
    }

    func testMainIsProtectedAndManualChoiceBeatsHooks() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "profile-test-\(UUID())"))
        let store = InsulinProfileStore(defaults: defaults)
        let sick = InsulinProfile(name: "Sick", segments: [ProfileSegment(startMinute: 0, basalUnitsPerHour: 1.5, sensitivityMgdlPerUnit: 35)])
        store.save(sick)
        store.delete(store.main.id)
        XCTAssertEqual(store.profiles.count, 2)

        struct Hook: ProfileSwitchHook {
            let name = "test"
            let decisionToReturn: ProfileSwitchDecision
            func decision(in context: ProfileSwitchContext, profiles: [InsulinProfile]) -> ProfileSwitchDecision { decisionToReturn }
        }
        let context = ProfileSwitchContext(date: Date(), glucose: nil)
        store.hooks = [Hook(decisionToReturn: .use(sick.id))]
        store.evaluateHooks(context)
        XCTAssertEqual(store.active.id, sick.id)
        XCTAssertEqual(store.activationSource, .automatic)

        store.hooks = [Hook(decisionToReturn: .useMain)]
        store.activate(sick.id)
        store.evaluateHooks(context)
        XCTAssertEqual(store.active.id, sick.id)
        XCTAssertEqual(InsulinProfileStore(defaults: defaults).active.id, sick.id)
    }
}

final class ServiceConnectionTests: XCTestCase {
    func testValidation() {
        XCTAssertFalse(ServiceConnection.nightscout().issues.isEmpty)
        var nightscout = ServiceConnection.nightscout()
        nightscout.baseURL = "https://example.herokuapp.com"
        XCTAssertTrue(nightscout.issues.isEmpty)
        var mtls = ServiceConnection.mutualTLSService()
        mtls.name = "Service"
        mtls.baseURL = "http://insecure.example.com"
        XCTAssertEqual(mtls.issues.count, 2)
        mtls.baseURL = "https://secure.example.com"
        mtls.identityLabel = "label"
        XCTAssertTrue(mtls.issues.isEmpty)
    }
}
