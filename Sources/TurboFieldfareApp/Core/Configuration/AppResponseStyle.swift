public enum AppResponseStyle: String, CaseIterable, Identifiable, Sendable {
    case precise
    case balanced
    case creative
    case custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .precise: "Precise"
        case .balanced: "Balanced"
        case .creative: "Creative"
        case .custom: "Custom"
        }
    }

    public var detail: String {
        switch self {
        case .precise: "Deterministic output for repeatable answers"
        case .balanced: "Steady answers with a small amount of variation"
        case .creative: "More varied wording and alternatives"
        case .custom: "Uses the advanced sampling controls below"
        }
    }

    public static func resolve(
        temperature: Double,
        topKEnabled: Bool,
        topK: Int,
        topPEnabled: Bool,
        topP: Double
    ) -> Self {
        if temperature == 0, !topKEnabled, !topPEnabled { return .precise }
        if approximatelyEqual(temperature, 0.2), topKEnabled, topK == 64,
           topPEnabled, approximatelyEqual(topP, 0.95) {
            return .balanced
        }
        if approximatelyEqual(temperature, 0.8), topKEnabled, topK == 64,
           topPEnabled, approximatelyEqual(topP, 0.95) {
            return .creative
        }
        return .custom
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.000_1
    }
}
