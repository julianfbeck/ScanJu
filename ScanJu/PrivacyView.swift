import SwiftUI

struct PrivacyView: View {
    var body: some View {
        List {
            Section("Your scans stay with you") {
                Text("ScanJu captures camera images, depth maps, camera calibration, point clouds, meshes, and available room measurements. It processes and stores these on your device. ScanJu has no account, advertising, analytics service, or developer-operated cloud storage, and does not upload your scans to us.")
                Text("Images and scans may contain people, belongings, and details of your home. Choose carefully what you capture and share.")
            }
            Section("Camera and TrueDepth") {
                Text("Camera access is used for scanning and textures. LiDAR provides rear depth data on supported devices. Close-up uses the front TrueDepth camera for object depth and color, with the rear camera assisting world tracking. ScanJu does not use Face ID authentication, create biometric identity templates, or record face landmarks or expressions.")
            }
            Section("Export, backups, and deletion") {
                Text("You choose when to export through the system share sheet or Files. Export packages include camera images and raw capture data as well as the processed model. The apps and services you choose to share with handle those copies under their own policies.")
                Text("Your device backup settings may include ScanJu's local files. Use Delete all scans on the home screen to remove captures and interrupted recordings from this installation. Copies you exported or backed up must be managed separately.")
            }
            Section("TestFlight and feedback") {
                Text("When you install a beta with TestFlight, Apple may share crash reports, usage information, and feedback with the developer under TestFlight's terms. ScanJu does not add a separate analytics SDK. Submit beta feedback through TestFlight; include a scan only if you choose to share it.")
                Link("Contact: eyevo@julianbeck.com", destination: URL(string: "mailto:eyevo@julianbeck.com")!)
                Text("Privacy information updated October 18, 2026.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy and contact")
        .navigationBarTitleDisplayMode(.inline)
    }
}
