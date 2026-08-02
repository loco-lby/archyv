import SwiftUI
import SwiftData
import PhotosUI
import ArkyvKit

/// The capture drawer (`screen-capture-sheet`). Renders in two modes:
///   • screenshot — a media draft already exists; shows a thumbnail and files
///     on one tap.
///   • add — the in-app entry: a photo picker + note field to stage new content
///     from the library, then file into a folder.
/// The sheet reports its content height back up so the presenter can size the
/// detent to fit exactly (no empty gap, no crop).
struct CaptureSheetView: View {
    let drawer: CaptureCoordinator.Drawer
    @Binding var measuredHeight: CGFloat

    @Environment(CaptureCoordinator.self) private var capture
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<StoredFolder> { !$0.isDeleted },
           sort: [SortDescriptor(\StoredFolder.sortOrder)])
    private var folders: [StoredFolder]

    @State private var note = ""
    @State private var showNewFolder = false
    @State private var pickerItem: PhotosPickerItem?
    /// Photo staged in add-mode: (filename in MediaStore, pixel size).
    @State private var stagedPhoto: (filename: String, size: CGSize)?
    @State private var isLoadingPhoto = false

    private var isAdd: Bool { drawer.isAdd }

    private var title: String {
        if isAdd { return "Add to..." }
        if case .screenshot(let d) = drawer, d.kind.isTextual { return "Save note to..." }
        return "Save to..."
    }

    private var orderedFolders: [StoredFolder] {
        guard let suggested = capture.suggestion else { return folders }
        return [suggested] + folders.filter { $0.id != suggested.id }
    }

    private var recentFolders: [StoredFolder] {
        folders.sorted { $0.updatedAt > $1.updatedAt }.prefix(2).map { $0 }
    }

    /// Something is stageable to save (add-mode needs a photo or note text).
    private var canSave: Bool {
        if isAdd { return stagedPhoto != nil || !note.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ArkyvMarkView(height: 40, color: ArkyvColor.textPrimary)
                    .padding(.top, 20)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.arkyvSheetTitle)
                        .foregroundStyle(ArkyvColor.textPrimary)
                    if let suggested = capture.suggestion, canSave {
                        SuggestionChip(folderName: suggested.name)
                    }
                }

                if isAdd { photoPicker }

                folderGrid

                quickNoteField

                Divider().overlay(ArkyvColor.border)

                recentFoldersRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: DrawerHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(ArkyvColor.background)
        .preferredColorScheme(.dark)
        .onPreferenceChange(DrawerHeightKey.self) { height in
            // Fit the detent to content + home-indicator inset, capped so a huge
            // folder list still scrolls rather than exceeding the screen.
            measuredHeight = min(height + 28, 760)
        }
        .task(id: pickerItem) { await loadPickedPhoto() }
        .sheet(isPresented: $showNewFolder) {
            NewFolderView { name, icon in
                capture.createFolderAndFile(effectiveDraft(), name: name, icon: icon)
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: Add-mode photo picker

    private var photoPicker: some View {
        Group {
            if let staged = stagedPhoto {
                ZStack(alignment: .topTrailing) {
                    LocalImageView(filename: staged.filename, contentMode: .fill)
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: ArkyvRadius.card))
                    Button {
                        MediaStore.shared.delete(filename: staged.filename)
                        stagedPhoto = nil
                        pickerItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white, .black.opacity(0.5))
                            .padding(8)
                    }
                }
            } else {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    HStack(spacing: 10) {
                        if isLoadingPhoto {
                            ProgressView().tint(ArkyvColor.textSecondary)
                        } else {
                            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 18))
                        }
                        Text(isLoadingPhoto ? "Loading..." : "Choose from library")
                            .font(.arkyvLabel)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .arkyvOutlinedSurface()
                }
            }
        }
    }

    // MARK: Folder grid

    private var folderGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(orderedFolders) { folder in
                folderButton(folder)
            }
            newFolderButton
        }
    }

    private func folderButton(_ folder: StoredFolder) -> some View {
        let isSuggested = folder.id == capture.suggestion?.id && canSave
        return Button {
            guard canSave else { return }
            capture.file(effectiveDraft(), into: folder)
        } label: {
            HStack(spacing: 8) {
                FolderIconView(icon: folder.icon, size: 18)
                Text(folder.name)
                    .font(.arkyvLabel)
                    .foregroundStyle(ArkyvColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .arkyvOutlinedSurface(
                fill: isSuggested ? ArkyvColor.surface : ArkyvColor.card,
                stroke: isSuggested ? ArkyvColor.textPrimary : ArkyvColor.border,
                lineWidth: isSuggested ? 1.5 : 1
            )
        }
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.5)
    }

    private var newFolderButton: some View {
        Button {
            showNewFolder = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 16))
                Text("New Folder").font(.arkyvLabel)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ArkyvColor.textDim)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!canSave && isAdd)
        .opacity((!canSave && isAdd) ? 0.5 : 1)
    }

    private var quickNoteField: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.cursor").foregroundStyle(ArkyvColor.textDim).font(.system(size: 13))
            TextField(
                isAdd ? "Add a note (optional)..." : "Add note...",
                text: $note,
                axis: .vertical
            )
            .font(.arkyvBody)
            .foregroundStyle(ArkyvColor.textPrimary)
            .lineLimit(1...3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .arkyvOutlinedSurface(fill: ArkyvColor.card, stroke: ArkyvColor.border)
    }

    private var recentFoldersRow: some View {
        HStack {
            Text("RECENT FOLDERS")
                .font(.arkyvSection)
                .foregroundStyle(ArkyvColor.textSecondary)
            Spacer()
            HStack(spacing: 12) {
                ForEach(recentFolders) { folder in
                    Button(folder.name) {
                        guard canSave else { return }
                        capture.file(effectiveDraft(), into: folder)
                    }
                    .font(ArkyvFont.sans(size: 13, weight: .medium))
                    .foregroundStyle(canSave ? ArkyvColor.textSecondary : ArkyvColor.textDim)
                    .disabled(!canSave)
                }
            }
        }
    }

    // MARK: Draft assembly

    /// Builds the draft to file from the current mode + staged content.
    private func effectiveDraft() -> CaptureDraft {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? nil : trimmed

        switch drawer {
        case .screenshot(var draft):
            draft.noteBody = body ?? draft.noteBody
            return draft
        case .add:
            if let staged = stagedPhoto {
                return CaptureDraft(
                    kind: .image,
                    localFilename: staged.filename,
                    pixelSize: staged.size,
                    noteBody: body,
                    sourceDevice: .iOS
                )
            }
            return CaptureDraft(kind: .note, noteBody: body, sourceDevice: .iOS)
        }
    }

    private func loadPickedPhoto() async {
        guard let pickerItem else { return }
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        guard let data = try? await pickerItem.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let saved = try? MediaStore.shared.save(image: image) else { return }
        stagedPhoto = (saved.filename, saved.size)
        capture.refreshSuggestion(for: CaptureDraft(kind: .image, localFilename: saved.filename))
    }
}

/// Reports the drawer's content height so the presenter can fit the detent.
private struct DrawerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
