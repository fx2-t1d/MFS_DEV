import SwiftUI

/// A bundled markdown document: "# " title, "## " headings, "- " bullets and plain paragraphs.
struct HelpView: View {
    let title: String
    let resource: String
    @Environment(\.dismiss) private var dismiss

    private var lines: [String] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return ["\(resource).md is missing from the app."] }
        return text.components(separatedBy: "\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func row(_ line: String) -> some View {
        if line.hasPrefix("## ") {
            Text(line.dropFirst(3)).font(.headline).padding(.top, 8)
        } else if line.hasPrefix("# ") {
            Text(line.dropFirst(2)).font(.title2.bold())
        } else if line.hasPrefix("- ") {
            HStack(alignment: .top) { Text("•"); Text(inline(String(line.dropFirst(2)))) }
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(inline(line))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

/// App, license and credit information. License and developer details are placeholders to fill in.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("MFS") {
                    LabeledContent("Version", value: version)
                    Text("Meal logging, glucose display and prediction comparison. Read-only toward your pump.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("License") {
                    Text("The MFS license has not been chosen yet.").foregroundStyle(.secondary)
                }
                Section("Inherited licenses") {
                    credit("oref0 / oref1", "OpenAPS contributors, MIT license. Bundled and run unchanged for the Oref0 and Oref1 prediction models.")
                    credit("LoopKit", "Loop Project, MIT license. Used for insulin and glucose types.")
                    credit("Open Food Facts", "Food data under the Open Database License, shown with attribution.")
                    Text("Full license texts are still to be added.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Developer") {
                    Text("Developer and contact information to be added.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func credit(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
