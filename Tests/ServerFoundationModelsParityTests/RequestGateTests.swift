import Testing
@testable import ServerFoundationModels

private actor GateProbe {
    var current = 0
    var peak = 0
    var completed = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func exit() {
        current -= 1
        completed += 1
    }
}

@Test func gateCapsConcurrencyAndCompletesAllWork() async throws {
    let gate = RequestGate()
    await gate.configure(limit: 3)
    let probe = GateProbe()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<20 {
            group.addTask {
                try await gate.withPermit {
                    await probe.enter()
                    try await Task.sleep(for: .milliseconds(20))
                    await probe.exit()
                }
            }
        }
        try await group.waitForAll()
    }

    #expect(await probe.peak == 3)  // saturated, never exceeded
    #expect(await probe.completed == 20)
}

@Test func gateWithoutLimitAdmitsEverythingAtOnce() async throws {
    let gate = RequestGate()  // never configured — unlimited
    let probe = GateProbe()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
            group.addTask {
                try await gate.withPermit {
                    await probe.enter()
                    try await Task.sleep(for: .milliseconds(50))
                    await probe.exit()
                }
            }
        }
        try await group.waitForAll()
    }

    #expect(await probe.peak == 10)
    #expect(await probe.completed == 10)
}

@Test func gateReleasesPermitWhenBodyThrows() async throws {
    struct Boom: Error {}
    let gate = RequestGate()
    await gate.configure(limit: 1)

    for _ in 0..<3 {
        _ = try? await gate.withPermit { throw Boom() }
    }
    // A leaked permit would deadlock this final acquisition.
    let survived = try await gate.withPermit { true }
    #expect(survived)
}

@Test func gateNonPositiveLimitMeansUnlimited() async throws {
    let gate = RequestGate()
    await gate.configure(limit: 0)
    let probe = GateProbe()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<5 {
            group.addTask {
                try await gate.withPermit {
                    await probe.enter()
                    try await Task.sleep(for: .milliseconds(30))
                    await probe.exit()
                }
            }
        }
        try await group.waitForAll()
    }

    #expect(await probe.peak == 5)
}
