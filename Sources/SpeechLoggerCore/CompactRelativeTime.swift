import Foundation

/// A terse, pt-BR "how long ago" stamp for a panel row's right edge: `agora`,
/// `N min`, `N h`, `N d`. Deliberately coarse — the panel wants a glanceable age,
/// not a precise duration (SPEC "UI", story 23).
public enum CompactRelativeTime {
    public static func text(from date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        guard seconds >= 60 else { return "agora" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h" }
        return "\(hours / 24) d"
    }
}
