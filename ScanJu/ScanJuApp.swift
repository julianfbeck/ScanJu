import SwiftUI

@main
struct ScanJuApp: App {
    var body: some Scene {
        WindowGroup { LibraryView().tint(Palette.ink).preferredColorScheme(.light) }
    }
}

enum Palette {
    static let paper = Color(red: 0.95, green: 0.96, blue: 0.93)
    static let ink = Color(red: 0.07, green: 0.17, blue: 0.15)
    static let mint = Color(red: 0.64, green: 0.95, blue: 0.78)
    static let secondary = Color(red: 0.40, green: 0.46, blue: 0.42)
}
