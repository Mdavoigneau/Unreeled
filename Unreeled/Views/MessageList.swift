import SwiftUI
import UIKit

/// What a message's row can ask for. The conversation's screen answers.
struct MessageHandlers {
    /// The list is near its top, with older messages to load.
    var reachedTop: () -> Void = {}
    var open: (MediaItem) -> Void = { _ in }
    var handOff: (DirectMessage) -> Void = { _ in }
    var heart: (DirectMessage) -> Void = { _ in }
    var retry: (DirectMessage) -> Void = { _ in }
    var navigate: (Route) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    /// For a message the app can't show yet: the conversation on the website.
    var showOnWebsite: () -> Void = {}
}

/// The handlers as the rows hold them: one object for the life of the list, so that new closures
/// from the screen reach the rows already made without remaking them.
@MainActor
final class MessageActions {
    var handlers = MessageHandlers()
}

/// A conversation's messages, oldest to newest, with the field to answer under them.
///
/// The list is a collection view. Rows are made as they scroll in and reused as they leave; the
/// list stays exactly where it is when older messages come in above or a row changes height;
/// and the field sits on the keyboard, which a drag down from the field pulls away under the
/// finger. The rows and the field are SwiftUI views.
struct MessageList: UIViewControllerRepresentable {
    let rows: [ConversationModel.Row]
    /// Older messages exist above the first row.
    let hasOlder: Bool
    let voice: VoicePlayer
    /// The field under the list, with all it needs from the environment already in it.
    let composer: AnyView
    let handlers: MessageHandlers

    func makeUIViewController(context: Context) -> MessageListController {
        MessageListController(voice: voice, composer: composer)
    }

    func updateUIViewController(_ controller: MessageListController, context: Context) {
        controller.actions.handlers = handlers
        controller.show(rows, hasOlder: hasOlder)
    }
}

