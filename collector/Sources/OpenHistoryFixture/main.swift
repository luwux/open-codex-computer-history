import SwiftUI
import UniformTypeIdentifiers

@main
struct OpenHistoryFixtureApp: App {
    var body: some Scene {
        WindowGroup("Open History Fixture") {
            FixtureView()
                .frame(minWidth: 680, minHeight: 520)
        }
        .commands {
            CommandMenu("Fixture") {
                Button("Run Synthetic Action") {
                    NotificationCenter.default.post(
                        name: .runSyntheticFixtureAction,
                        object: nil
                    )
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Select Next Item") {
                    NotificationCenter.default.post(
                        name: .selectNextFixtureItem,
                        object: nil
                    )
                }
                .keyboardShortcut("j", modifiers: [.command])
            }
        }
    }
}

private extension Notification.Name {
    static let runSyntheticFixtureAction = Notification.Name(
        "OpenHistoryFixture.RunSyntheticAction"
    )
    static let selectNextFixtureItem = Notification.Name(
        "OpenHistoryFixture.SelectNextItem"
    )
}

struct FixtureView: View {
    @State private var note = ""
    @State private var secret = ""
    @State private var actionCount = 0
    @State private var selectedItem = "Alpha"
    @State private var droppedItems: [String] = []
    @FocusState private var focusedField: Field?

    private let items = ["Alpha", "Beta", "Gamma"]

    enum Field {
        case note
        case secret
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            HStack(alignment: .top, spacing: 28) {
                form
                activityPanel
            }
            dragArea
        }
        .padding(28)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            focusedField = .note
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .runSyntheticFixtureAction
            )
        ) { _ in
            actionCount += 1
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .selectNextFixtureItem
            )
        ) { _ in
            let index = items.firstIndex(of: selectedItem) ?? 0
            selectedItem = items[(index + 1) % items.count]
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Computer History Fixture")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .accessibilityIdentifier("fixture-title")
            Text("Synthetic controls only. No personal content is used.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("fixture-subtitle")
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Input events")
                .font(.headline)

            TextField("Synthetic note", text: $note)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .note)
                .onSubmit {
                    actionCount += 1
                }
                .accessibilityLabel("Synthetic note")
                .accessibilityIdentifier("synthetic-note")

            SecureField("Synthetic secret", text: $secret)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .secret)
                .accessibilityLabel("Synthetic secret")
                .accessibilityIdentifier("synthetic-secret")

            Button("Run Synthetic Action") {
                actionCount += 1
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityIdentifier("synthetic-action")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selection events")
                .font(.headline)

            Picker("Fixture item", selection: $selectedItem) {
                ForEach(items, id: \.self) { item in
                    Text(item).tag(item)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("fixture-selection")

            Divider()

            LabeledContent("Selected", value: selectedItem)
            LabeledContent("Action count", value: "\(actionCount)")
                .accessibilityIdentifier("fixture-action-count")
        }
        .frame(width: 230, alignment: .leading)
    }

    private var dragArea: some View {
        HStack(spacing: 16) {
            Text("Synthetic payload")
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .draggable("Synthetic payload")
                .accessibilityIdentifier("fixture-drag-source")

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)

            VStack {
                Text("Drop target")
                    .font(.headline)
                Text(droppedItems.last ?? "Waiting")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .dropDestination(for: String.self) { values, _ in
                droppedItems.append(contentsOf: values)
                return true
            }
            .accessibilityIdentifier("fixture-drop-target")
        }
    }
}
