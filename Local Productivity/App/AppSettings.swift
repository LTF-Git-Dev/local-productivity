//
//  AppSettings.swift
//  Local Productivity
//
//  Preferences that apply across every workspace, stored in UserDefaults.
//

import SwiftUI

@Observable
final class AppSettings {

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "Automatic"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    enum EditorFont: String, CaseIterable, Identifiable {
        case standard, rounded, serif, mono
        /// An installed font family, named by `editorFontFamily`.
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard: return "Default"
            case .rounded: return "Rounded"
            case .serif: return "Serif"
            case .mono: return "Mono"
            case .custom: return "Other"
            }
        }

        var design: Font.Design {
            switch self {
            case .standard, .custom: return .default
            case .rounded: return .rounded
            case .serif: return .serif
            case .mono: return .monospaced
            }
        }
    }

    enum LineSpacing: String, CaseIterable, Identifiable {
        case compact, regular, relaxed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .compact: return "Compact"
            case .regular: return "Default"
            case .relaxed: return "Relaxed"
            }
        }

        /// Line height as a multiple of the text size.
        var multiplier: CGFloat {
            switch self {
            case .compact: return 1.35
            case .regular: return 1.55
            case .relaxed: return 1.8
            }
        }
    }

    enum PageWidth: String, CaseIterable, Identifiable {
        case narrow, regular, wide, full

        var id: String { rawValue }

        var title: String {
            switch self {
            case .narrow: return "Narrow"
            case .regular: return "Default"
            case .wide: return "Wide"
            case .full: return "Full"
            }
        }

        /// The widest the text column gets for `textSize`; nil fills the window. Larger text gets
        /// a proportionally wider column, so lines keep about the same number of words.
        func columnWidth(for textSize: CGFloat) -> CGFloat? {
            let base: CGFloat
            switch self {
            case .narrow: base = 600
            case .regular: base = Metrics.readingWidth
            case .wide: base = 920
            case .full: return nil
            }
            return (base * max(1, textSize / EditorTheme.defaultTextSize)).rounded()
        }
    }

    /// The size of LP's own text: the sidebar, lists, boards, Home and the calendar.
    enum InterfaceSize: String, CaseIterable, Identifiable {
        case small, regular, large

        var id: String { rawValue }

        var title: String {
            switch self {
            case .small: return "Small"
            case .regular: return "Default"
            case .large: return "Large"
            }
        }

        var scale: CGFloat {
            switch self {
            case .small: return 0.92
            case .regular: return 1
            case .large: return 1.1
            }
        }
    }

    var appearance: Appearance { didSet { store(appearance.rawValue, Keys.appearance) } }
    var editorFont: EditorFont { didSet { store(editorFont.rawValue, Keys.editorFont) } }
    /// The family used when `editorFont` is `.custom`.
    var editorFontFamily: String { didSet { store(editorFontFamily, Keys.editorFontFamily) } }
    /// Body text size in points, 12 to 24.
    var editorTextSize: CGFloat {
        didSet {
            let clamped = min(max(editorTextSize.rounded(), EditorTheme.textSizes.lowerBound), EditorTheme.textSizes.upperBound)
            if clamped != editorTextSize { editorTextSize = clamped }
            store(Double(editorTextSize), Keys.editorTextSize)
        }
    }
    var lineSpacing: LineSpacing { didSet { store(lineSpacing.rawValue, Keys.lineSpacing) } }
    var pageWidth: PageWidth { didSet { store(pageWidth.rawValue, Keys.pageWidth) } }
    var interfaceSize: InterfaceSize {
        didSet {
            store(interfaceSize.rawValue, Keys.interfaceSize)
            InterfaceScale.shared.value = interfaceSize.scale
        }
    }
    var checksSpelling: Bool { didSet { store(checksSpelling, Keys.spelling) } }
    /// Folder, relative to the workspace root, where new daily notes are created.
    var dailyNotesFolder: String { didSet { store(dailyNotesFolder, Keys.dailyFolder) } }

    // Reminders (Settings → Notifications).
    /// The switch for all of LP's reminders; on unless turned off (existing settings keep it on).
    var remindersEnabled: Bool { didSet { store(remindersEnabled, Keys.enabled); remindersChanged() } }
    var remindsDueItems: Bool { didSet { store(remindsDueItems, Keys.dueItems); remindersChanged() } }
    var dueReminderTime: TimeOfDay { didSet { store(dueReminderTime.minutes, Keys.dueTime); remindersChanged() } }
    var sendsDailySummary: Bool { didSet { store(sendsDailySummary, Keys.summary); remindersChanged() } }
    var summaryTime: TimeOfDay { didSet { store(summaryTime.minutes, Keys.summaryTime); remindersChanged() } }
    /// Minutes before an event to alert; nil turns event alerts off.
    var eventLeadMinutes: Int? { didSet { store(eventLeadMinutes ?? -1, Keys.eventLead); remindersChanged() } }
    var includesAppleCalendarEvents: Bool { didSet { store(includesAppleCalendarEvents, Keys.appleEvents); remindersChanged() } }

    var reminders: ReminderSettings {
        ReminderSettings(isEnabled: remindersEnabled, remindsDueItems: remindsDueItems, dueTime: dueReminderTime, sendsDailySummary: sendsDailySummary,
                         summaryTime: summaryTime, eventLeadMinutes: eventLeadMinutes,
                         includesAppleCalendarEvents: includesAppleCalendarEvents)
    }

    /// Called after any reminder setting changes.
    @ObservationIgnored var onRemindersChanged: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults?

    /// Pass `nil` to keep settings in memory only (used by previews and UI snapshots).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        appearance = defaults?.string(forKey: Keys.appearance).flatMap(Appearance.init) ?? .system
        editorFont = defaults?.string(forKey: Keys.editorFont).flatMap(EditorFont.init) ?? .standard
        editorFontFamily = defaults?.string(forKey: Keys.editorFontFamily) ?? ""
        if let size = defaults?.object(forKey: Keys.editorTextSize) as? Double {
            editorTextSize = min(max(CGFloat(size).rounded(), EditorTheme.textSizes.lowerBound), EditorTheme.textSizes.upperBound)
        } else {
            // Carried over from the three sizes of earlier versions.
            switch defaults?.string(forKey: Keys.legacyTextSize) {
            case "small": editorTextSize = 14
            case "large": editorTextSize = 18
            default: editorTextSize = EditorTheme.defaultTextSize
            }
        }
        lineSpacing = defaults?.string(forKey: Keys.lineSpacing).flatMap(LineSpacing.init) ?? .regular
        if let width = defaults?.string(forKey: Keys.pageWidth).flatMap(PageWidth.init) {
            pageWidth = width
        } else {
            pageWidth = defaults?.bool(forKey: Keys.legacyFullWidth) == true ? .full : .regular
        }
        interfaceSize = defaults?.string(forKey: Keys.interfaceSize).flatMap(InterfaceSize.init) ?? .regular
        checksSpelling = defaults?.object(forKey: Keys.spelling) as? Bool ?? true
        dailyNotesFolder = defaults?.string(forKey: Keys.dailyFolder) ?? "Daily Notes"

        let standard = ReminderSettings()
        remindersEnabled = defaults?.object(forKey: Keys.enabled) as? Bool ?? standard.isEnabled
        remindsDueItems = defaults?.object(forKey: Keys.dueItems) as? Bool ?? standard.remindsDueItems
        dueReminderTime = (defaults?.object(forKey: Keys.dueTime) as? Int).map(TimeOfDay.init(minutes:)) ?? standard.dueTime
        sendsDailySummary = defaults?.object(forKey: Keys.summary) as? Bool ?? standard.sendsDailySummary
        summaryTime = (defaults?.object(forKey: Keys.summaryTime) as? Int).map(TimeOfDay.init(minutes:)) ?? standard.summaryTime
        if let lead = defaults?.object(forKey: Keys.eventLead) as? Int {
            eventLeadMinutes = lead < 0 ? nil : lead
        } else {
            eventLeadMinutes = standard.eventLeadMinutes
        }
        includesAppleCalendarEvents = defaults?.object(forKey: Keys.appleEvents) as? Bool ?? standard.includesAppleCalendarEvents

        InterfaceScale.shared.value = interfaceSize.scale
    }

    private func remindersChanged() {
        onRemindersChanged?()
    }

    // MARK: Text

    /// The editor's typeface, from the font setting.
    var editorTypeface: EditorTheme.Typeface {
        switch editorFont {
        case .standard: return .standard
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .mono
        case .custom: return editorFontFamily.isEmpty ? .standard : .family(editorFontFamily)
        }
    }

    /// The editor's look, from the text settings.
    var editorTheme: EditorTheme {
        var theme = EditorTheme()
        theme.typeface = editorTypeface
        theme.textSize = editorTextSize
        theme.lineSpacing = lineSpacing.multiplier
        return theme
    }

    /// A font for text that sits with the page (its title), in the editor's typeface.
    func pageFont(size: CGFloat, weight: Font.Weight) -> Font {
        if editorFont == .custom, !editorFontFamily.isEmpty {
            return Font.custom(editorFontFamily, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: editorFont.design)
    }

    func makeTextBigger() { editorTextSize = min(editorTextSize + 1, EditorTheme.textSizes.upperBound) }
    func makeTextSmaller() { editorTextSize = max(editorTextSize - 1, EditorTheme.textSizes.lowerBound) }
    func resetTextSize() { editorTextSize = EditorTheme.defaultTextSize }

    private func store(_ value: Any, _ key: String) {
        defaults?.set(value, forKey: key)
    }

    private enum Keys {
        static let appearance = "settings.appearance"
        static let editorFont = "settings.editorFont"
        static let editorFontFamily = "settings.editorFontFamily"
        static let editorTextSize = "settings.editorTextSize"
        static let lineSpacing = "settings.lineSpacing"
        static let pageWidth = "settings.pageWidth"
        static let interfaceSize = "settings.interfaceSize"
        /// Settings of earlier versions, read once to carry them over.
        static let legacyTextSize = "settings.textSize"
        static let legacyFullWidth = "settings.fullWidth"
        static let spelling = "settings.spelling"
        static let dailyFolder = "settings.dailyNotesFolder"
        static let enabled = "reminders.enabled"
        static let dueItems = "reminders.dueItems"
        static let dueTime = "reminders.dueTime"
        static let summary = "reminders.summary"
        static let summaryTime = "reminders.summaryTime"
        static let eventLead = "reminders.eventLead"
        static let appleEvents = "reminders.appleEvents"
    }
}
