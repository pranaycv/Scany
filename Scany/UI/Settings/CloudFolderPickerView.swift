import SwiftUI

struct CloudFolderPickerView: View {
    @ObservedObject var cloud: CloudManager
    let provider: CloudProvider

    @Environment(\.dismiss) private var dismiss
    @State private var folders: [CloudFolder] = []
    @State private var isLoading = true
    @State private var newName = ""
    @State private var errorMessage: String?

    var body: some View {
        navigationContainer {
            List {
                Section("New folder") {
                    HStack {
                        TextField("Folder name", text: $newName)
                            .foregroundStyle(.white)
                        Button("Create") {
                            Task { await createFolder() }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .listRowBackground(Color.white.opacity(0.06))

                Section("Folders in \(provider.displayName)") {
                    if isLoading {
                        ProgressView()
                            .tint(ScanyTheme.accent)
                    } else if folders.isEmpty {
                        Text("No folders yet. Create one above.")
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        ForEach(folders) { folder in
                            Button {
                                cloud.setFolder(folder, for: provider)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(ScanyTheme.accent)
                                    Text(folder.name)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    if cloud.connection(for: provider)?.folder?.id == folder.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(ScanyTheme.accent)
                                    }
                                }
                            }
                        }
                    }
                }
                .listRowBackground(Color.white.opacity(0.06))
            }
            .scanyHideListBackground()
            .navigationTitle("Choose folder")
            .navigationBarTitleDisplayMode(.inline)
            .scanyToolbarChrome()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await reload() }
            .alert("Folder error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func navigationContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            folders = try await cloud.listFolders(provider)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createFolder() async {
        do {
            _ = try await cloud.createFolder(named: newName, provider: provider)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
