import Foundation
import SwiftData
import Testing
@testable import TallyKit

/// Gate 0's CloudKit-safety audit (PLAN Wave 0, SPEC §1).
///
/// Sync ships in Wave 2, but the schema has to be legal from day one or the flip
/// becomes a migration. These tests are the thing that keeps a later agent from
/// adding a `@Attribute(.unique)` or a non-optional column and only finding out
/// at Gate 2.
@Suite("CloudKit safety")
struct CloudKitSafetyTests {

    private var schema: Schema { TallyStore.makeSchema() }

    @Test("Every model is in the schema")
    func schemaCoversEveryModel() {
        let names = Set(schema.entities.map(\.name))
        #expect(names == ["DrinkEvent", "Venue", "Session", "SuppressedPlace"])
        #expect(TallyStore.models.count == 4)
    }

    @Test("No uniqueness constraints anywhere — CloudKit does not support them")
    func noUniquenessConstraints() {
        for entity in schema.entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name) declares a uniqueness constraint")
            for attribute in entity.attributes {
                #expect(attribute.isUnique == false, "\(entity.name).\(attribute.name) is unique")
            }
        }
    }

    @Test("Every attribute is optional or has a default")
    func everyAttributeIsOptionalOrDefaulted() {
        for entity in schema.entities {
            for attribute in entity.attributes {
                #expect(
                    attribute.isOptional || attribute.defaultValue != nil,
                    "\(entity.name).\(attribute.name) is required with no default"
                )
            }
        }
    }

    @Test("Every relationship is optional and has an explicit inverse")
    func everyRelationshipIsOptionalWithAnInverse() {
        for entity in schema.entities {
            for relationship in entity.relationships {
                #expect(relationship.isOptional, "\(entity.name).\(relationship.name) is not optional")
                #expect(
                    relationship.inverseName != nil,
                    "\(entity.name).\(relationship.name) has no inverse"
                )
            }
        }
    }

    @Test("Every model can be created with no arguments")
    func everyModelHasAUsableDefaultInit() {
        // If this compiles and runs, every property carries a default — the same
        // property CloudKit needs when it materializes a record it has never seen.
        _ = DrinkEvent()
        _ = Venue()
        _ = Session()
        _ = SuppressedPlace()
    }

    @Test("Enums are stored as raw-value strings with defaults")
    func enumsAreStoredAsStrings() {
        let event = DrinkEvent()
        #expect(event.typeRaw == DrinkType.alcoholic.rawValue)
        #expect(event.sourceRaw == EventSource.app.rawValue)

        let venue = Venue()
        #expect(venue.categoryRaw == VenueCategory.other.rawValue)
        #expect(venue.sourceRaw == VenueSource.userDefined.rawValue)

        // The raw columns are what SwiftData sees; the enums are computed.
        let eventAttributes = Set(
            schema.entities.first { $0.name == "DrinkEvent" }?.attributes.map(\.name) ?? []
        )
        #expect(eventAttributes.contains("typeRaw"))
        #expect(eventAttributes.contains("sourceRaw"))
        #expect(!eventAttributes.contains("type"))
        #expect(!eventAttributes.contains("source"))
    }

    @Test("An unknown raw value degrades instead of crashing")
    func unknownRawValuesDegradeGracefully() {
        // A newer device writing an enum case this build has never heard of must
        // not take the app down after a sync.
        let event = DrinkEvent()
        event.typeRaw = "quantumBeer"
        #expect(event.type == .alcoholic)

        let venue = Venue()
        venue.categoryRaw = "spaceStation"
        #expect(venue.category == .other)
    }

    @Test("The sync switch is off, and the private-database container is named")
    func cloudKitIsOffButWired() {
        // Wave 2 flips exactly this one value (SPEC §8).
        #expect(TallyStore.cloudKitMode == .disabled)
        #expect(TallyStore.cloudKitContainerIdentifier.hasPrefix("iCloud."))
        #expect(
            CloudKitMode.privateDatabase(containerIdentifier: TallyStore.cloudKitContainerIdentifier).isEnabled
        )
    }

    @Test("The App Group id derives from the app bundle id")
    func appGroupIdentifier() {
        #expect(TallyStore.appGroupIdentifier == "group.devplaceholder.B13UVL67.tally")
        #expect(StoreConfiguration.default.appGroupIdentifier == TallyStore.appGroupIdentifier)
        #expect(StoreConfiguration.local.appGroupIdentifier == nil)
        #expect(StoreConfiguration.inMemory.isStoredInMemoryOnly)
    }

    @Test("An in-memory container builds from the shared schema")
    func inMemoryContainerBuilds() throws {
        let container = try TallyStore.makeInMemoryContainer()
        #expect(container.schema.entities.count == 4)
    }
}
