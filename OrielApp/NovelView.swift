import SwiftUI
import OrielReading
import OrielReaderUI

struct NovelView: View {
    @ObservedObject var session: NovelSession
    @ObservedObject var library: NovelLibrary
    var chooseFile: () -> Void
    @AppStorage("novel.simplified") private var simplified = false
    @AppStorage("novel.font.size") private var fontSize = 13
    @StateObject private var discovery = CatalogDiscovery()
    @State private var query = ""
    @State private var removing: ShelfBook?
    private let accent = OrielPalette.tint

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let label = session.busy {
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(label).lineLimit(1)
                        Button("取消", action: session.cancel)
                    }.padding(.horizontal, 3)
                    Spacer(minLength: 0)
                } else if let target = removing {
                    Spacer(minLength: 0)
                    Text("移除《\(target.title)》？").lineLimit(2)
                    HStack {
                        Button("保留") { removing = nil }
                        Button("移除") { removing = nil; session.remove(target) }
                    }
                    Spacer(minLength: 0)
                } else {
                    switch session.section {
                    case .shelf, .catalog:
                        if geometry.size.height < 68 { pocketShelf } else { libraryView(width: geometry.size.width) }
                    case .contents:
                        if geometry.size.height < 68 { pocketNavigation(bookmarks: false) } else { contents }
                    case .bookmarks:
                        if geometry.size.height < 68 { pocketNavigation(bookmarks: true) } else { bookmarks }
                    case .search: NovelLookupView(session: session, pocket: geometry.size.height < 68)
                    case .reading: reading(size: geometry.size)
                    }
                    if let message = session.notice {
                        HStack(spacing: 3) {
                            Text(message).font(.caption).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                            if let title = session.retryTitle { Button(title) { session.retry(chooseFile: chooseFile) }.foregroundStyle(accent) }
                            icon("xmark", "关闭提示") { session.notice = nil }
                        }.padding(4).background(.quaternary)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .bottom) {
                if session.markConfirmation && session.section == .reading {
                    Label("已加书签", systemImage: "bookmark.fill")
                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule()).padding(.bottom, geometry.size.height > 90 ? 26 : 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(OrielPalette.text)
        .tint(accent)
        .buttonStyle(.plain)
        .onAppear { session.start() }
        .onDisappear { discovery.reset() }
        .onChange(of: query) { _, _ in discovery.reset() }
        .onChange(of: session.section) { _, _ in query = "" }
        .onChange(of: library.books) { _, books in
            if let selected = session.book, !books.contains(selected) { session.showShelf() }
        }
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }.accessibilityLabel(label).help(label)
    }

    private func libraryView(width: CGFloat) -> some View {
        let filter = NovelQuery(query)
        return VStack(spacing: 0) {
            HStack(spacing: width < 160 ? 2 : 8) {
                sectionButton("书架", .shelf)
                sectionButton("书库", .catalog)
                Spacer(minLength: 0)
                icon("square.and.arrow.down", "导入 TXT 或 EPUB", action: chooseFile)
            }.padding(.horizontal, width < 160 ? 2 : 7)
            Divider()
            if session.section == .shelf && library.books.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        Image(systemName: "books.vertical").font(.title2).foregroundStyle(accent)
                        Text("书架还是空的").fontWeight(.medium)
                        Button("导入本地书", action: chooseFile).foregroundStyle(accent)
                        Button("去书库选书") { session.section = .catalog }.foregroundStyle(OrielPalette.mutedText)
                    }.frame(maxWidth: .infinity).padding(.vertical, 14)
                }
            } else {
                if session.section == .catalog || library.books.count > 5 {
                    searchBox("搜书名或作者")
                        .onSubmit { if session.section == .catalog { discovery.search(query) } }
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if session.section == .catalog {
                            let sources = CatalogNovel.all.filter { filter.matches($0.title + $0.originalTitle + $0.author) }
                            let localIDs = Set(sources.map(\.id))
                            let found = sources + discovery.results.filter { !localIDs.contains($0.id) }
                            ForEach(found) { source in
                                let saved = library.books.first { $0.sourceID == source.id }
                                row(title: source.title, detail: source.author, mark: saved == nil ? "arrow.down.to.line" : "checkmark",
                                    color: color(source.id), width: width) {
                                    if let saved { session.open(saved) } else { session.open(source) }
                                }
                            }
                            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                discoveryFooter(empty: found.isEmpty)
                            }
                            Text("Project Gutenberg").font(.system(size: 9)).foregroundStyle(OrielPalette.mutedText)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        } else {
                            let books = library.recent.filter { filter.matches($0.title + ($0.author ?? "")) }
                            ForEach(books) { book in
                                let progress = library.place(for: book.id)
                                let detail = progress.updated == nil ? "\(book.chapterCount) 节" : "读到 \(progress.chapter + 1) / \(book.chapterCount)"
                                row(title: book.title, detail: detail, mark: "chevron.right",
                                    color: color(book.sourceID ?? book.id.utf8.reduce(0) { $0 + Int($1) }), width: width) {
                                    session.open(book)
                                }.contextMenu { Button("从书架移除") { removing = book } }
                            }
                            if books.isEmpty { Text("没有匹配的书").foregroundStyle(OrielPalette.mutedText).padding(8) }
                        }
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            session.openFiles(urls)
            return true
        }
    }

    @ViewBuilder private func discoveryFooter(empty: Bool) -> some View {
        if discovery.searching {
            HStack(spacing: 5) { ProgressView().controlSize(.small); Button("取消", action: discovery.reset) }.padding(6)
        } else if discovery.failed {
            Button("书库暂时无法连接 · 重试") { discovery.search(query, from: discovery.next ?? 1) }
                .foregroundStyle(accent).padding(6)
        } else if !discovery.searched {
            Button("搜索全部中文藏书") { discovery.search(query) }.foregroundStyle(accent).padding(6)
        } else if let next = discovery.next {
            Button("更多结果") { discovery.search(query, from: next) }.foregroundStyle(accent).padding(6)
        } else if empty {
            Text("没有匹配的书").foregroundStyle(OrielPalette.mutedText).padding(6)
        }
    }

    private func sectionButton(_ title: String, _ section: NovelSession.Section) -> some View {
        Button { session.section = section; session.notice = nil } label: {
            Text(title).fontWeight(session.section == section ? .semibold : .regular)
                .foregroundStyle(session.section == section ? OrielPalette.text : OrielPalette.mutedText)
                .padding(.horizontal, 2).frame(height: 25)
                .overlay(alignment: .bottom) {
                    if session.section == section { Capsule().fill(accent).frame(height: 2) }
                }
        }.accessibilityAddTraits(session.section == section ? .isSelected : [])
    }

    private func color(_ id: Int) -> Color {
        let colors = [accent, Color(red: 0.52, green: 0.34, blue: 0.32), Color(red: 0.37, green: 0.4, blue: 0.54),
                      Color(red: 0.52, green: 0.42, blue: 0.24)]
        return colors[id % colors.count]
    }

    private func row(title: String, detail: String, mark: String, color: Color, width: CGFloat,
                     action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 7) {
                    if width > 155 {
                        RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.16)).frame(width: 24, height: 31)
                            .overlay(alignment: .leading) { Rectangle().fill(color.opacity(0.6)).frame(width: 2).padding(.leading, 3) }
                            .overlay { Image(systemName: "text.alignleft").font(.system(size: 8)).foregroundStyle(color) }
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(detail).font(.system(size: 10)).lineLimit(1).foregroundStyle(OrielPalette.mutedText)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: mark).font(.system(size: 10)).foregroundStyle(OrielPalette.mutedText)
                }
                .padding(.horizontal, width > 155 ? 9 : 3).padding(.vertical, 6)
                .contentShape(Rectangle())
            }.accessibilityLabel(title).accessibilityValue(detail)
            Divider().padding(.leading, width > 155 ? 40 : 3)
        }
    }

    private func searchBox(_ placeholder: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(OrielPalette.mutedText)
            TextField(placeholder, text: $query).textFieldStyle(.plain)
            if !query.isEmpty { icon("xmark.circle.fill", "清除搜索") { query = "" } }
        }.padding(.horizontal, 7).frame(height: 25)
    }

    private var pocketShelf: some View {
        Menu {
            Button("导入 TXT 或 EPUB", action: chooseFile)
            if !library.books.isEmpty {
                Section("书架") { ForEach(library.recent) { book in Button(book.title) { session.open(book) } } }
            }
            Menu("在线书库") {
                ForEach(CatalogNovel.all) { book in Button(book.title) { session.open(book) } }
            }
        } label: {
            Label("选书", systemImage: "books.vertical").padding(3)
        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("选书")
    }

    @ViewBuilder private func reading(size: CGSize) -> some View {
        if let book = session.book, session.chapters.indices.contains(session.chapter) {
            let index = session.chapter
            let pocket = size.height < 68
            let compact = size.height < 90 || size.width < 155
            let page = NovelPageView(bookID: book.id, chapter: session.chapters[index], index: index, offset: session.offset,
                                     highlight: session.highlight, simplified: simplified, fontSize: min(CGFloat(fontSize), max(10, (size.height - 3) * 0.64)),
                                     onPosition: { session.saveOffset($0, bookID: book.id, index: index) },
                                     onTurn: { session.turn(to: index + $0) },
                                     onPreviousChapterEnd: { session.jump(to: index - 1, offset: .max) })
            if !pocket {
                HStack(spacing: 2) {
                    icon("chevron.left", "返回书架") { session.showShelf() }
                    if size.width > 120 { Text(book.title).font(.system(size: 11, weight: .medium)).lineLimit(1) }
                    Spacer(minLength: 0)
                    if compact { icon("list.bullet", "章节目录") { session.section = .contents } }
                    readingMenu(book, index: index, pocket: false, compact: compact)
                }.padding(.horizontal, 3)
                Divider()
            }
            // Keep the native text view alive across compact layout changes.
            HStack(alignment: .top, spacing: 0) {
                page
                if pocket {
                    readingMenu(book, index: index, pocket: true, compact: true)
                }
            }
            if !pocket && !compact {
                Divider()
                HStack {
                    icon("chevron.left", "上一章") { session.turn(to: index - 1) }.disabled(index == 0)
                    Spacer(minLength: 0)
                    Button { session.section = .contents } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "list.bullet")
                            Text("\(index + 1) / \(book.chapterCount)").monospacedDigit()
                        }.font(.system(size: 11)).frame(height: 22)
                    }.accessibilityLabel("章节目录").accessibilityValue("\(index + 1) / \(book.chapterCount)")
                    Spacer(minLength: 0)
                    icon("chevron.right", "下一章") { session.turn(to: index + 1) }.disabled(index + 1 == book.chapterCount)
                }.padding(.horizontal, 4)
            }
        }
    }

    private func readingMenu(_ book: ShelfBook, index: Int, pocket: Bool, compact: Bool) -> some View {
        Menu {
            if pocket {
                Button("返回书架") { session.showShelf() }
                Button("章节目录") { session.section = .contents }
            }
            if compact {
                Button("上一章") { session.turn(to: index - 1) }.disabled(index == 0)
                Button("下一章") { session.turn(to: index + 1) }.disabled(index + 1 == book.chapterCount)
            }
            Button("查找正文") { session.section = .search }
            Button("添加书签") { session.markHere() }
            Button("查看书签") { session.section = .bookmarks }
            Divider()
            Menu("字号") {
                ForEach([13, 16, 19, 22], id: \.self) { value in
                    Button { fontSize = value } label: {
                        if value == fontSize { Label("\(value) pt", systemImage: "checkmark") }
                        else { Text("\(value) pt") }
                    }
                }
            }
            Toggle("简体阅读", isOn: $simplified)
            if let source = book.sourcePage {
                Link("书源 · Project Gutenberg", destination: source)
                Button("在访达中查看原文") { session.showOriginal() }
            }
            Button("从书架移除") { removing = book }
        } label: {
            Image(systemName: pocket ? "ellipsis" : "textformat.size").frame(width: pocket ? 16 : 23, height: 22)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("阅读设置").help("阅读设置")
    }

    private func pocketNavigation(bookmarks: Bool) -> some View {
        HStack(spacing: 2) {
            icon("chevron.left", "返回正文") { session.section = .reading }
            Menu(bookmarks ? "书签" : "目录") {
                if bookmarks, let book = session.book {
                    Button("添加当前位置") { session.markHere() }
                    ForEach(library.places.marks(for: book.id)) { mark in
                        Button(String(mark.excerpt.prefix(24))) { session.jump(to: mark.chapter, offset: mark.offset) }
                    }
                } else if session.chapters.count <= 24 {
                    chapterChoices(session.chapters.indices)
                } else {
                    ForEach(Array(stride(from: 0, to: session.chapters.count, by: 20)), id: \.self) { start in
                        let end = min(start + 20, session.chapters.count)
                        Menu("\(start + 1)–\(end)") { chapterChoices(start..<end) }
                    }
                }
            }.menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func chapterChoices(_ indices: Range<Int>) -> some View {
        ForEach(indices, id: \.self) { index in
            Button(session.chapters[index].title) { session.turn(to: index) }
        }
    }

    private var bookmarks: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                icon("chevron.left", "返回正文") { session.section = .reading }
                Text("书签").fontWeight(.medium)
                Spacer(minLength: 0)
                icon("bookmark.badge.plus", "收藏当前位置") { session.markHere() }
            }
            Divider()
            if let book = session.book {
                let marks = library.places.marks(for: book.id)
                ScrollView {
                    if marks.isEmpty {
                        Button("添加当前位置") { session.markHere() }.foregroundStyle(accent).padding(8)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(marks) { mark in
                            HStack(spacing: 2) {
                                Button {
                                    session.jump(to: mark.chapter, offset: mark.offset)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        if session.chapters.indices.contains(mark.chapter) {
                                            Text(session.chapters[mark.chapter].title).font(.caption).foregroundStyle(OrielPalette.mutedText).lineLimit(1)
                                        }
                                        Text(mark.excerpt).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }
                                icon("minus.circle", "移除书签") { library.removeMark(book: book, mark: mark) }
                            }.padding(5)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var contents: some View {
        let filter = NovelQuery(query)
        return VStack(spacing: 0) {
            HStack {
                icon("chevron.left", "返回正文") { session.section = .reading }
                Text("目录").fontWeight(.medium)
                Spacer(minLength: 0)
            }
            if session.chapters.count > 8 { searchBox("查找章节") }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let indices = session.chapters.indices.filter { filter.matches(session.chapters[$0].title) }
                        ForEach(indices, id: \.self) { i in
                            Button { session.turn(to: i) } label: {
                                HStack(spacing: 5) {
                                    if i == session.chapter { Image(systemName: "checkmark").foregroundStyle(accent) }
                                    Text(session.chapters[i].title).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6).contentShape(Rectangle())
                            }.id(i)
                            Divider()
                        }
                        if indices.isEmpty { Text("没有匹配的章节").foregroundStyle(OrielPalette.mutedText).padding(6) }
                    }
                }.onAppear { proxy.scrollTo(session.chapter, anchor: .center) }
            }
        }
    }
}

private struct NovelLookupView: View {
    @ObservedObject var session: NovelSession
    let pocket: Bool
    @State private var query = ""
    @State private var matches = NovelMatches.empty
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { session.section = .reading } label: {
                    Image(systemName: "chevron.left").frame(width: 22, height: 22)
                }.accessibilityLabel("返回正文")
                TextField("查找正文", text: $query).textFieldStyle(.plain).focused($focused)
                if pocket && !query.isEmpty {
                    Menu {
                        if matches.hits.isEmpty { Text(searching ? "正在查找…" : "没有匹配") }
                        ForEach(matches.hits) { hit in
                            Button(hit.excerpt) { session.jump(to: hit.chapter, offset: hit.offset, length: hit.length) }
                        }
                    } label: { Image(systemName: "list.bullet") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("搜索结果")
                } else if !query.isEmpty {
                    Button { query = ""; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(OrielPalette.mutedText)
                    }.accessibilityLabel("清除搜索")
                }
            }.padding(.trailing, 5)
            if !pocket {
                Divider()
                results
            }
        }
        .onAppear { focused = true }
        .task(id: query) {
            searching = !query.isEmpty
            matches = .empty
            guard !query.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(160))
                let found = try await NovelSearch.find(query, in: session.chapters)
                try Task.checkCancellation()
                matches = found
                searching = false
            } catch { /* A newer search or navigation owns the view. */ }
        }
        .onExitCommand { session.section = .reading }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(matches.hits) { hit in
                    Button {
                        session.jump(to: hit.chapter, offset: hit.offset, length: hit.length)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            if session.chapters.indices.contains(hit.chapter) {
                                Text(session.chapters[hit.chapter].title).font(.caption).foregroundStyle(OrielPalette.mutedText).lineLimit(1)
                            }
                            Text(hit.excerpt).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6).contentShape(Rectangle())
                    }
                    Divider()
                }
                if matches.hasMore { Text("前 80 处 · 可继续输入").font(.caption).foregroundStyle(OrielPalette.mutedText).padding(6) }
                if !query.isEmpty && matches.hits.isEmpty {
                    Text(searching ? "正在查找…" : "没有找到匹配的文字").foregroundStyle(OrielPalette.mutedText).padding(6)
                }
            }
        }
    }
}
