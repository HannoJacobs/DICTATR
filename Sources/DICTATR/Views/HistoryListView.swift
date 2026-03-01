import SwiftUI

struct HistoryListView: View {
    @Environment(AppState.self) private var appState
    @State private var records: [DictationRecord] = []
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search dictations...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onChange(of: searchText) {
                        loadRecords()
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)
            .background(.bar)

            Divider()

            if records.isEmpty {
                ContentUnavailableView {
                    Label("No Dictations", systemImage: "mic.slash")
                } description: {
                    Text(searchText.isEmpty
                        ? "Press your hotkey to start dictating."
                        : "No results for \"\(searchText)\"")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(records) { record in
                        HistoryRow(record: record) {
                            appState.copyToClipboard(record.text)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteRecord(record)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 300, minHeight: 400)
        .onAppear { loadRecords() }
        .onChange(of: appState.lastTranscription) {
            loadRecords()
        }
    }

    private func loadRecords() {
        guard let db = appState.databaseManager else { return }
        do {
            if searchText.isEmpty {
                records = try db.fetchRecent(limit: 200)
            } else {
                records = try db.search(query: searchText)
            }
        } catch {
            appState.errorMessage = "Failed to load history: \(error.localizedDescription)"
        }
    }

    private func deleteRecord(_ record: DictationRecord) {
        guard let db = appState.databaseManager else { return }
        do {
            if let audioPath = record.audioFilePath {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
            try db.delete(record)
            loadRecords()
        } catch {
            appState.errorMessage = "Failed to delete record: \(error.localizedDescription)"
        }
    }
}

struct HistoryRow: View {
    let record: DictationRecord
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.previewText)
                .font(.body)
                .lineLimit(2)

            HStack {
                Text(record.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("·")
                    .foregroundStyle(.secondary)

                Text(record.formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onCopy()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy to clipboard")
            }
        }
        .padding(.vertical, 4)
    }
}
