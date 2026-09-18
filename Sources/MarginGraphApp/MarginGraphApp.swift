import SwiftUI
import MarginGraphCore

@MainActor
final class AppModel: ObservableObject {
    @Published var topics: [Topic] = []
    @Published var documents: [Document] = []
    let database: Database?

    init() {
        database = try? Database()
        topics = (try? database?.allTopics()) ?? []
        documents = (try? database?.allDocuments()) ?? []
    }
}

@main
struct MarginGraphApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                List {
                    Section("Notebooks") {
                        ForEach(model.topics, id: \.id) { topic in
                            Label(topic.title, systemImage: "square.grid.2x2")
                        }
                    }
                    Section("Documents") {
                        ForEach(model.documents, id: \.id) { document in
                            Label(document.title, systemImage: "doc")
                        }
                    }
                }
                .navigationTitle("MarginGraph")
            } detail: {
                ContentUnavailableView("Select a notebook or document", systemImage: "book")
            }
        }
    }
}
