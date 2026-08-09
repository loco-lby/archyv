import SwiftData

/// CLOUDKIT READINESS (D1): the current on-disk shape, wrapped as an
/// explicit `VersionedSchema` rather than the previous flat, unversioned
/// `Schema([...])`. This is schema-shape prep only — CloudKit itself is
/// NOT enabled by introducing this type.
///
/// This wraps the schema AFTER this milestone's changes (no `.unique`
/// attributes, `StoredItem.imageData` present) directly as version 1,
/// rather than adding a second `ArkyvSchemaV2` snapshot of the "before"
/// shape and an explicit `MigrationStage`. SwiftData's own lightweight
/// migration detection (structural diffing against whatever store file is
/// already on disk) is relied on to carry existing local data forward —
/// nothing here declares a custom migration stage. No data model version
/// has ever shipped to a user before this branch, so there is no prior
/// on-disk shape that needs a real migration path yet.
enum ArkyvSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [StoredFolder.self, StoredItem.self, StoredFolderMembership.self]
    }
}

/// Single-stage migration plan — see `ArkyvSchemaV1`'s doc comment for why
/// `stages` is empty rather than containing an explicit lightweight- or
/// custom-migration stage.
enum ArkyvMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ArkyvSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
