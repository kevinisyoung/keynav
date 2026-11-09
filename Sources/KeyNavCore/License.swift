import Foundation

/// Whether KeyNav may run: during its free trial, or once a license is activated on this Mac.
public enum LicenseStatus: Equatable, Sendable {
    case trial(daysLeft: Int)
    case trialEnded
    case licensed

    /// Modes may start.
    public var allowsUse: Bool { self != .trialEnded }
}

public enum Trial {
    public static let days = 14

    /// The status on `now` for a trial that began on `firstLaunch`. A clock set before the first launch counts
    /// as day one rather than extending the trial.
    public static func status(firstLaunch: Date, now: Date, licensed: Bool) -> LicenseStatus {
        if licensed { return .licensed }
        let elapsed = max(0, now.timeIntervalSince(firstLaunch)) / 86_400
        let daysLeft = days - Int(elapsed.rounded(.down))
        return daysLeft > 0 ? .trial(daysLeft: daysLeft) : .trialEnded
    }
}
