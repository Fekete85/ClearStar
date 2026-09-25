import SwiftUI
import ClearStarCore

/// Váz: a 16 lépés csoportosítva, a kiválasztott lépés neve és leírása. A feldolgozás még nincs portolva.
struct ContentView: View {
    let strings: Strings
    @State private var selection: StepId? = .loadFrames

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(StepGroup.allCases, id: \.self) { group in
                    Section(strings.t("group.\(group.rawValue)")) {
                        ForEach(StepId.allCases.filter { $0.group == group }, id: \.self) { step in
                            Text("\(step.rawValue). \(strings.t("step.\(step.languageKey).name"))")
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let step = selection {
                VStack(alignment: .leading, spacing: 12) {
                    Text(strings.t("step.\(step.languageKey).name")).font(.largeTitle)
                    Text(strings.t("step.\(step.languageKey).desc")).font(.body).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