@MainActor
final class MessageListController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    let actions = MessageActions()

    private static let older = "older messages"
    /// Close enough to the top to ask for older messages, before the top itself comes into view.
    private static let nearTop: CGFloat = 400

    private let voice: VoicePlayer
    private let composer: UIHostingController<AnyView>
    private var composerHeight: NSLayoutConstraint?
    private let layout = MessageListLayout.column()
    private lazy var list = MessageCollectionView(frame: .zero, collectionViewLayout: layout)
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
    private var rows: [ConversationModel.Row] = []
    private var rowsByID: [String: ConversationModel.Row] = [:]
    private var hasOlder = false
    private var width: CGFloat = 0
    /// What's on screen before the list is resized, to find again after.
    private var held: (id: String, top: CGFloat)?

    init(voice: VoicePlayer, composer: AnyView) {
        self.voice = voice
        self.composer = UIHostingController(rootView: AnyView(EmptyView()))
        super.init(nibName: nil, bundle: nil)
        // As tall as the field wants to be at the width it gets, which it says each time that
        // changes: a line more of text, the recording bar in place of the field.
        self.composer.rootView = AnyView(
            composer
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                    self?.composerResized(to: height)
                }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not made from a storyboard")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        list.backgroundColor = .white
        list.delegate = self
        list.prefetchDataSource = self
        list.allowsSelection = false
        list.alwaysBounceVertical = true
        // The field and the keyboard are this screen's to make room for, not the system's.
        list.contentInsetAdjustmentBehavior = .never
        list.automaticallyAdjustsScrollIndicatorInsets = false
        list.keyboardDismissMode = .interactive
        list.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(list)

        // White from the field down to the bottom of the screen, whatever is behind.
        let under = UIView()
        under.backgroundColor = .white
        under.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(under)

        addChild(composer)
        composer.view.backgroundColor = .white
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        // The field is placed on the keyboard by this screen: it isn't to move itself out of the
        // keyboard's way as well.
        composer.safeAreaRegions = []
        view.addSubview(composer.view)
        composer.didMove(toParent: self)

        let height = composer.view.heightAnchor.constraint(equalToConstant: 54)
        composerHeight = height
        let sides = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: view.topAnchor),
            // Down to the safe part of the screen and no further. A row in the strip under it
            // (the home indicator's) would be told to keep its content out of that strip, and
            // ask to be taller for it: taller, it reaches further in, and asks again, without end.
            list.bottomAnchor.constraint(equalTo: sides.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: sides.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: sides.trailingAnchor),
            composer.view.leadingAnchor.constraint(equalTo: sides.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: sides.trailingAnchor),
            // On the keyboard when there is one, on the bottom of the screen's safe part otherwise;
            // and with the keyboard as a drag pulls it down.
            composer.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            height,
            under.topAnchor.constraint(equalTo: composer.view.topAnchor),
            under.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            under.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            under.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let row = UICollectionView.CellRegistration<MessageCell, String> { [unowned self] cell, _, id in
            guard let row = rowsByID[id] else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                // Under the row's own ID: a cell used again for another message starts that
                // message's row afresh, with nothing of the last one's left in it.
                MessageRow(row: row, actions: actions, voice: voice)
                    .environment(cell.display)
                    .id(row.id)
            }
            .margins(.all, 0)
        }
        let spinner = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration {
                ProgressView().frame(maxWidth: .infinity).padding(12)
            }
            .margins(.all, 0)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: list) { list, place, id in
            id == Self.older
                ? list.dequeueConfiguredReusableCell(using: spinner, for: place, item: id)
                : list.dequeueConfiguredReusableCell(using: row, for: place, item: id)
        }
        apply(rows, hasOlder: hasOlder, before: [:])
        #if DEBUG
        // The scripted scroll (-standInScroll YES) moves the list as a finger would: off the end.
        ScrollScript.releaseFromEnd = { ($0 as? MessageCollectionView)?.endDistance = nil }
        #endif
    }

    // MARK: Rows

    /// Shows these rows. What's on screen stays where it is, whatever came in above it or
    /// changed around it; at the end of the conversation, the list stays at the end, and goes
    /// there for a new message when it's yours or you were already there.
    func show(_ rows: [ConversationModel.Row], hasOlder: Bool) {
        guard rows != self.rows || hasOlder != self.hasOlder else { return }
        let before = rowsByID
        let wasEmpty = self.rows.isEmpty
        let newLast = rows.last.map { before[$0.id] == nil } ?? false
        self.rows = rows
        self.hasOlder = hasOlder
        rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard isViewLoaded else { return }

        // A new last message, yours or with the list at the end: the list goes to it. It's laid
        // out under what's on screen first, then scrolled up into view.
        let follows = !wasEmpty && newLast && (list.endDistance != nil || rows.last?.isMine == true)
        #if DEBUG
        let watched = firstRowOnScreen()
        #endif
        if wasEmpty { list.endDistance = 0 }
        // What stays where it is through the change: the layout is told first, so that it
        // lands there straight away; then it's checked, and put right if it didn't.
        let held = wasEmpty || follows ? nil : hold()
        // On its way to the end from here on: laying the new row out doesn't put the list
        // there at once, the scroll does.
        if follows { list.isFollowing = true }
        apply(rows, hasOlder: hasOlder, before: before)
        layout.held = nil
        layout.heldFromEnd = nil
        list.layoutIfNeeded()
        if let held { keep(held) }
        if follows { list.follow() }
        #if DEBUG
        logMove(of: watched, rowsBefore: before.count)
        #endif
        askForOlderIfNearTop()
    }

    #if DEBUG
    /// -listMoves YES: after each change to the rows, how far the first row that was on screen
    /// moved on screen, in points. Anything but zero, with the list away from its end, is a jump.
    private func logMove(of watched: (id: String, top: CGFloat)?, rowsBefore: Int) {
        guard UserDefaults.standard.bool(forKey: "listMoves"), let watched, let place = place(ofRow: watched.id),
              let frame = list.layoutAttributesForItem(at: place)?.frame
        else { return }
        NetworkRecorder.append(["time": Date().ISO8601Format(), "listMove": [
            "moved": Double(((frame.minY - list.contentOffset.y - watched.top) * 10).rounded() / 10),
            "rows": [rowsBefore, rows.count], "atEnd": list.endDistance != nil, "byFinger": list.isMovedByFinger,
            "layoutAsked": layout.asked,
        ] as [String: Any]])
        layout.asked = 0
    }
    #endif

    private func apply(_ rows: [ConversationModel.Row], hasOlder: Bool, before: [String: ConversationModel.Row]) {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        // Each row once: the list can't hold two under one ID.
        var seen = Set<String>()
        let ids = rows.map(\.id).filter { seen.insert($0).inserted }
        snapshot.appendItems((hasOlder ? [Self.older] : []) + ids)
        // Only the rows that show something else than before are made again.
        snapshot.reconfigureItems(ids.filter { id in before[id].map { $0 != rowsByID[id] } ?? false })
        if before.isEmpty {
            dataSource.applySnapshotUsingReloadData(snapshot)
        } else {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    /// What to keep in place through a change: the distance to the end of the conversation
    /// while the list is there, a row's place on screen otherwise.
    private enum Held {
        case end(CGFloat)
        case row(id: String, top: CGFloat)
    }

    /// Notes what's to stay in place through the change about to be made, and tells the layout.
    private func hold() -> Held? {
        if let distance = list.endDistance {
            layout.heldFromEnd = distance
            return .end(distance)
        }
        guard let first = firstRowOnScreen() else { return nil }
        if let place = place(ofRow: first.id) { layout.held = (place, first.top) }
        return .row(id: first.id, top: first.top)
    }

    /// Puts what was held back where it was, if the change moved it.
    private func keep(_ held: Held) {
        let top = -list.adjustedContentInset.top
        let wanted: CGFloat
        switch held {
        case .end(let distance):
            wanted = max(list.endOffset - distance, top)
        case .row(let id, let rowTop):
            guard let place = place(ofRow: id), let frame = list.layoutAttributesForItem(at: place)?.frame else { return }
            wanted = max(frame.minY - rowTop, top)
        }
        guard abs(list.contentOffset.y - wanted) > 0.5 else { return }
        list.contentOffset.y = wanted
        list.layoutIfNeeded()
    }

    /// Where a row is in the list, as the rows are now.
    private func place(ofRow id: String) -> IndexPath? {
        rows.firstIndex { $0.id == id }.map { IndexPath(item: $0 + (hasOlder ? 1 : 0), section: 0) }
    }

    /// The first row on screen that the new rows still have, and how far its top is under the list's.
    private func firstRowOnScreen() -> (id: String, top: CGFloat)? {
        let top = list.contentOffset.y + list.adjustedContentInset.top
        for place in list.indexPathsForVisibleItems.sorted() {
            guard let id = dataSource?.itemIdentifier(for: place), rowsByID[id] != nil,
                  let frame = list.layoutAttributesForItem(at: place)?.frame, frame.maxY > top
            else { continue }
            return (id, frame.minY - list.contentOffset.y)
        }
        return nil
    }

    private func askForOlderIfNearTop() {
        guard hasOlder, list.contentOffset.y + list.adjustedContentInset.top < Self.nearTop else { return }
        actions.handlers.reachedTop()
    }

    // MARK: Layout

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Before a new width reaches the list (a turn of the phone): what's on screen now.
        if list.endDistance == nil, list.bounds.width == width { held = firstRowOnScreen() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The room the field and the keyboard take at the bottom of the list. A drag that pulls
        // the keyboard down starts at the top of the field, not of the keyboard.
        list.setFooter(max(list.frame.maxY - composer.view.frame.minY, 0))
        view.keyboardLayoutGuide.keyboardDismissPadding = composer.view.bounds.height
        if list.bounds.width != width {
            // Every row is another height at another width: back to what was on screen.
            let turned = width > 0
            width = list.bounds.width
            list.layoutIfNeeded()
            if turned, list.endDistance == nil, let held { keep(.row(id: held.id, top: held.top)) }
        }
        list.layoutIfNeeded()
    }

    private func composerResized(to height: CGFloat) {
        guard height > 0, let composerHeight, abs(composerHeight.constant - height) > 0.5 else { return }
        composerHeight.constant = height
        view.setNeedsLayout()
    }

    // MARK: Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Where your own scrolling leaves the list is where it stays: at the end, or near it,
        // or further up.
        if list.isMovedByFinger {
            let distance = list.distanceFromEnd
            list.endDistance = distance <= MessageCollectionView.nearEnd ? max(distance, 0) : nil
        }
        askForOlderIfNearTop()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        list.isFollowing = false
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        list.isFollowing = false
        list.setNeedsLayout()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        list.setNeedsLayout()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { list.setNeedsLayout() }
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        list.endDistance = nil
        askForOlderIfNearTop()
    }

    // MARK: Cells

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? MessageCell)?.display.isShown = true
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? MessageCell)?.display.isShown = false
    }

    /// Rows about to scroll in: their pictures are read ahead, at the size they show at.
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let pictures = indexPaths
            .compactMap { dataSource?.itemIdentifier(for: $0) }
            .compactMap { rowsByID[$0] }
            .flatMap { MessageRow.pictures(in: $0) }
        ImageCache.shared.prefetch(pictures, decode: true, fitting: MessageRow.largestPicture)
    }
}

