import Foundation
import MCP
import Testing
@testable import LogicProMCP

@Test func issue253AudioAndPluginsHelpReturnCategoryDocs() async {
    for category in ["audio", "plugins"] {
        let result = await SystemDispatcher.handle(
            command: "help",
            params: ["category": .string(category)],
            router: ChannelRouter(),
            cache: StateCache()
        )

        #expect(result.isError == false)
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
