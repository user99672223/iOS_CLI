import SwiftUI

struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var flow = SignInFlow()
    @State private var code = ""
    @State private var pasted = ""
    @State private var showTerminal = false

    var body: some View {
        NavigationStack {
            Form {
                switch flow.phase {
                case .idle, .failed:
                    Section {
                        Text("Claude Code will create a sign-in link for your Claude subscription. You sign in in Safari, then paste the code you get back here.")
                            .font(.callout)
                        Button("Start sign-in") { flow.start() }
                        if case .failed(let m) = flow.phase { Text(m).foregroundStyle(.red).font(.footnote) }
                    }
                    Section("Already have a token?") {
                        SecureField("sk-ant-oat01-…", text: $pasted)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Use this token") {
                            Credentials.save(pasted)
                            pasted = ""
                            model.signedIn = true
                            dismiss()
                        }
                        .disabled(!Credentials.looksValid(pasted))
                        Text("Create one on a computer with `claude setup-token`.").font(.caption).foregroundStyle(.secondary)
                    }
                case .starting:
                    Section { HStack { ProgressView(); Text("Starting Claude Code…") } }
                case .waitingForBrowser, .waitingForToken:
                    Section("1 · Sign in") {
                        if let url = flow.signInURL {
                            Button { openURL(url) } label: { Label("Open the sign-in page", systemImage: "safari") }
                        } else {
                            HStack { ProgressView(); Text("Waiting for the sign-in link…") }
                        }
                    }
                    Section("2 · Paste the code") {
                        TextField("Authentication code", text: $code)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.body.monospaced())
                        Button("Continue") { flow.submit(code: code); code = "" }
                            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || flow.phase == .waitingForToken)
                        if flow.phase == .waitingForToken {
                            HStack { ProgressView(); Text("Finishing sign-in…") }
                        }
                    }
                case .done:
                    Section {
                        Label("Signed in", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("Done") { model.signedIn = true; dismiss() }
                    }
                }
                Section {
                    DisclosureGroup("Terminal", isExpanded: $showTerminal) {
                        Text(flow.screen.isEmpty ? "(no output yet)" : flow.screen)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { if flow.phase != .done { flow.cancel() }; dismiss() }
                }
            }
            .onChange(of: flow.phase) { _, p in if p == .done { model.signedIn = true } }
        }
    }
}
