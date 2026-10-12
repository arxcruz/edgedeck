import AppKit
import SwiftUI

/// A small window on the Mac's main screen that asks something without blocking. A modal dialog
/// (NSAlert.runModal) makes macOS drop every touch on the Edge until it's answered, so anything
/// another Mac can trigger asks this way instead.
final class PromptWindow: NSObject, NSWindowDelegate {
    private static var open: [PromptWindow] = []

    private let panel: NSPanel
    private var cancel: (() -> Void)?

    /// `content` gets a `close` to call once answered; closing the window instead runs `cancel`.
    static func show<Content: View>(title: String, cancel: @escaping () -> Void,
                                    content: (_ close: @escaping () -> Void) -> Content) {
        let prompt = PromptWindow(title: title, cancel: cancel)
        prompt.panel.contentView = NSHostingView(rootView: content { [weak prompt] in prompt?.close(answered: true) })
        prompt.present()
        open.append(prompt)
    }

    private init(title: String, cancel: @escaping () -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.titled, .closable],
                        backing: .buffered, defer: false)
        self.cancel = cancel
        super.init()
        panel.title = title
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
    }

    private func present() {
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        if let screen = NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY))
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func close(answered: Bool) {
        if answered { cancel = nil }
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        let cancel = self.cancel
        self.cancel = nil
        Self.open.removeAll { $0 === self }
        cancel?()
    }
}

/// Another Mac connects with a Pairing saved by an earlier EdgeDeck: macOS is about to ask for the password.
struct KeychainPrompt: View {
    let hostName: String
    let answer: (_ pairAgain: Bool) -> Void
    @State private var hideFromNowOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("macOS will ask for your password", systemImage: "key.fill").font(.headline)
            Text("\(hostName) wants to connect to EdgeDeck. EdgeDeck keeps its Pairing with \(hostName) in your keychain, saved by an earlier version, so macOS asks once before this version can use it: enter your password and choose Always Allow.\n\nOr Pair again with a code instead.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Don't show this again", isOn: $hideFromNowOn)
            HStack {
                Spacer()
                Button("Pair Again") { finish(pairAgain: true) }
                Button("Continue") { finish(pairAgain: false) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func finish(pairAgain: Bool) {
        if hideFromNowOn { RemoteKeychain.noticeHidden = true }
        answer(pairAgain)
    }
}

/// On the Source: type the code a Host's Edge shows to Pair with it.
struct PairingPrompt: View {
    let hostName: String
    let answer: (String?) -> Void
    @State private var code = ""

    private var digits: String { code.filter(\.isNumber) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Show this Mac's Dashboard on \(hostName)'s Edge?").font(.headline)
            Text("Type the 6-digit code shown on the Edge. You only need to do this once.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("123456", text: $code)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .onSubmit { if digits.count == 6 { answer(digits) } }
            HStack {
                Spacer()
                Button("Cancel") { answer(nil) }.keyboardShortcut(.cancelAction)
                Button("Pair") { answer(digits) }.keyboardShortcut(.defaultAction).disabled(digits.count != 6)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
