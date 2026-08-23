import Foundation
import Testing
@testable import TallyKit

/// SPEC §4 "Recovery context": the model is pure and deterministic, so every
/// property worth promising is directly testable.
@Suite("Fibrinolysis model")
struct FibrinolysisModelTests {

    private let model = FibrinolysisModel()
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func drink(_ offset: TimeInterval, type: DrinkType = .alcoholic) -> DrinkEventSnapshot {
        DrinkEventSnapshot(
            id: UUID(), type: type, timestamp: t0.addingTimeInterval(offset),
            latitude: nil, longitude: nil, horizontalAccuracy: nil,
            source: .app, venueID: nil
        )
    }

    @Test("No drinks means baseline, everywhere")
    func emptyIsZero() {
        #expect(model.suppressionIndex(at: t0, events: []) == 0)
        #expect(model.baselineReturn(after: t0, events: []) == nil)
        #expect(model.projectedPeak(after: t0, events: []) == nil)
    }

    @Test("Non-alcoholic drinks contribute nothing")
    func naIsInert() {
        let events = [drink(0, type: .nonAlcoholic), drink(600, type: .nonAlcoholic)]
        #expect(model.suppressionIndex(at: t0.addingTimeInterval(4 * 3600), events: events) == 0)
    }

    @Test("Nothing before absorption onset")
    func onsetGate() {
        let events = [drink(0)]
        #expect(model.suppressionIndex(at: t0.addingTimeInterval(30 * 60), events: events) == 0)
        #expect(model.suppressionIndex(at: t0.addingTimeInterval(46 * 60), events: events) > 0)
    }

    @Test("A single drink peaks at the configured delay, at the unit pulse")
    func singlePulsePeak() {
        let events = [drink(0)]
        let atPeak = model.suppressionIndex(at: t0.addingTimeInterval(4 * 3600), events: events)
        #expect(abs(atPeak - model.configuration.unitPulse) < 0.01)
        // Rising before, falling after.
        #expect(model.suppressionIndex(at: t0.addingTimeInterval(2 * 3600), events: events) < atPeak)
        #expect(model.suppressionIndex(at: t0.addingTimeInterval(6 * 3600), events: events) < atPeak)
    }

    @Test("Decay halves per half-life")
    func decayHalfLife() {
        let events = [drink(0)]
        let atPeak = model.suppressionIndex(at: t0.addingTimeInterval(4 * 3600), events: events)
        let oneHalfLifeLater = model.suppressionIndex(at: t0.addingTimeInterval(12 * 3600), events: events)
        #expect(abs(oneHalfLifeLater - atPeak / 2) < 0.01)
    }

    @Test("The lag is real: suppression outlives the drinking")
    func morningAfter() {
        // Last drink at midnight-equivalent; eight hours later the index is
        // still elevated — the whole reason the model exists.
        let events = [drink(0), drink(3600), drink(2 * 3600)]
        let eightHoursAfterLast = model.suppressionIndex(at: t0.addingTimeInterval(10 * 3600), events: events)
        #expect(eightHoursAfterLast > model.configuration.baselineThreshold)
    }

    @Test("Compressed drinks compound superlinearly")
    func compressionSuperlinearity() {
        // Three drinks inside 90 minutes vs the same three spread over 7.5 h.
        let compressed = [drink(0), drink(45 * 60), drink(90 * 60)]
        let paced = [drink(0), drink(3.75 * 3600), drink(7.5 * 3600)]
        let peakCompressed = model.projectedPeak(after: t0, events: compressed)?.index ?? 0
        let peakPaced = model.projectedPeak(after: t0, events: paced)?.index ?? 0
        #expect(peakCompressed > peakPaced)
        // And more than linear: the compressed peak exceeds 3 unit pulses.
        #expect(peakCompressed > 3 * model.configuration.unitPulse)
    }

    @Test("The index saturates at the ceiling")
    func ceiling() {
        let bender = (0..<40).map { drink(TimeInterval($0) * 600) }
        let worst = model.projectedPeak(after: t0, events: bender)?.index ?? 0
        #expect(worst <= model.configuration.ceiling)
    }

    @Test("Baseline return lands after the last pulse decays, and respects re-rises")
    func baselineReturn() {
        let events = [drink(0)]
        let back = model.baselineReturn(after: t0.addingTimeInterval(4 * 3600), events: events)
        #expect(back != nil)
        if let back {
            #expect(model.suppressionIndex(at: back, events: events) <= model.configuration.baselineThreshold)
            #expect(back > t0.addingTimeInterval(4 * 3600))
        }

        // A second drink hours later pushes the boundary out past its pulse too.
        let twoNights = [drink(0), drink(6 * 3600)]
        let back2 = model.baselineReturn(after: t0.addingTimeInterval(4 * 3600), events: twoNights)
        if let back, let back2 { #expect(back2 > back) }
    }

    @Test("Curve sampling brackets the index function")
    func curveConsistency() {
        let events = [drink(0), drink(3600)]
        let samples = model.curve(from: t0, to: t0.addingTimeInterval(12 * 3600), events: events)
        #expect(!samples.isEmpty)
        for sample in samples where abs(sample.index - model.suppressionIndex(at: sample.date, events: events)) > 0.001 {
            Issue.record("curve diverges from index at \(sample.date)")
        }
    }

    // MARK: Classification

    private func session(offsets: [TimeInterval]) -> DerivedSession {
        let events = offsets.map { drink($0) }
        let deriver = SessionDeriver()
        let derived = deriver.derive(events: events.map { $0 }, materialized: [], venueExits: [])
        precondition(derived.count == 1, "fixture should form one Session")
        return derived[0]
    }

    @Test("One drink per 90 minutes classifies paced")
    func pacedClass() {
        let s = session(offsets: [0, 2 * 3600, 4 * 3600].map(TimeInterval.init))
        #expect(FibrinolysisModel().classify(s) == .paced)
    }

    @Test("Two to three in 90 minutes classifies elevated")
    func elevatedClass() {
        let s = session(offsets: [0, 3600, 2.2 * 3600])
        #expect(FibrinolysisModel().classify(s) == .elevated)
    }

    @Test("Four or more in 90 minutes classifies compressed")
    func compressedClass() {
        let s = session(offsets: [0, 20 * 60, 40 * 60, 60 * 60])
        #expect(FibrinolysisModel().classify(s) == .compressed)
    }
}
