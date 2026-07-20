import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Test func issue253AudioAndPluginsHelpReturnCategoryDocs() async throws {
    for category in ["audio", "plugins"] {
        let result = await SystemDispatcher.handle(
            command: "help",
            params: ["category": .string(category)],
            router: ChannelRouter(),
            cache: StateCache()
        )

        let v1 = try #require(result.isError)
        #expect(!v1)
        #expect(sharedToolText(result).contains("logic_\(category) commands"))
    }
}

@Test func issue253UnknownCategoryListsAudioAndPluginsAsValid() async throws {
    let result = await SystemDispatcher.handle(
        command: "help",
        params: ["category": .string("bogus")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(sharedToolText(result).utf8))
            as? [String: Any]
    )
    let validCategories = try #require(object["valid_categories"] as? [String])

    #expect(validCategories.contains("audio"))
    #expect(validCategories.contains("plugins"))
}

@Test func issue253SystemHelpFooterListsEveryToolCategory() async {
    let result = await SystemDispatcher.handle(
        command: "help",
        params: ["category": .string("system")],
        router: ChannelRouter(),
        cache: StateCache()
    )

    #expect(sharedToolText(result).contains(
        "Categories: transport, tracks, mixer, midi, edit, navigate, project, audio, plugins, system"
    ))
}

@Test func navigateHelpDoesNotExposeMarkerImplementationMetadata() async {
    let result = await SystemDispatcher.handle(
        command: "help",
        params: ["category": .string("navigate")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    let text = sharedToolText(result)

    #expect(!text.contains("AX"))
    #expect(!text.localizedCaseInsensitiveContains("accessibility"))
}

@Test func tracksHelpDoesNotExposeAutomationImplementationMetadata() async {
    let result = await SystemDispatcher.handle(
        command: "help",
        params: ["category": .string("tracks")],
        router: ChannelRouter(),
        cache: StateCache()
    )
    let text = sharedToolText(result)

    #expect(!text.contains("MCU write + AX track-header readback"))
}
