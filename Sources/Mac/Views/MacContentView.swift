import AppKit
import SwiftUI

private enum MacSection: String, CaseIterable, Identifiable {
    case music = "音乐", knowledge = "知识库", reports = "报表", devices = "设备"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .music: "music.note"
        case .knowledge: "books.vertical"
        case .reports: "chart.xyaxis.line"
        case .devices: "iphone.and.arrow.forward"
        }
    }
}

struct MacContentView: View {
    let connection: MacDeviceConnection
    let player: MacAudioPlayer
    let library: MacLibrary
    @State private var selection: MacSection? = .music
    @State private var showsQueue = false
    @State private var selectedAlbumID: String?
    @State private var showsPortableAlbum = false

    var body: some View {
        NavigationSplitView {
            List(MacSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .navigationTitle("小晴空")
            .navigationSplitViewColumnWidth(min: 160, ideal: 185, max: 220)
            .safeAreaInset(edge: .bottom) {
                Button { selection = .devices } label: {
                    Label(connection.connectedName ?? "连接 iPhone", systemImage: connection.isConnected ? "iphone.radiowaves.left.and.right" : "iphone")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .buttonStyle(.plain)
                .help(connection.isConnected ? "查看已连接设备" : "设置 iPhone 连接")
            }
            .background {
                MacSidebarMaterial().ignoresSafeArea(.container, edges: .top)
            }
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch selection ?? .music {
                    case .music:
                        MacMusicView(connection: connection, player: player, library: library,
                            selectedAlbumID: $selectedAlbumID, showsPortableAlbum: $showsPortableAlbum)
                    case .knowledge: MacKnowledgeView(content: library.content)
                    case .reports: MacReportsView(connection: connection, openDevices: showDevices)
                    case .devices: MacPairingView(connection: connection)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                MacPlayerBar(connection: connection, player: player, library: library,
                    selectedAlbumID: selectedAlbumID, showsPortableAlbum: showsPortableAlbum, showsQueue: $showsQueue)
                    .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .navigationTitle((selection ?? .music).rawValue)
            .inspector(isPresented: $showsQueue) {
                MacQueueView(player: player, isTransferring: connection.isTransferring)
                    .inspectorColumnWidth(min: 250, ideal: 290, max: 360)
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(MacWindowAppearance().frame(width: 0, height: 0))
    }

    private func showDevices() { selection = .devices }
}

private struct MacSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct MacWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }

    func updateNSView(_ nsView: WindowView, context: Context) {
        nsView.window?.titlebarSeparatorStyle = .none
    }

    final class WindowView: NSView {
        private var searchFocusMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeSearchFocusMonitor()
            // The toolbar separator belongs to the window, not the content views.
            window?.titlebarSeparatorStyle = .none
            guard let window else { return }
            searchFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
                guard let window, event.window === window,
                      window.attachedSheet == nil,
                      window.contentLayoutRect.contains(event.locationInWindow),
                      let editor = window.firstResponder as? NSTextView,
                      editor.isFieldEditor,
                      editor.delegate is NSSearchField else { return event }
                // Release toolbar search before AppKit delivers the same click to the content.
                // Keep the query and let buttons, lists and selectable text handle the event normally.
                window.makeFirstResponder(nil)
                return event
            }
        }

        private func removeSearchFocusMonitor() {
            if let searchFocusMonitor {
                NSEvent.removeMonitor(searchFocusMonitor)
                self.searchFocusMonitor = nil
            }
        }

        deinit {
            removeSearchFocusMonitor()
        }
    }
}
