import SwiftUI

// MARK: - Device Presets

struct DevicePreset: Identifiable {
    let id = UUID()
    let name: String
    let width: Int
    let height: Int
    let category: PresetCategory
    var dimensionString: String { "\(width) x \(height)" }

    enum PresetCategory: String, CaseIterable {
        case iphone = "iPhone"
        case ipad = "iPad"
        case mac = "Mac"
        case tv = "tv"

        func localizedName(_ locale: LocaleManager) -> String {
            switch self {
            case .iphone: return "iPhone"
            case .ipad: return "iPad"
            case .mac: return "Mac"
            case .tv: return locale.t("preset_tv")
            }
        }
    }
}

let devicePresets: [DevicePreset] = [
    .init(name: "iPhone 16 Pro Max", width: 1320, height: 2868, category: .iphone),
    .init(name: "iPhone 16 Pro", width: 1206, height: 2622, category: .iphone),
    .init(name: "iPhone 16", width: 1179, height: 2556, category: .iphone),
    .init(name: "iPhone SE", width: 750, height: 1334, category: .iphone),
    .init(name: "iPhone 15 Pro Max", width: 1290, height: 2796, category: .iphone),
    .init(name: "iPhone 15 Pro", width: 1179, height: 2556, category: .iphone),
    .init(name: "iPad Pro 13\"", width: 2752, height: 2064, category: .ipad),
    .init(name: "iPad Pro 11\"", width: 2420, height: 1668, category: .ipad),
    .init(name: "iPad Air 13\"", width: 2732, height: 2048, category: .ipad),
    .init(name: "iPad Air 11\"", width: 2360, height: 1640, category: .ipad),
    .init(name: "iPad mini", width: 2266, height: 1488, category: .ipad),
    .init(name: "iPad 10th gen", width: 2360, height: 1640, category: .ipad),
    .init(name: "MacBook Air 15\"", width: 2880, height: 1864, category: .mac),
    .init(name: "MacBook Air 13\"", width: 2560, height: 1664, category: .mac),
    .init(name: "MacBook Pro 16\"", width: 3456, height: 2234, category: .mac),
    .init(name: "MacBook Pro 14\"", width: 3024, height: 1964, category: .mac),
    .init(name: "iMac 24\"", width: 4480, height: 2520, category: .mac),
    .init(name: "Studio Display", width: 5120, height: 2880, category: .mac),
    .init(name: "Pro Display XDR", width: 6016, height: 3384, category: .mac),
    .init(name: "1080p Full HD", width: 1920, height: 1080, category: .tv),
    .init(name: "1440p QHD", width: 2560, height: 1440, category: .tv),
    .init(name: "4K UHD", width: 3840, height: 2160, category: .tv),
    .init(name: "5K", width: 5120, height: 2880, category: .tv),
    .init(name: "Ultrawide 3440x1440", width: 3440, height: 1440, category: .tv),
    .init(name: "Apple TV 4K", width: 3840, height: 2160, category: .tv),
]
