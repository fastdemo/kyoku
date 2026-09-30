import XCTest
@testable import Kyoku

/// Scheduler due-logic: pure isDue/nextCheckDescription with injected jobs.
/// No timers fire in tests (tick is called directly with fixed dates).
final class SchedulerTests: XCTestCase {
    @MainActor
    private func scheduler() -> SyncScheduler2 {
        SyncScheduler2()
    }

    private func job(schedule: SyncSchedule = .every30Minutes, enabled: Bool = true,
                     lastRun: Date? = nil, failures: Int = 0) -> SyncJobConfig {
        SyncJobConfig(sourceID: "s", name: "J", schedule: schedule,
                      enabled: enabled, lastRunAt: lastRun,
                      consecutiveFailures: failures)
    }

    @MainActor
    func testManualNeverDue() {
        let s = scheduler()
        XCTAssertFalse(s.isDue(job(schedule: .manual), now: Date()))
    }

    @MainActor
    func testDisabledNeverDue() {
        let s = scheduler()
        XCTAssertFalse(s.isDue(job(schedule: .hourly, enabled: false), now: Date()))
    }

    @MainActor
    func testNeverRunIsDue() {
        let s = scheduler()
        XCTAssertTrue(s.isDue(job(lastRun: nil), now: Date()))
    }

    @MainActor
    func testDueAfterInterval() {
        let s = scheduler()
        let now = Date()
        XCTAssertTrue(s.isDue(job(schedule: .hourly, lastRun: now.addingTimeInterval(-3700)), now: now))
        XCTAssertFalse(s.isDue(job(schedule: .hourly, lastRun: now.addingTimeInterval(-100)), now: now))
    }

    @MainActor
    func testBackoffDelaysFailingJob() {
        let s = scheduler()
        let now = Date()
        // 3 consecutive failures → backoff max(30min schedule, 8min backoff)... backoff=480s < 1800s,
        // so schedule still governs. Use 15-min schedule: backoff 8min < 900s → due by schedule.
        // 6 failures → backoff 3840→capped 3600s > 900s → delayed.
        let failing = job(schedule: .every15Minutes,
                          lastRun: now.addingTimeInterval(-1000), failures: 6)
        XCTAssertFalse(s.isDue(failing, now: now),
                       "backoff (3600s) must delay a job whose schedule (900s) already elapsed")
        let recovered = job(schedule: .every15Minutes,
                            lastRun: now.addingTimeInterval(-1000), failures: 0)
        XCTAssertTrue(s.isDue(recovered, now: now))
    }

    @MainActor
    func testNextCheckDescriptions() {
        let s = scheduler()
        let now = Date()
        XCTAssertEqual(s.nextCheckDescription(job(schedule: .manual, enabled: true), now: now), "Manual only")
        XCTAssertEqual(s.nextCheckDescription(job(enabled: false), now: now), "Paused")
        XCTAssertEqual(s.nextCheckDescription(job(lastRun: nil), now: now), "Due now")
        let recent = job(schedule: .hourly, lastRun: now.addingTimeInterval(-100))
        XCTAssertTrue(s.nextCheckDescription(recent, now: now).hasPrefix("Next check in"))
    }

    @MainActor
    func testTickFiresDueJobs() {
        let s = scheduler()
        var fired: [[SyncJobConfig]] = []
        s.onDueJobs = { fired.append($0) }
        let due = job(schedule: .hourly, lastRun: Date().addingTimeInterval(-4000))
        s.jobProvider = { [due] }
        s.tick()
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.count, 1)
    }

    @MainActor
    func testTickSkipsRunningJobs() {
        let s = scheduler()
        var fired: [[SyncJobConfig]] = []
        s.onDueJobs = { fired.append($0) }
        let due = job(schedule: .hourly, lastRun: Date().addingTimeInterval(-4000))
        s.jobProvider = { [due] }
        s.markRunning(due.id)
        s.tick()
        XCTAssertTrue(fired.isEmpty, "overlapping runs must be prevented")
    }
}
