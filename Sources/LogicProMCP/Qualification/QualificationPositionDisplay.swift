import Foundation

/// How a mutation-allowed qualification cycle reads and changes Logic's playhead display.
///
/// Four position components (bar, beat, division, tick) are shown only in the control bar's
/// Beats display mode; Logic's default, Beats & Project, shows bar and beat, which cannot name an
/// exact origin to put the playhead back to. The marker and bar restore cycles therefore switch
/// to Beats for the whole cycle and give the mode back afterwards
/// (`QualificationTransport.withBeatsPositionDisplay`); the transport cycles switch only for the
/// exact position reads, because Beats does not show the tempo their requests need
/// (`QualificationTransport.withPositionDisplay`).
///
/// A seam, not a global: a transport built without one leaves the display alone, which is what
/// every unit test of the transport itself wants. The live `--qualify` drive supplies
/// `production`.
struct QualificationPositionDisplay: Sendable {
    /// The popup's current mode title, or nil when it cannot be read.
    let read: @Sendable () -> String?
    /// The mode the popup's menu has checked, observed without selecting anything, or nil when it
    /// cannot be read in full. The popup's title and the checked item are two readings of one
    /// setting; a cycle starts only when they agree (`withBeatsPositionDisplay`).
    let readChecked: @Sendable () -> String?
    /// Selects Beats. See `ControlBarDisplayMode.Switch` for what each answer obliges the caller to do.
    let selectBeats: @Sendable () -> ControlBarDisplayMode.Switch
    /// Puts back the mode a switch found, while the lease still holds.
    let restore: @Sendable (ControlBarDisplayMode.Lease) -> ControlBarDisplayMode.Restore
    /// True only for the seam the shipped `--qualify` drive supplies, so a test can say the drive
    /// is wired to it without driving Logic.
    let isProduction: Bool

    init(
        read: @escaping @Sendable () -> String?,
        readChecked: @escaping @Sendable () -> String?,
        selectBeats: @escaping @Sendable () -> ControlBarDisplayMode.Switch,
        restore: @escaping @Sendable (ControlBarDisplayMode.Lease) -> ControlBarDisplayMode.Restore,
        isProduction: Bool = false
    ) {
        self.read = read
        self.readChecked = readChecked
        self.selectBeats = selectBeats
        self.restore = restore
        self.isProduction = isProduction
    }

    static let production = QualificationPositionDisplay(
        read: { ControlBarDisplayMode.currentMode() },
        readChecked: { ControlBarDisplayMode.checkedMode() },
        selectBeats: { ControlBarDisplayMode.selectBeats() },
        restore: { ControlBarDisplayMode.restore($0) },
        isProduction: true)
}
