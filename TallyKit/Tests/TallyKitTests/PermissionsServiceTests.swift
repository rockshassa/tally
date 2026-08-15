import Foundation
import Testing
@testable import TallyKit

/// Gate 0: "`PermissionsService` ships behind a protocol with a mock, so UI agents
/// can test permission states without dialogs" (PLAN Wave 0, SPEC §9).
@Suite("PermissionsService")
@MainActor
struct PermissionsServiceTests {

    @Test("The mock satisfies the protocol UI agents will inject")
    func mockIsAPermissionsService() {
        let service: any PermissionsService = MockPermissionsService()
        #expect(service.locationAuthorization() == .notDetermined)
    }

    @Test("Granting When-In-Use moves the status and records the ask")
    func whenInUseGrant() async {
        let service = MockPermissionsService()
        #expect(await service.requestLocationWhenInUse() == .whenInUse)
        #expect(service.locationAuthorization().allowsOneShotFix)
        #expect(!service.locationAuthorization().allowsBarRadar)
        #expect(service.received(.locationWhenInUse))
    }

    @Test("Declining leaves logging working with no coordinates")
    func whenInUseDenial() async {
        let service = MockPermissionsService(grantOnRequest: false)
        #expect(await service.requestLocationWhenInUse() == .denied)
        #expect(!service.locationAuthorization().allowsOneShotFix)
        #expect(service.locationAuthorization().needsSystemSettings)
    }

    @Test("Bar Radar upgrades When-In-Use to Always")
    func alwaysUpgrade() async {
        let service = MockPermissionsService(locationStatus: .whenInUse)
        #expect(await service.requestLocationAlways() == .always)
        #expect(service.locationAuthorization().allowsBarRadar)
        #expect(service.received(.locationAlways))
    }

    @Test("Declining the upgrade drops back to When-In-Use, nothing else changes")
    func alwaysUpgradeDeclined() async {
        let service = MockPermissionsService(locationStatus: .whenInUse, grantOnRequest: false)
        #expect(await service.requestLocationAlways() == .whenInUse)
        #expect(service.locationAuthorization().allowsOneShotFix)
    }

    @Test("A denied permission never re-prompts — it deep-links instead")
    func deniedNeverRePrompts() async {
        let service = MockPermissionsService.allDenied()
        #expect(await service.requestLocationWhenInUse() == .denied)
        service.openSystemSettings()
        #expect(service.received(.openSystemSettings))
    }

    @Test("Provisional notifications are distinct from a loud grant")
    func provisionalNotifications() async {
        let service = MockPermissionsService()
        #expect(await service.requestNotifications(provisional: true) == .provisional)
        #expect(service.notificationStatus.isUsable)
        #expect(service.received(.notifications(provisional: true)))

        let loud = MockPermissionsService()
        #expect(await loud.requestNotifications() == .authorized)
        #expect(loud.received(.notifications(provisional: false)))
    }

    @Test("HealthKit read never claims to know whether it was granted")
    func healthReadOnlyRecordsTheAsk() async {
        let service = MockPermissionsService()
        #expect(service.healthAuthorization().readRequested == false)
        _ = await service.requestHealthActivityRead()
        #expect(service.healthAuthorization().readRequested)
        #expect(service.received(.healthActivityRead))
    }

    @Test("HealthKit write is off by default and grantable on its own")
    func healthWriteIsSeparate() async {
        let service = MockPermissionsService()
        #expect(service.healthAuthorization().alcoholWrite == .notDetermined)
        #expect(await service.requestHealthAlcoholWrite())
        #expect(service.healthAuthorization().alcoholWrite == .authorized)
    }

    @Test("Health being unavailable is a state, not a failure")
    func healthUnavailable() async {
        let service = MockPermissionsService(healthDataAvailable: false)
        #expect(!service.isHealthDataAvailable)
        #expect(service.healthAuthorization() == .unavailable)
        #expect(await service.requestHealthActivityRead() == false)
    }

    @Test("One snapshot feeds every Settings status row")
    func snapshotReadsEverything() async {
        let service = MockPermissionsService.allGranted()
        let snapshot = await service.snapshot()
        #expect(snapshot.location == .always)
        #expect(snapshot.notifications == .authorized)
        #expect(snapshot.health.alcoholWrite == .authorized)
    }
}
