import Foundation
import Testing

@testable import LogicProMCP

/// #993 -- the plug-in menu an empty insert slot opens, as ten languages of Logic 12.3 (6674) drew it.
///
/// Each list is the item titles read off a live menu on 2026-09-26 by
/// `Scripts/livekit/probe_993_1004_nbsp_labels_as_drawn.py`, in order, with the untitled first item
/// left out the way `findAudioPluginRootMenu` leaves out a title that will not read. Nine end in one
/// `Audio Units` item. zh_TW ends in one `音訊單元：<maker>` item per manufacturer and has no Audio
/// Units item at all, because Apple's zh_TW `Audio Units:` row carries a full-width colon that Logic
/// does not split on. Before this change `insert_plugin` could not recognise that menu.
@Suite("#993 the plug-in root menu is recognised in every language Logic ships")
struct Issue993PluginRootMenuTests {
    static let measured: [String: [String]] = [
        "en": ["Recent", "Compressor", "Channel EQ", "Gain", "Raum", "Tremolo", "", "Amps and Pedals", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging", "Metering", "Modulation", "Multi Effects", "Pitch", "Reverb", "Specialized", "Utility", "", "Audio Units", ""],
        "ko": ["최근 사용", "Compressor", "Channel EQ", "Gain", "Raum", "Tremolo", "", "Amps and Pedals", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging", "Metering", "Modulation", "Multi Effects", "Pitch", "Reverb", "Specialized", "Utility", "", "Audio Units", ""],
        "ja": ["最近使った項目", "Compressor", "Channel EQ", "Gain", "Raum", "Tremolo", "", "Amps and Pedals", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging", "Metering", "Modulation", "Multi Effects", "Pitch", "Reverb", "Specialized", "Utility", "", "Audio Units", ""],
        "de": ["Letzte", "Compressor", "Channel EQ", "Gain", "Raum", "Tremolo", "", "Amps and Pedals", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging", "Metering", "Modulation", "Multi Effects", "Pitch", "Reverb", "Specialized", "Utility", "", "Audio Units", ""],
        "es": ["Recientes", "Compressor", "Channel EQ", "Gain", "Raum", "Tremolo", "", "Amps and Pedals", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging", "Metering", "Modulation", "Multi Effects", "Pitch", "Reverb", "Specialized", "Utility", "", "Audio Units", ""],
        "fr": ["Récent", "Compressor", "Channel EQ", "Gain", "Raum", "Tremolo", "", "Amps and Pedals", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging", "Metering", "Modulation", "Multi Effects", "Pitch", "Reverb", "Specialized", "Utility", "", "Audio Units ", ""],
        "it": ["Recenti", "Compressor", "Channel EQ", "Gain", "Raum", "Tremolo", "", "Amps and Pedals", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging", "Metering", "Modulation", "Multi Effects", "Pitch", "Reverb", "Specialized", "Utility", "", "Audio Units", ""],
        "pt": ["Recentes", "Compressor", "Channel EQ", "Gain", "Raum", "Tremolo", "", "Amps and Pedals", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging", "Metering", "Modulation", "Multi Effects", "Pitch", "Reverb", "Specialized", "Utility", "", "Audio Units", ""],
        "zh_CN": ["最近项目", "Compressor", "Channel EQ", "Gain", "Raum", "Tremolo", "", "Amps and Pedals", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging", "Metering", "Modulation", "Multi Effects", "Pitch", "Reverb", "Specialized", "Utility", "", "音频单元", ""],
        "zh_TW": ["最近項目", "Compressor", "Channel EQ", "Gain", "Raum", "Tremolo", "", "Amps and Pedals", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging", "Metering", "Modulation", "Multi Effects", "Pitch", "Reverb", "Specialized", "Utility", "", "音訊單元：Apple", "音訊單元：iZotope", "音訊單元：Native Instruments", ""],
    ]

    @Test(
        "every measured menu is the plug-in root menu",
        arguments: ["en", "ko", "ja", "de", "es", "fr", "it", "pt", "zh_CN", "zh_TW"]
    )
    func everyMeasuredMenuIsRecognised(lproj: String) throws {
        let titles = try #require(Self.measured[lproj])
        #expect(AccessibilityChannel.isAudioPluginRootMenu(titles: titles))
    }

    @Test("zh_TW is recognised by its manufacturer items, not by an Audio Units item")
    func zhTWHasNoAudioUnitsItem() throws {
        let titles = try #require(Self.measured["zh_TW"])
        #expect(!titles.contains { AXLocalePolicy.pluginMenuAudioUnits.matches($0) })
        let makers = titles.filter {
            AXLocalePolicy.pluginMenuAudioUnitsManufacturerItem.matches($0, mode: .prefix)
        }
        #expect(makers == ["音訊單元：Apple", "音訊單元：iZotope", "音訊單元：Native Instruments"])
    }

    @Test("a manufacturer prefix does not make a menu the root without its other members")
    func prefixAloneIsNotTheRoot() {
        #expect(!AccessibilityChannel.isAudioPluginRootMenu(titles: ["音訊單元：Apple", "音訊單元：iZotope"]))
        #expect(!AccessibilityChannel.isAudioPluginRootMenu(titles: ["Utility", "音訊單元：Apple"]))
        #expect(!AccessibilityChannel.isAudioPluginRootMenu(titles: ["Channel EQ", "Utility", "Apple", "iZotope"]))
    }
}
