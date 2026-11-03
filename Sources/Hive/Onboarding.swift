import AppKit
import SwiftUI

private let accent = Color(red: 0.85, green: 0.47, blue: 0.34)

/// Shown instead of the sessions until Claude Code is installed and signed in.
struct OnboardingView: View {
    @ObservedObject var model: WindowModel

    private var state: SetupState { model.app.setup }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(accent)
                    Text("Willkommen bei Hive")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Mehrere Claude Code-Sessions nebeneinander, in einer Mac-App.\nNoch zwei kurze Schritte, dann geht's los.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                if state == .checking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Suche Claude Code …").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 20)
                } else {
                    VStack(spacing: 10) {
                        Step(number: 1,
                             title: "Claude Code installieren",
                             detail: "Installiert das offizielle Kommandozeilen-Tool von Anthropic in deinen Benutzerordner. Kein Administrator-Passwort nötig.",
                             command: ClaudeSetup.installCommand,
                             status: state == .notInstalled ? .current : .done,
                             button: "Installieren") {
                            model.runSetupStep(title: "Installation", command: ClaudeSetup.installCommand)
                        }
                        Step(number: 2,
                             title: "Bei Claude anmelden",
                             detail: "Dein Browser öffnet sich. Melde dich mit deinem Claude-Abo (Pro oder Max) oder einem Anthropic-Console-Konto an und kehre dann hierher zurück.",
                             command: nil,
                             status: state == .notLoggedIn ? .current : state == .notInstalled ? .pending : .done,
                             button: "Anmelden") {
                            model.runSetupStep(title: "Anmeldung", command: ClaudeSetup.loginCommand)
                        }
                    }
                }

                if let tab = model.setupTab {
                    SetupTerminal(tab: tab)
                }

                Button("Erneut prüfen") { model.app.recheckSetup() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .disabled(state == .checking)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }
}

private enum StepStatus { case pending, current, done }

private struct Step: View {
    let number: Int
    let title: String
    let detail: String
    let command: String?
    let status: StepStatus
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(status == .done ? accent : Color.white.opacity(status == .current ? 0.12 : 0.05))
                    .frame(width: 26, height: 26)
                if status == .done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(status == .current ? .primary : .tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status == .pending ? .tertiary : .primary)
                if status == .current {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let command {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
            if status == .current {
                Button(action: action) { Text(button).padding(.horizontal, 6) }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(status == .current ? 0.06 : 0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(status == .current ? accent.opacity(0.35) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.2), value: status)
    }
}

/// The installer or login running visibly, so users see progress and can answer prompts.
private struct SetupTerminal: View {
    @ObservedObject var tab: TermTab

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if tab.exited {
                    Image(systemName: tab.exitCode == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(tab.exitCode == 0 ? accent : .yellow)
                    Text(tab.exitCode == 0 ? "\(tab.title) abgeschlossen" : "\(tab.title) nicht erfolgreich – siehe Ausgabe unten")
                } else {
                    ProgressView().controlSize(.small)
                    Text("\(tab.title) läuft …")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            TerminalHost(view: tab.view)
                .frame(height: 230)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
    }
}