/// A plain column of rows, each as tall as its content, which keeps its place through a change:
/// the list says what to hold before the change, and this puts it back where it was, before
/// anything is drawn.
final class MessageListLayout: UICollectionViewCompositionalLayout {
    /// A row to keep where it is, by its place after the change, and how far its top is under
    /// the list's.
    var held: (item: IndexPath, top: CGFloat)?
    /// Or the distance to the end of the list, to keep.
    var heldFromEnd: CGFloat?

    static func column() -> MessageListLayout {
        // A guess, until a row has been measured: on the tall side, so the first look measures
        // no more rows than fit.
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(90))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 3
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        // The list is already inside the safe part of the screen, sideways; under it, the field is.
        section.contentInsetsReference = .none
        return MessageListLayout(section: section)
    }

    #if DEBUG
    /// Times the list asked where to be, since last read (-listMoves YES).
    var asked = 0
    #endif

    override func targetContentOffset(forProposedContentOffset proposed: CGPoint) -> CGPoint {
        #if DEBUG
        if held != nil || heldFromEnd != nil { asked += 1 }
        #endif
        guard let list = collectionView else { return proposed }
        let top = -list.adjustedContentInset.top
        if let heldFromEnd {
            let end = max(collectionViewContentSize.height + list.adjustedContentInset.bottom - list.bounds.height, top)
            return CGPoint(x: proposed.x, y: max(end - heldFromEnd, top))
        }
        if let held, let frame = layoutAttributesForItem(at: held.item)?.frame {
            return CGPoint(x: proposed.x, y: max(frame.minY - held.top, top))
        }
        return super.targetContentOffset(forProposedContentOffset: proposed)
    }
}

