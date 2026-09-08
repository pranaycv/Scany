import SwiftUI
import UniformTypeIdentifiers

struct CloudSettingsView: View {
    @ObservedObject var cloud: CloudManager
    var onClose: () -> Void

    @State private var folderProvider: CloudProvider?
    @State private var busyProvider: CloudProvider?
    @State private var showiCloudPicker = false

    var body: some View {
        navigationContainer {
            List {
                Section {
                    Text("Scans are saved to Google Drive or iCloud Drive. Scany does not keep a local document library.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .listRowBackground(Color.white.opacity(0.06))
                }

                if !CloudConfig.Google.isConfigured {
                    Section("Developer setup") {
                        Text("Live Google Drive needs a client ID in Cloud/CloudConfig.swift. Until that is set, Connect Drive uses a sandbox folder labeled CloudUploadSimulation.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .listRowBackground(Color.white.opacity(0.06))
                }

                providerSection(.googleDrive)
                providerSection(.iCloud)
            }
            .scanyHideListBackground()
            .listStyle(.insetGrouped)
            .navigationTitle("Cloud")
            .navigationBarTitleDisplayMode(.inline)
            .scanyToolbarChrome()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done", action: onClose)
                }
            }
            .sheet(item: $folderProvider) { provider in
                CloudFolderPickerView(cloud: cloud, provider: provider)
            }
            .fileImporter(
                isPresented: $showiCloudPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await cloud.connectICloud(folderURL: url) }
                case .failure:
                    break
                }
            }
            .alert("Cloud", isPresented: Binding(
                get: { cloud.statusMessage != nil },
                set: { if !$0 { cloud.statusMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(cloud.statusMessage ?? "")
            }
            .overlay {
                if let busyProvider {
                    ProgressView("Connecting \(busyProvider.displayName)…")
                        .padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
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

    private func providerSection(_ provider: CloudProvider) -> some View {
        let connection = cloud.connection(for: provider)
        return Section(provider.displayName) {
            if let connection {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ScanyTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.account.displayName)
                            .foregroundStyle(.white)
                        Text(connection.account.email)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(ScanyTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.folder?.name ?? "No folder selected")
                            .foregroundStyle(.white)
                        if connection.isSimulated {
                            Text("Sandbox simulation")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Spacer()
                    Button("Change") {
                        if provider == .iCloud {
                            showiCloudPicker = true
                        } else {
                            folderProvider = provider
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }

                Button(role: .destructive) {
                    Task { await cloud.disconnect(provider) }
                } label: {
                    Text("Disconnect")
                }
            } else {
                Button {
                    if provider == .iCloud {
                        showiCloudPicker = true
                        return
                    }
                    Task {
                        busyProvider = provider
                        await cloud.connect(provider)
                        busyProvider = nil
                        if cloud.connection(for: provider)?.folder == nil,
                           cloud.connection(for: provider) != nil {
                            folderProvider = provider
                        }
                    }
                } label: {
                    Label("Connect \(provider.displayName)", systemImage: provider.systemImage)
                        .foregroundStyle(ScanyTheme.accent)
                }
            }
        }
        .listRowBackground(Color.white.opacity(0.06))
    }
}
