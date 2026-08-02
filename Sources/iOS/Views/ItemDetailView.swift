import SwiftUI
import SwiftData
import ArkyvKit

/// `screen-reference-detail`: full media, source, title, tags, notes, and the
/// move / favorite actions.
struct ItemDetailView: View {
    @Bindable var item: StoredItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var showMovePicker = false
    @State private var noteDraft = ""
    @State private var editingNote = false

    private var repo: Repository { Repository(context: context) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if item.kind.isMedia {
                    LocalImageView(filename: item.localFilename, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                VStack(alignment: .leading, spacing: 16) {
                    if let source = item.sourceURL, !source.isEmpty {
                        Text(source)
                            .font(.arkyvCaption)
                            .foregroundStyle(ArkyvColor.textSecondary)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title ?? defaultTitle)
                            .font(.arkyvTitle)
                            .foregroundStyle(ArkyvColor.textPrimary)
                        Spacer()
                        Text("Saved \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.arkyvCaption)
                            .foregroundStyle(ArkyvColor.textDim)
                    }

                    if !item.tags.isEmpty {
                        FlowTags(tags: item.tags)
                    }

                    Rectangle().fill(ArkyvColor.border).frame(height: 1)

                    notesSection

                    HStack {
                        Button {
                            showMovePicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                Text("Move to...")
                            }
                            .font(ArkyvFont.mono(.medium, size: 15))
                            .foregroundStyle(ArkyvColor.textPrimary)
                        }
                        Spacer()
                        Button {
                            try? repo.toggleFavorite(item)
                        } label: {
                            Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 18))
                                .foregroundStyle(item.isFavorite ? .red : ArkyvColor.textPrimary)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .background(ArkyvColor.background)
        .safeAreaInset(edge: .top) { header }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showMovePicker) {
            MoveToFolderView(item: item)
                .presentationDetents([.medium, .large])
        }
    }

    private var defaultTitle: String {
        switch item.kind {
        case .screenshot: return "Screenshot"
        case .image: return "Image"
        case .note, .text: return "Note"
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left").font(.system(size: 20))
                    Text(item.folder?.name ?? "Back").font(ArkyvFont.mono(.medium, size: 17))
                }
                .foregroundStyle(ArkyvColor.textPrimary)
            }
            Spacer()
            ShareLink(item: shareText) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 20))
                    .foregroundStyle(ArkyvColor.textPrimary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(ArkyvColor.background)
    }

    private var shareText: String {
        item.noteBody ?? item.title ?? item.sourceURL ?? "arkyv capture"
    }

    @ViewBuilder private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTES")
                .font(.arkyvSection)
                .foregroundStyle(ArkyvColor.textSecondary)
            if editingNote {
                TextEditor(text: $noteDraft)
                    .font(.arkyvBody)
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80)
                    .onDisappear(perform: saveNote)
                HStack {
                    Spacer()
                    Button("Done") { editingNote = false; saveNote() }
                        .font(.arkyvCaption)
                        .foregroundStyle(ArkyvColor.textPrimary)
                }
            } else {
                Text(item.noteBody?.isEmpty == false ? item.noteBody! : "Add a note...")
                    .font(.arkyvBody)
                    .foregroundStyle(item.noteBody?.isEmpty == false ? ArkyvColor.textPrimary : ArkyvColor.textDim)
                    .onTapGesture {
                        noteDraft = item.noteBody ?? ""
                        editingNote = true
                    }
            }
        }
    }

    private func saveNote() {
        item.noteBody = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        item.updatedAt = .now
        item.dirty = true
        try? context.save()
    }
}

/// Wrapping tag row.
struct FlowTags: View {
    let tags: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { TagPill(text: $0) }
        }
    }
}

/// Folder picker used by "Move to...".
struct MoveToFolderView: View {
    @Bindable var item: StoredItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<StoredFolder> { !$0.isDeleted },
           sort: \StoredFolder.sortOrder)
    private var folders: [StoredFolder]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(folders) { folder in
                        Button {
                            try? Repository(context: context).move(item, to: folder)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                FolderIconView(icon: folder.icon, size: 18)
                                Text(folder.name).font(.arkyvLabel)
                                    .foregroundStyle(ArkyvColor.textPrimary)
                                Spacer()
                                if folder.id == item.folder?.id {
                                    Image(systemName: "checkmark").foregroundStyle(ArkyvColor.textSecondary)
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .arkyvOutlinedSurface()
                        }
                    }
                }
                .padding(20)
            }
            .background(ArkyvColor.background)
            .navigationTitle("Move to...")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}
