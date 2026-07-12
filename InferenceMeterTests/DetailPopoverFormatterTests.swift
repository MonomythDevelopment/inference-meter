import Foundation
import Testing
@testable import InferenceMeter

@Test("Countdown formats future reset windows")
func countdownFormatsFutureResetWindows() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let twoHours: TimeInterval = 2 * 60 * 60
    let fourteenMinutes: TimeInterval = 14 * 60
    let resetsAt = now.addingTimeInterval(twoHours + fourteenMinutes)

    #expect(countdownString(to: resetsAt, now: now) == "2h 14m")
}

@Test("Countdown formats multi-day reset windows")
func countdownFormatsMultiDayResetWindows() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let threeDays: TimeInterval = 3 * 24 * 60 * 60
    let fiveHours: TimeInterval = 5 * 60 * 60
    let fortyTwoMinutes: TimeInterval = 42 * 60
    let resetsAt = now.addingTimeInterval(threeDays + fiveHours + fortyTwoMinutes)

    #expect(countdownString(to: resetsAt, now: now) == "3d 5h")
}

@Test("Countdown omits nil reset times")
func countdownOmitsNilResetTimes() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(countdownString(to: nil, now: now) == nil)
}

@Test("Countdown uses resetting sentinel for past reset times")
func countdownUsesResettingSentinelForPastResetTimes() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let resetsAt = now.addingTimeInterval(-1)

    #expect(countdownString(to: resetsAt, now: now) == "resetting…")
}

@Test("Relative updated string formats representative deltas")
func relativeUpdatedStringFormatsRepresentativeDeltas() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(relativeUpdatedString(from: now.addingTimeInterval(-12), now: now) == "12s ago")
    #expect(relativeUpdatedString(from: now.addingTimeInterval(-180), now: now) == "3m ago")
    #expect(relativeUpdatedString(from: now.addingTimeInterval(-7_200), now: now) == "2h ago")
    #expect(relativeUpdatedString(from: now.addingTimeInterval(-172_800), now: now) == "2d ago")
}
