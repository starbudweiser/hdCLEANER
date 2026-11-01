import Foundation

/// Tailles affichées en puissances de 1000, comme le Finder.
public enum SizeFormat {
    public static func text(_ bytes: Int64) -> String {
        let b = Double(max(bytes, 0))
        func decimal(_ v: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", locale: .current, v) }
        if b >= 1e12 { return L("unit.tb", decimal(b / 1e12, 2)) }
        if b >= 1e9 { return L("unit.gb", decimal(b / 1e9, 2)) }
        if b >= 1e6 { return L("unit.mb", decimal(b / 1e6, 1)) }
        return L("unit.kb", decimal(b / 1e3, 0))
    }
}
