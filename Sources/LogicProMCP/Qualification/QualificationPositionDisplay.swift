import Foundation

/// How a mutation-allowed qualification cycle reads and changes Logic's playhead display.
///
/// Four position components (bar, beat, division, tick) are shown only in the control bar's
/// Beats display mode; Logic's default, Beats & Project, shows bar and beat, which cannot name an
/// exact origin to put the playhead back to. The transport, marker and bar restore cycles
/// therefore switch to Beats for their reads and give the mode back afterwards
/// (`QualificationTransport.withBeatsPositionDisplay`).
///
/// A seam, not a global: a transport built without one leaves the display alone, which is what
/// every unit test of the transport itself wants. The live `--qualify` drive supplies
/// `production`.
struct QualificationPositionDisplay: Sendable {
    /// The popup's current mode title, or nil when it cannot be read.
    let read: @Sendable () -> String?
    /// Selects Beats. See `ControlBarDisplayMode.Switch` for what each answer obliges the caller to do.
    let selectBeats: @Sendable () -> ControlBarDisplayMode.Switch
    /// Puts back the mode a switch found, while the lease still holds.
    let restore: @Sendable (ControlBarDisplayMode.Lease) -> ControlBarDisplayMode.Restore

    static let production = QualificationPositionDisplay(
        read: { ControlBarDisplayMode.currentMode() },
        selectBeats: { ControlBarDisplayMode.selectBeats() },
        restore: { ControlBarDisplayMode.restore($0) })
}
