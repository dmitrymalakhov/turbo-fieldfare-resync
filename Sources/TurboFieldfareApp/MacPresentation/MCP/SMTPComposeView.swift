import SwiftUI
import TurboFieldfareAppCore

struct SMTPComposeView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: AppMCPProfile
    let manager: AppMCPManager
    @State private var to = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var reviewing = false
    @State private var sending = false
    @State private var attempted = false
    @State private var result: String?
    @State private var error: String?

    private var recipients: [String] {
        to.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reviewing ? "Review Email" : "Compose Email").font(.title2.weight(.semibold))
            Text("From: \(profile.email) · \(profile.server)").foregroundStyle(.secondary).textSelection(.enabled)
            if reviewing {
                LabeledContent("To", value: recipients.joined(separator: ", "))
                LabeledContent("Subject", value: subject)
                ScrollView { Text(bodyText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            } else {
                TextField("To · addresses separated by commas", text: $to).textFieldStyle(.roundedBorder)
                TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
                TextEditor(text: $bodyText).font(.body).border(.separator)
            }
            if let result { Text(result).textSelection(.enabled) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if sending { ProgressView("Submitting to SMTP server…") }
            Divider()
            HStack {
                Button(attempted ? "Close" : "Cancel") { dismiss() }.disabled(sending)
                Spacer()
                if reviewing && !attempted {
                    Button("Back") { reviewing = false }
                    Button("Send Email") { send() }.buttonStyle(.borderedProminent)
                        .disabled(manager.status(profile.id) != .connected)
                } else if !attempted {
                    Button("Review Email") { reviewing = true }.buttonStyle(.borderedProminent)
                        .disabled(recipients.isEmpty || subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24).frame(width: 650, height: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(sending)
    }

    private func send() {
        guard !attempted else { return }
        // Freeze exactly what was reviewed and prevent accidental duplicate submissions.
        let recipients = recipients, subject = subject, body = bodyText
        attempted = true; sending = true
        Task { @MainActor in
            do {
                let response = try await manager.sendSMTP(profile, to: recipients, subject: subject, body: body)
                guard let accepted = response["accepted"]?.arrayValue?.compactMap(\.stringValue),
                      let rejected = response["rejected"]?.objectValue else {
                    throw AppMCPError.protocolError
                }
                result = "Accepted by SMTP server: \(accepted.joined(separator: ", ")). This does not confirm delivery."
                if !rejected.isEmpty {
                    result! += "\nRejected: " + rejected.keys.sorted().map { "\($0) (\(rejected[$0]?.intValue ?? 0))" }.joined(separator: ", ")
                    result! += "\nDo not resend to recipients already accepted."
                }
            } catch {
                self.error = error.localizedDescription + "\nIf submission was interrupted, the server may have accepted the message. Check before retrying."
            }
            sending = false
        }
    }
}
