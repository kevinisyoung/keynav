import XCTest
@testable import KeyNavCore

final class LicenseTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func day(_ n: Double) -> Date { start.addingTimeInterval(n * 86_400) }

    func testTrialCountsDownFourteenDays() {
        XCTAssertEqual(Trial.status(firstLaunch: start, now: start, licensed: false), .trial(daysLeft: 14))
        XCTAssertEqual(Trial.status(firstLaunch: start, now: day(0.9), licensed: false), .trial(daysLeft: 14))
        XCTAssertEqual(Trial.status(firstLaunch: start, now: day(13.5), licensed: false), .trial(daysLeft: 1))
        XCTAssertEqual(Trial.status(firstLaunch: start, now: day(14), licensed: false), .trialEnded)
        XCTAssertFalse(LicenseStatus.trialEnded.allowsUse)
    }

    func testALicenseOutlastsTheTrial() {
        XCTAssertEqual(Trial.status(firstLaunch: start, now: day(400), licensed: true), .licensed)
    }

    func testTurningTheClockBackDoesNotExtendTheTrial() {
        XCTAssertEqual(Trial.status(firstLaunch: start, now: day(-30), licensed: false), .trial(daysLeft: 14))
    }
}
