import SwiftUI
import OrielReading
import OrielReaderUI

struct NovelView: View {
    @ObservedObject var session: NovelSession
    @ObservedObject var library: NovelLibrary
    var chooseFile: (ShelfBook?) -> Void
    @AppStorage("novel.simplified") private var simplified = false
    @AppStorage("novel.font.size") private var fontSize = 13
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
                    Text("移除《\(target.title)》？").lineLimit(2).multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                    HStack(spacing: 12) {
                        Button("保留") { removing = nil }
                        Button("移除") { removing = nil; session.remove(target) }.foregroundStyle(accent)
                    }.padding(.top, 5)
                    Spacer(minLength: 0)
                } else {
                    switch session.section {
                    case .shelf:
                        if geometry.size.height < 68 { pocketShelf } else { shelfView(width: geometry.size.width) }
                    case .contents:
                        if geometry.size.height < 68 { pocketNavigation(bookmarks: false) } else { contents }
                    case .bookmarks:
                        if geometry.size.height < 68 { pocketNavigation(bookmarks: true) } else { bookmarks }
                    case .search: NovelLookupView(session: session, pocket: geometry.size.height < 68)
                    case .reading: reading(size: geometry.size)
                    }
                    if let message = session.notice {
                        HStack(spacing: 4) {
                            Text(message).font(.caption).lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let title = session.retryTitle { Button(title) { session.retry(chooseFile: chooseFile) }.foregroundStyle(accent) }
                            icon("xmark", "关闭提示") { session.notice = nil }
                        }
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(Color(nsColor: OrielPalette.field), in: RoundedRectangle(cornerRadius: 7))
                        .padding(.horizontal, 4).padding(.bottom, 4)
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

    private func sectionHeader<Accessory: View>(_ title: String, detail: String? = nil, back: Bool = false,
                                                @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: back ? 2 : 5) {
            if back {
                icon("chevron.left", "返回正文") { session.section = .reading }
            }
            Text(title).font(.system(size: 12, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 9)).foregroundStyle(OrielPalette.mutedText)
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.leading, back ? 2 : 8).padding(.trailing, 2)
        .frame(height: 26)
    }

    // MARK: Shelf

    private func shelfView(width: CGFloat) -> some View {
        let filter = NovelQuery(query)
        let tight = width < 160
        return VStack(spacing: 0) {
            sectionHeader("书架", detail: library.books.isEmpty ? nil : "\(library.books.count) 本") {
                icon("square.and.arrow.down", "导入 TXT 或 EPUB") { chooseFile(nil) }
            }
            if library.books.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        Image(systemName: "books.vertical").font(.system(size: 26, weight: .light))
                            .foregroundStyle(OrielPalette.mutedText).padding(.bottom, 2)
                        Text("书架还是空的").font(.system(size: 12, weight: .medium))
                        Text("把 TXT 或 EPUB 拖进来，或手动导入").font(.system(size: 10))
                            .foregroundStyle(OrielPalette.mutedText).multilineTextAlignment(.center)
                        Button("导入本地书") { chooseFile(nil) }.foregroundStyle(accent).padding(.top, 3)
                    }.frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            } else {
                if library.books.count > 5 || !query.isEmpty {
                    NovelSearchField(placeholder: "搜书名或作者", text: $query)
                        .padding(.horizontal, 6).padding(.bottom, 4)
                }
                ScrollView {
                    LazyVStack(spacing: 1) {
                        let books = library.recent.filter { filter.matches($0.title + ($0.author ?? "")) }
                        ForEach(books) { book in
                            bookRow(book, tight: tight)
                        }
                        if books.isEmpty {
                            Text("没有匹配的书").font(.system(size: 10))
                                .foregroundStyle(OrielPalette.mutedText).padding(8)
                        }
                    }
                    .padding(.horizontal, 3).padding(.bottom, 4)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            session.openFiles(urls)
            return true
        }
    }

    private func bookRow(_ book: ShelfBook, tight: Bool) -> some View {
        let progress = library.place(for: book.id)
        let detail = progress.updated == nil ? "\(book.chapterCount) 节" : "读到 \(progress.chapter + 1) / \(book.chapterCount)"
        let tint = color(book.id.utf8.reduce(0) { $0 + Int($1) })
        return Button { session.open(book) } label: {
            HStack(spacing: 7) {
                Capsule().fill(tint.opacity(0.5)).frame(width: 3, height: 17)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(detail).font(.system(size: 9.5)).lineLimit(1).foregroundStyle(OrielPalette.mutedText)
                }
                Spacer(minLength: 0)
                if !tight {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(OrielPalette.mutedText.opacity(0.55))
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .novelRow()
        }
        .accessibilityLabel(book.title).accessibilityValue(detail)
        .contextMenu { Button("从书架移除") { removing = book } }
    }

    private func color(_ id: Int) -> Color {
        let colors = [accent, Color(red: 0.52, green: 0.34, blue: 0.32), Color(red: 0.37, green: 0.4, blue: 0.54),
                      Color(red: 0.52, green: 0.42, blue: 0.24)]
        return colors[id % colors.count]
    }

    private var pocketShelf: some View {
        Menu {
            Button("导入 TXT 或 EPUB") { chooseFile(nil) }
            if !library.books.isEmpty {
                Section("书架") { ForEach(library.recent) { book in Button(book.title) { session.open(book) } } }
            }
        } label: {
            Label("选书", systemImage: "books.vertical").padding(3)
        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("选书")
    }

    // MARK: Reading

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
                HStack(spacing: 1) {
                    icon("chevron.left", "返回书架") { session.showShelf() }
                    Spacer(minLength: 0)
                    if compact { icon("list.bullet", "章节目录") { session.section = .contents } }
                    readingMenu(book, index: index, pocket: false, compact: compact)
                }
                .padding(.horizontal, 3)
                .frame(height: 25)
            }
            // Keep the native text view alive across compact layout changes.
            HStack(alignment: .top, spacing: 0) {
                page
                if pocket {
                    readingMenu(book, index: index, pocket: true, compact: true)
                }
            }
            if !pocket && !compact {
                HStack(spacing: 2) {
                    icon("chevron.left", "上一章") { session.turn(to: index - 1) }.disabled(index == 0)
                    Spacer(minLength: 0)
                    Button { session.section = .contents } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "list.bullet").font(.system(size: 9, weight: .medium))
                            Text("\(index + 1) / \(book.chapterCount)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                        }
                        .foregroundStyle(OrielPalette.mutedText)
                        .padding(.horizontal, 9).frame(height: 20)
                        .background(Color(nsColor: OrielPalette.field), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .accessibilityLabel("章节目录").accessibilityValue("\(index + 1) / \(book.chapterCount)")
                    Spacer(minLength: 0)
                    icon("chevron.right", "下一章") { session.turn(to: index + 1) }.disabled(index + 1 == book.chapterCount)
                }
                .padding(.horizontal, 4)
                .frame(height: 24)
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

    // MARK: Bookmarks

    private var bookmarks: some View {
        VStack(spacing: 0) {
            sectionHeader("书签", back: true) {
                icon("bookmark.badge.plus", "收藏当前位置") { session.markHere() }
            }
            if let book = session.book {
                let marks = library.places.marks(for: book.id)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if marks.isEmpty {
                            Button("添加当前位置") { session.markHere() }
                                .foregroundStyle(accent).padding(10)
                        }
                        ForEach(marks) { mark in
                            HStack(spacing: 2) {
                                Button {
                                    session.jump(to: mark.chapter, offset: mark.offset)
                                } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        if session.chapters.indices.contains(mark.chapter) {
                                            Text(session.chapters[mark.chapter].title)
                                                .font(.system(size: 9.5)).foregroundStyle(OrielPalette.mutedText).lineLimit(1)
                                        }
                                        Text(mark.excerpt).font(.system(size: 11.5)).lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 8).padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                icon("minus.circle", "移除书签") { library.removeMark(book: book, mark: mark) }
                                    .opacity(0.75).padding(.trailing, 5)
                            }
                            .novelRow()
                        }
                    }
                    .padding(.horizontal, 3).padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: Contents

    private var contents: some View {
        let filter = NovelQuery(query)
        return VStack(spacing: 0) {
            sectionHeader("目录", back: true) { EmptyView() }
            if session.chapters.count > 8 {
                NovelSearchField(placeholder: "查找章节", text: $query)
                    .padding(.horizontal, 6).padding(.bottom, 4)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let indices = session.chapters.indices.filter { filter.matches(session.chapters[$0].title) }
                        ForEach(indices, id: \.self) { i in
                            Button { session.turn(to: i) } label: {
                                HStack(spacing: 5) {
                                    if i == session.chapter {
                                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(accent)
                                    }
                                    Text(session.chapters[i].title)
                                        .font(.system(size: 11.5, weight: i == session.chapter ? .medium : .regular))
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .novelRow()
                            }.id(i)
                        }
                        if indices.isEmpty {
                            Text("没有匹配的章节").font(.system(size: 10))
                                .foregroundStyle(OrielPalette.mutedText).padding(8)
                        }
                    }
                    .padding(.horizontal, 3).padding(.bottom, 4)
                }.onAppear { proxy.scrollTo(session.chapter, anchor: .center) }
            }
        }
    }
}

/// A pill-shaped search field: no border, the field colour carries the shape.
private struct NovelSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .medium))
                .foregroundStyle(OrielPalette.mutedText)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 11))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        .foregroundStyle(OrielPalette.mutedText)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }.accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 23)
        .background(Color(nsColor: OrielPalette.field), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Rows are grouped by spacing and a rounded hover fill instead of rules.
private struct NovelRowHighlight: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(hovered ? Color(nsColor: OrielPalette.hover).opacity(0.65) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

private extension View {
    func novelRow() -> some View { modifier(NovelRowHighlight()) }
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
            HStack(spacing: 2) {
                Button { session.section = .reading } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }.accessibilityLabel("返回正文")
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(OrielPalette.mutedText)
                    TextField("查找正文", text: $query).textFieldStyle(.plain)
                        .font(.system(size: 11)).focused($focused)
                    if pocket && !query.isEmpty {
                        Menu {
                            if matches.hits.isEmpty { Text(searching ? "正在查找…" : "没有匹配") }
                            ForEach(matches.hits) { hit in
                                Button(hit.excerpt) { session.jump(to: hit.chapter, offset: hit.offset, length: hit.length) }
                            }
                        } label: { Image(systemName: "list.bullet").font(.system(size: 10)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("搜索结果")
                    } else if !query.isEmpty {
                        Button { query = ""; focused = true } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                                .foregroundStyle(OrielPalette.mutedText)
                                .frame(width: 20, height: 20).contentShape(Rectangle())
                        }.accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 23)
                .background(Color(nsColor: OrielPalette.field), in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(.leading, 2).padding(.trailing, 6).padding(.top, 3).padding(.bottom, 3)
            if !pocket {
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
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(matches.hits) { hit in
                    Button {
                        session.jump(to: hit.chapter, offset: hit.offset, length: hit.length)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            if session.chapters.indices.contains(hit.chapter) {
                                Text(session.chapters[hit.chapter].title)
                                    .font(.system(size: 9.5)).foregroundStyle(OrielPalette.mutedText).lineLimit(1)
                            }
                            Text(hit.excerpt).font(.system(size: 11.5)).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .novelRow()
                    }
                }
                if matches.hasMore {
                    Text("前 80 处 · 可继续输入").font(.system(size: 9.5))
                        .foregroundStyle(OrielPalette.mutedText).padding(.horizontal, 9).padding(.vertical, 5)
                }
                if !query.isEmpty && matches.hits.isEmpty {
                    Text(searching ? "正在查找…" : "没有找到匹配的文字").font(.system(size: 11))
                        .foregroundStyle(OrielPalette.mutedText).padding(9)
                }
            }
            .padding(.horizontal, 3).padding(.bottom, 4)
        }
    }
}
