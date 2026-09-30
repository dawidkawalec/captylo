import SwiftUI

/// Ustawienia > Dane: "Import ze starego VocaType". Shows what a dry run found, imports after a
/// confirmation (progress bar, "Przerwij"), then the summary and "Zaimportowano <data>" with
/// "Importuj ponownie" (safe: rows already here are skipped).
@MainActor
struct LegacyImportRow: View {
    let model: LegacyImportModel

    @State private var confirmImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassRow(
                title: Text("Import ze starego VocaType"),
                subtitle: subtitle,
                systemImage: "square.and.arrow.down.on.square"
            ) {
                trailing
            }
            details
                .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
                .padding(.trailing, GlassTokens.Padding.rowHorizontal)
                .padding(.bottom, 4)
        }
        .onAppear {
            model.prepare()
        }
        .alert("Zaimportować dane ze starego VocaType?", isPresented: $confirmImport) {
            Button("Importuj") {
                model.startImport()
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Captylo przeniesie historię transkrypcji, wersje poprawione przez AI, statystyki i nagrania. Nagrania są podlinkowane, więc nie zajmują dodatkowego miejsca na dysku. Dane starej aplikacji zostają nietknięte. Import można bezpiecznie powtórzyć: wpisy, które już są w Captylo, zostaną pominięte.")
        }
    }

    // MARK: Parts

    private var subtitle: Text {
        if model.phase == .scanning {
            return Text("Sprawdzam dane starej wersji…")
        }
        if model.sourcesMissing {
            return Text("Nie znaleziono danych starego VocaType na tym Macu.")
        }
        if let scan = model.scan {
            return Text(verbatim: LegacyImportSummary.found(scan))
        }
        return Text("Historia, wersje AI, statystyki i nagrania ze starej aplikacji.")
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.phase {
        case .scanning:
            ProgressView()
                .controlSize(.small)
                .tint(GlassColor.textSecondary)
        case .importing:
            Button("Przerwij") {
                model.cancel()
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        case .idle:
            if model.lastImport != nil {
                Button("Importuj ponownie") {
                    confirmImport = true
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .disabled(!model.canImport)
            } else {
                Button("Importuj") {
                    confirmImport = true
                }
                .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
                .disabled(!model.canImport)
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if case .importing(let processed, let total) = model.phase {
            VStack(alignment: .leading, spacing: 6) {
                ToolProgressTrack(value: model.progress)
                Text(verbatim: LegacyImportSummary.progress(processed: processed, total: total))
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .monospacedDigit()
            }
        }
        if let result = model.result {
            ToolStatusLine(text: LegacyImportSummary.result(result), tone: .success)
            if let note = LegacyImportSummary.audioNote(result) {
                ToolStatusLine(text: note)
            }
        }
        if let lastImport = model.lastImport, model.phase == .idle {
            ToolStatusLine(text: LegacyImportSummary.importedAt(lastImport.importedAt))
        }
        if let error = model.errorMessage {
            ToolStatusLine(text: error, tone: .error)
        }
    }
}
