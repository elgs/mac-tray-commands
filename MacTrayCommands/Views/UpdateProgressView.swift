import SwiftUI

/// The window shown while an update is downloading or installing: which
/// version, how far along, and a Cancel button that works during the
/// download. The menu closes on the click that starts an update, so without
/// this nothing visible would happen until the relaunch. AppDelegate opens
/// and closes the window from the updater's state.
struct UpdateProgressView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updating Mac Tray Commands to \(updater.updateAvailable?.version ?? "the new version")")
                .font(.headline)
            switch updater.updateState {
            case .downloading(let fraction):
                // Determinate from the first frame: a bar that starts
                // indeterminate and snaps to 3% reads as a stall.
                ProgressView(value: fraction)
                Text("Downloading… \(Int((fraction * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .installing:
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Verifying and installing… the app relaunches when done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .idle, .failed:
                // The window closes on these states; keep the layout stable
                // for the moment in between.
                ProgressView(value: 0)
                Text(" ")
                    .font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    updater.cancelUpdate()
                }
                .disabled(!isDownloading)
                .help(isDownloading
                    ? "Stop the download. Nothing is changed."
                    : "The install step is short and can't be interrupted.")
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var isDownloading: Bool {
        if case .downloading = updater.updateState { return true }
        return false
    }
}