/// The list of messages: a collection view that stays at the end of the conversation while
/// it's there, as rows change, as the field grows and as the keyboard comes and goes, and that
/// sits a short conversation at the bottom, above the field.
final class MessageCollectionView: UICollectionView {
    /// Within this of the end, the list counts as at the end: a new message scrolls into view.
    static let nearEnd: CGFloat = 80

    /// How far from the end the list stays, whatever changes, while it's at the end or near it.
    /// Nil further up: there, what's on screen stays where it is.
    var endDistance: CGFloat? = 0
    /// The list is on its way to the end, for a new message: it isn't put there at once meanwhile.
    var isFollowing = false {
        didSet { if !isFollowing { isScrollingToEnd = false } }
    }
    /// The animated scroll there has started.
    private var isScrollingToEnd = false
    private var followTarget: CGFloat = 0
    /// The room the field and the keyboard take at the bottom.
    private var footer: CGFloat = 0

    var isMovedByFinger: Bool { isTracking || isDragging || isDecelerating }

    var distanceFromEnd: CGFloat {
        contentSize.height + adjustedContentInset.bottom - contentOffset.y - bounds.height
    }

    /// Where the list is when it shows its last row just above the field.
    var endOffset: CGFloat {
        max(contentSize.height + adjustedContentInset.bottom - bounds.height, -adjustedContentInset.top)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A conversation shorter than the screen sits at the bottom, above the field.
        let spare = max(bounds.height - footer - contentSize.height, 0)
        if abs(contentInset.top - spare) > 0.5 { contentInset.top = spare }
        if isFollowing {
            // The end moved while the list was on its way there (a row measured): on to the new end.
            if isScrollingToEnd, abs(endOffset - followTarget) > 0.5 { follow() }
            return
        }
        guard !isMovedByFinger else { return }
        let top = -adjustedContentInset.top
        // At the end: still there. Further up: where it was, within the list's bounds.
        let place = endDistance.map { max(endOffset - $0, top) } ?? min(max(contentOffset.y, top), endOffset)
        if abs(contentOffset.y - place) > 0.5 { contentOffset.y = place }
    }

    /// Scrolls to the end of the conversation, and stays there.
    func follow() {
        endDistance = 0
        followTarget = endOffset
        guard abs(followTarget - contentOffset.y) > 0.5 else { return isFollowing = false }
        isFollowing = true
        isScrollingToEnd = true
        setContentOffset(CGPoint(x: contentOffset.x, y: followTarget), animated: true)
    }

    func setFooter(_ height: CGFloat) {
        guard abs(height - footer) > 0.5 else { return }
        let change = height - footer
        footer = height
        contentInset.bottom = height
        verticalScrollIndicatorInsets.bottom = height
        // Further up the conversation, what was just above the field stays just above it, as
        // in Messages. Not while a finger moves the list: then the keyboard follows the finger.
        #if DEBUG
        let before = contentOffset.y
        #endif
        if endDistance == nil, !isMovedByFinger {
            contentOffset.y = min(max(contentOffset.y + change, -adjustedContentInset.top), endOffset)
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "listMoves") {
            NetworkRecorder.append(["time": Date().ISO8601Format(), "listFooter": [
                "footer": Double(height), "change": Double(change), "offset": [Double(before), Double(contentOffset.y)],
                "end": Double(endOffset), "atEnd": endDistance != nil, "byFinger": isMovedByFinger,
            ] as [String: Any]])
        }
        #endif
        setNeedsLayout()
    }
}

/// Whether a row is on screen, for what should stop when it isn't (a GIF's loop): a cell that
/// scrolled away stays alive, waiting to be used again.
@MainActor
@Observable
final class CellDisplay {
    var isShown = true
}

final class MessageCell: UICollectionViewCell {
    let display = CellDisplay()
}
