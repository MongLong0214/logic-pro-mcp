import Darwin
import Foundation
import Testing
@testable import LogicProMCP

private func bindingRecordStoreURL(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("midi-key-command-records-\(tag)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("midi-key-commands.json")
}

private var metronomeBindingEntry: MIDIKeyCommandBindingCatalog.Entry {
    MIDIKeyCommandBindingCatalog.entries[0]
}

@Test func midiKeyCommandBindingRecordStoreStartsEmpty() async {
    let store = MIDIKeyCommandBindingRecordStore(fileURL: bindingRecordStoreURL("empty"))

    let records = await store.matchingRecords(
        portName: "LogicProMCP-KeyCmd-Internal",
        channel: 16
    )

    #expect(records.isEmpty)
}

@Test func midiKeyCommandBindingRecordStoreReturnsOnlyExactCurrentIdentity() async throws {
    let store = MIDIKeyCommandBindingRecordStore(fileURL: bindingRecordStoreURL("identity"))
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    try await store.replaceVerified(
        entries: [metronomeBindingEntry],
        portName: "LogicProMCP-KeyCmd-Internal",
        observedAt: observedAt
    )

    let records = await store.matchingRecords(
        portName: "LogicProMCP-KeyCmd-Internal",
        channel: 16
    )

    #expect(records == [MIDIKeyCommandBindingRecord(
        operation: "transport.toggle_metronome",
        portName: "LogicProMCP-KeyCmd-Internal",
        channel: 16,
        cc: 98,
        value: 127,
        observedAt: observedAt
    )])
    #expect((await store.matchingRecords(portName: "Other-Port", channel: 16)).isEmpty)
    #expect((await store.matchingRecords(
        portName: "LogicProMCP-KeyCmd-Internal",
        channel: 15
    )).isEmpty)
}

@Test func midiKeyCommandBindingRecordStoreDropsCatalogDrift() async throws {
    let store = MIDIKeyCommandBindingRecordStore(fileURL: bindingRecordStoreURL("drift"))
    try await store.replaceVerified(
        entries: [metronomeBindingEntry],
        portName: "LogicProMCP-KeyCmd-Internal"
    )
    let changedCatalog = [MIDIKeyCommandBindingCatalog.Entry(
        operation: metronomeBindingEntry.operation,
        commandName: metronomeBindingEntry.commandName,
        cc: 99,
        channel: metronomeBindingEntry.channel,
        value: 126
    )]

    let records = await store.matchingRecords(
        portName: "LogicProMCP-KeyCmd-Internal",
        channel: 16,
        catalog: changedCatalog
    )

    #expect(records.isEmpty)
}

@Test func midiKeyCommandBindingRecordStoreRefusesNonCatalogAndDuplicateEntries() async {
    let store = MIDIKeyCommandBindingRecordStore(fileURL: bindingRecordStoreURL("invalid"))
    let nonCatalog = MIDIKeyCommandBindingCatalog.Entry(
        operation: "transport.toggle_count_in",
        commandName: "Toggle Count-in",
        cc: 99,
        channel: 16,
        value: 127
    )

    await #expect(throws: MIDIKeyCommandBindingRecordStoreError.nonCatalogEntry(
        "transport.toggle_count_in"
    )) {
        try await store.replaceVerified(
            entries: [nonCatalog],
            portName: "LogicProMCP-KeyCmd-Internal"
        )
    }
    await #expect(throws: MIDIKeyCommandBindingRecordStoreError.duplicateOperation(
        "transport.toggle_metronome"
    )) {
        try await store.replaceVerified(
            entries: [metronomeBindingEntry, metronomeBindingEntry],
            portName: "LogicProMCP-KeyCmd-Internal"
        )
    }
    for invalidPortName in ["", "LogicProMCP\0KeyCmd"] {
        await #expect(throws: MIDIKeyCommandBindingRecordStoreError.invalidPortName) {
            try await store.replaceVerified(
                entries: [metronomeBindingEntry],
                portName: invalidPortName
            )
        }
    }
}

@Test func midiKeyCommandBindingRecordStoreRefusesToOverwriteCorruptBytes() async throws {
    let fileURL = bindingRecordStoreURL("corrupt")
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let original = Data("not-json".utf8)
    try original.write(to: fileURL)
    let store = MIDIKeyCommandBindingRecordStore(fileURL: fileURL)

    #expect((await store.matchingRecords(
        portName: "LogicProMCP-KeyCmd-Internal",
        channel: 16
    )).isEmpty)
    await #expect(throws: (any Error).self) {
        try await store.replaceVerified(
            entries: [metronomeBindingEntry],
            portName: "LogicProMCP-KeyCmd-Internal"
        )
    }
    #expect(try Data(contentsOf: fileURL) == original)
}

@Test func midiKeyCommandBindingRecordStoreRefusesUnsupportedSchema() async throws {
    let fileURL = bindingRecordStoreURL("schema")
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let original = Data(#"{"schema":2,"records":[]}"#.utf8)
    try original.write(to: fileURL)
    let store = MIDIKeyCommandBindingRecordStore(fileURL: fileURL)

    #expect((await store.matchingRecords(
        portName: "LogicProMCP-KeyCmd-Internal",
        channel: 16
    )).isEmpty)
    await #expect(throws: MIDIKeyCommandBindingRecordStoreError.unsupportedSchema(2)) {
        try await store.replaceVerified(
            entries: [metronomeBindingEntry],
            portName: "LogicProMCP-KeyCmd-Internal"
        )
    }
    #expect(try Data(contentsOf: fileURL) == original)
}

@Test func midiKeyCommandBindingRecordStoreReplacesTheCompleteObservedSet() async throws {
    let store = MIDIKeyCommandBindingRecordStore(fileURL: bindingRecordStoreURL("replace"))
    try await store.replaceVerified(
        entries: [metronomeBindingEntry],
        portName: "LogicProMCP-KeyCmd-Internal"
    )
    try await store.replaceVerified(
        entries: [],
        portName: "LogicProMCP-KeyCmd-Internal"
    )

    #expect((await store.matchingRecords(
        portName: "LogicProMCP-KeyCmd-Internal",
        channel: 16
    )).isEmpty)
}

@Test func midiKeyCommandBindingRecordStoreWritesOwnerOnlyPermissions() async throws {
    let fileURL = bindingRecordStoreURL("permissions")
    let store = MIDIKeyCommandBindingRecordStore(fileURL: fileURL)
    try await store.replaceVerified(
        entries: [metronomeBindingEntry],
        portName: "LogicProMCP-KeyCmd-Internal"
    )

    let directoryMode = try #require(
        FileManager.default.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber
    ).intValue & 0o777
    let fileMode = try #require(
        FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
    ).intValue & 0o777

    #expect(directoryMode == 0o700)
    #expect(fileMode == 0o600)
}
