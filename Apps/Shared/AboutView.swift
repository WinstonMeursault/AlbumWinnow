import SwiftUI

struct AboutView: View {
    private static let repository = URL(string: "https://github.com/WinstonMeursault/AlbumWinnow")!
    static let privacyURL = repository.appending(path: "blob/dev/PRIVACY.md")

    @Environment(\.dismiss) private var dismiss

    private var version: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("AlbumWinnow") {
                    if let version {
                        LabeledContent("Version", value: version)
                    }
                    Text("Copyright © 2026 Winston Meursault")
                    Text("AlbumWinnow’s public source code is available under the GNU Affero General Public License, version 3.")
                }

                Section("Open Source") {
                    if let version {
                        Link("Source Code for This Version",
                             destination: Self.repository.appending(path: "tree/v\(version)"))
                            .accessibilityIdentifier("release-source-code")
                    } else {
                        Link("Source Code", destination: Self.repository)
                    }
                    NavigationLink("AGPL-3.0 License") {
                        licenseDocument("AGPL-3.0 License", resource: "LICENSE", ext: nil)
                    }
                    NavigationLink("Third-Party Notices") {
                        licenseDocument("Third-Party Notices", resource: "THIRD-PARTY-NOTICES", ext: "txt")
                    }
                }

                Section("Privacy") {
                    Link("Privacy Policy", destination: Self.privacyURL)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("About & Open Source")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 400)
        #endif
    }

    private func licenseDocument(_ title: LocalizedStringKey, resource: String, ext: String?) -> some View {
        ScrollView {
            if let url = Bundle.main.url(forResource: resource, withExtension: ext),
               let contents = try? String(contentsOf: url, encoding: .utf8) {
                Text(verbatim: contents)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("license-document")
            } else {
                Text("License text is unavailable.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .navigationTitle(title)
    }
}
