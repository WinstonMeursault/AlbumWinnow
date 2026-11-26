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
                        LabeledContent(L10n.text("app_version"), value: version)
                    }
                    Text(L10n.text("app_copyright_2026_winston_meursault"))
                    Text(L10n.text("app_albumwinnow_s_public_source_code_is_available_under_the_gnu_affero_general_public_license_version_3"))
                }

                Section(L10n.text("app_open_source")) {
                    if let version {
                        Link(L10n.text("app_source_code_for_this_version"),
                             destination: Self.repository.appending(path: "tree/v\(version)"))
                            .accessibilityIdentifier("release-source-code")
                    } else {
                        Link(L10n.text("app_source_code"), destination: Self.repository)
                    }
                    NavigationLink(L10n.text("app_agpl_3_0_license")) {
                        licenseDocument(L10n.text("app_agpl_3_0_license"), resource: "LICENSE", ext: nil)
                    }
                    NavigationLink(L10n.text("app_third_party_notices")) {
                        licenseDocument(L10n.text("app_third_party_notices"), resource: "THIRD-PARTY-NOTICES", ext: "txt")
                    }
                }

                Section(L10n.text("app_privacy")) {
                    Link(L10n.text("app_privacy_policy"), destination: Self.privacyURL)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.text("app_about_open_source"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("app_done")) { dismiss() }
                        .accessibilityIdentifier("about-done")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 400)
        #endif
    }

    private func licenseDocument(_ title: String, resource: String, ext: String?) -> some View {
        ScrollView {
            if let url = Bundle.main.url(forResource: resource, withExtension: ext),
               let contents = try? String(contentsOf: url, encoding: .utf8) {
                Text(verbatim: contents)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("license-document")
            } else {
                Text(L10n.text("app_license_text_is_unavailable"))
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .navigationTitle(title)
    }
}
