import SwiftUI
import UIKit

struct ParameterGridItem: Equatable, Identifiable {
    let id: String
    var isDraggable: Bool = true
    var fullWidth: Bool = false

    init(id: String, isDraggable: Bool = true, fullWidth: Bool = false) {
        self.id = id
        self.isDraggable = isDraggable
        self.fullWidth = fullWidth
    }
}

struct ParameterGridSection: Identifiable {
    let id: String
    let title: String?
    let items: [ParameterGridItem]

    init(id: String, title: String? = nil, items: [ParameterGridItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// Owns the page's single vertical scroll surface. IDs must be globally unique.
/// Callers own the model, permission rules and same-section removal offset.
struct NativeParameterGrid: UIViewRepresentable {
    var sections: [ParameterGridSection]
    var isEditing: Bool
    var usesSingleColumn: Bool
    var accessibilityIdentifier: String
    var content: (String) -> AnyView
    var canMove: (String, String) -> Bool
    var onMove: (String, String, Int) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    // Explicit init keeps the agreed memberwise API independent of environment storage.
    init(
        sections: [ParameterGridSection],
        isEditing: Bool,
        usesSingleColumn: Bool,
        accessibilityIdentifier: String,
        content: @escaping (String) -> AnyView,
        canMove: @escaping (String, String) -> Bool,
        onMove: @escaping (String, String, Int) -> Void
    ) {
        self.sections = sections
        self.isEditing = isEditing
        self.usesSingleColumn = usesSingleColumn
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content
        self.canMove = canMove
        self.onMove = onMove
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        let layout = UICollectionViewCompositionalLayout { [weak coordinator] index, environment in
            coordinator?.layoutSection(at: index, environment: environment)
        }
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.alwaysBounceVertical = true
        collectionView.dragInteractionEnabled = isEditing
        collectionView.dragDelegate = coordinator
        collectionView.dropDelegate = coordinator
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Coordinator.cellID)
        collectionView.register(ParameterGridHeader.self,
                                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: Coordinator.headerID)
        coordinator.install(in: collectionView)
        return collectionView
    }

    func updateUIView(_ uiView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh(in: uiView)
    }

    final class Coordinator: NSObject, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        fileprivate static let cellID = "parameter-grid.cell"
        fileprivate static let headerID = "parameter-grid.header"

        // A run of compact cards or one full-width card. The anchor is a layout ID,
        // not an ordinal, so telemetry updates never change snapshot identities.
        private struct LayoutID: Hashable {
            let sectionID: String
            let anchorID: String?
        }

        private struct LayoutSection {
            let id: LayoutID
            let items: [String]
            let fullWidth: Bool
            let showsHeader: Bool
        }

        private struct Structure: Equatable {
            let id: String
            let hasTitle: Bool
            let items: [ParameterGridItem]
        }

        private final class DragToken {
            weak var owner: Coordinator?
            let cardID: String
            let layoutID = UUID().uuidString
            var committed = false

            init(owner: Coordinator, cardID: String) {
                self.owner = owner
                self.cardID = cardID
            }
        }

        private struct Destination {
            let sectionID: String
            let index: Int
        }

        fileprivate var parent: NativeParameterGrid
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<LayoutID, String>?
        private var layoutSections: [LayoutSection] = []
        private var structure: [Structure]?
        private var singleColumn = false
        private var activeDrag: DragToken?

        fileprivate init(parent: NativeParameterGrid) { self.parent = parent }

        fileprivate func install(in collectionView: UICollectionView) {
            self.collectionView = collectionView
            let source = UICollectionViewDiffableDataSource<LayoutID, String>(collectionView: collectionView) {
                [weak self] collectionView, indexPath, id in
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.cellID, for: indexPath)
                self?.configure(cell, id: id)
                return cell
            }
            source.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
                guard let self, kind == UICollectionView.elementKindSectionHeader else { return nil }
                let header = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind, withReuseIdentifier: Self.headerID, for: indexPath
                )
                if let header = header as? ParameterGridHeader {
                    self.configure(header, at: indexPath.section)
                }
                return header
            }
            // No diffable reorderingHandlers: every successful move must use onMove.
            dataSource = source
            refresh(in: collectionView)
        }

        fileprivate func refresh(in collectionView: UICollectionView) {
            collectionView.accessibilityIdentifier = parent.accessibilityIdentifier
            collectionView.dragInteractionEnabled = parent.isEditing
            // Keep other visible cards live, including freshness/error transitions.
            // Only the lifted card's host and structural/layout work wait for drag end;
            // UIKit owns the lifted preview snapshot, not a frozen page of telemetry.
            // Live text may naturally self-size; no manual layout invalidation here.
            if activeDrag != nil {
                refreshVisibleContent(in: collectionView)
                return
            }
            collectionView.semanticContentAttribute = parent.layoutDirection == .rightToLeft
                ? .forceRightToLeft : .forceLeftToRight
            let newSingleColumn = parent.usesSingleColumn || parent.dynamicTypeSize >= .xxxLarge
            let columnChanged = singleColumn != newSingleColumn
            singleColumn = newSingleColumn
            let newStructure = parent.sections.map {
                Structure(id: $0.id, hasTitle: $0.title != nil, items: $0.items)
            }
            if newStructure != structure {
                structure = newStructure
                layoutSections = makeLayoutSections()
                // Width flags/header presence can change without changing diffable IDs.
                collectionView.collectionViewLayout.invalidateLayout()
                var snapshot = NSDiffableDataSourceSnapshot<LayoutID, String>()
                for section in layoutSections {
                    snapshot.appendSections([section.id])
                    snapshot.appendItems(section.items, toSection: section.id)
                }
                // Estimated heights + no diff animations also honour Reduce Motion.
                dataSource?.apply(snapshot, animatingDifferences: false) { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return }
                    self.refreshVisibleContent(in: collectionView)
                }
            } else {
                // No reloadData/reloadItems/reconfigure snapshot on telemetry ticks.
                refreshVisibleContent(in: collectionView)
            }
            if columnChanged { collectionView.collectionViewLayout.invalidateLayout() }
        }

        private func makeLayoutSections() -> [LayoutSection] {
            var result: [LayoutSection] = []
            for section in parent.sections {
                if section.items.isEmpty {
                    result.append(LayoutSection(id: LayoutID(sectionID: section.id, anchorID: nil),
                                                items: [], fullWidth: true, showsHeader: true))
                    continue
                }
                var cursor = 0
                while cursor < section.items.count {
                    let start = cursor
                    let fullWidth = section.items[start].fullWidth
                    cursor += 1
                    if !fullWidth {
                        while cursor < section.items.count && !section.items[cursor].fullWidth { cursor += 1 }
                    }
                    result.append(LayoutSection(
                        id: LayoutID(sectionID: section.id, anchorID: section.items[start].id),
                        items: section.items[start..<cursor].map(\.id),
                        fullWidth: fullWidth, showsHeader: start == 0
                    ))
                }
            }
            return result
        }

        fileprivate func layoutSection(at index: Int, environment: NSCollectionLayoutEnvironment)
            -> NSCollectionLayoutSection? {
            guard layoutSections.indices.contains(index) else { return nil }
            let row = layoutSections[index]
            let largeType = environment.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
                || environment.traitCollection.preferredContentSizeCategory == .extraExtraExtraLarge
            let width = environment.container.effectiveContentSize.width
            let columns = row.fullWidth || singleColumn || largeType ? 1 : (width >= 700 ? 3 : 2)
            // repeatingSubitem 不替调用方均分 item 宽度；显式扣除 section
            // 左右内边距与列间距，避免 2/3 个整组宽度的 item 越出可见区。
            let availableWidth = max(1, width - 32)
            let itemWidth = max(1, (availableWidth - CGFloat(columns - 1) * 8) / CGFloat(columns))
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .absolute(itemWidth), heightDimension: .estimated(100)
            ))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                  heightDimension: .estimated(100)),
                repeatingSubitem: item, count: columns
            )
            group.interItemSpacing = .fixed(8)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 8
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            // Use the applied structure, not pending model edits, during a drag.
            let hasTitle = structure?.first(where: { $0.id == row.id.sectionID })?.hasTitle == true
            if row.showsHeader && (hasTitle || row.items.isEmpty) {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                                      heightDimension: .estimated(44)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top
                )
                header.pinToVisibleBounds = false
                section.boundarySupplementaryItems = [header]
            }
            return section
        }

        private func hosted(_ view: AnyView) -> AnyView {
            AnyView(view
                .environment(\.dynamicTypeSize, parent.dynamicTypeSize)
                .environment(\.colorScheme, parent.colorScheme)
                .environment(\.layoutDirection, parent.layoutDirection)
                .environment(\.accessibilityReduceMotion, parent.reduceMotion)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                })
        }

        private func configure(_ cell: UICollectionViewCell, id: String) {
            cell.backgroundColor = .clear
            cell.isAccessibilityElement = false
            cell.contentConfiguration = UIHostingConfiguration { hosted(parent.content(id)) }
                .margins(.all, 0)
                .minSize(width: 0, height: 0)
            // Do not mark the cell as one accessibility element: hosted buttons survive.
        }

        private func configure(_ header: ParameterGridHeader, at index: Int) {
            guard layoutSections.indices.contains(index) else { return }
            let row = layoutSections[index]
            let title = parent.sections.first(where: { $0.id == row.id.sectionID })?.title
            let view = AnyView(Text(title ?? "")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: title == nil ? 44 : 0, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHidden(title == nil))
            header.setContent(UIHostingConfiguration { hosted(view) }
                .margins(.all, 0)
                .minSize(width: 0, height: 0))
        }

        private func refreshVisibleContent(in collectionView: UICollectionView) {
            // The applied snapshot may still contain IDs removed by a pending edit.
            // Never ask the newest content closure to render a no-longer-existing ID.
            let currentIDs = Set(parent.sections.flatMap { $0.items.map(\.id) })
            for indexPath in collectionView.indexPathsForVisibleItems {
                if let id = dataSource?.itemIdentifier(for: indexPath),
                   id != activeDrag?.cardID, currentIDs.contains(id),
                   let cell = collectionView.cellForItem(at: indexPath) {
                    configure(cell, id: id)
                }
            }
            // Header geometry belongs to the deferred structure, not live telemetry.
            guard activeDrag == nil else { return }
            for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(
                ofKind: UICollectionView.elementKindSectionHeader
            ) {
                if let header = collectionView.supplementaryView(
                    forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath
                ) as? ParameterGridHeader { configure(header, at: indexPath.section) }
            }
        }

        func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                            at indexPath: IndexPath) -> [UIDragItem] {
            guard parent.isEditing, activeDrag == nil,
                  let id = dataSource?.itemIdentifier(for: indexPath),
                  parent.sections.contains(where: { $0.items.contains(where: { $0.id == id && $0.isDraggable }) })
            else { return [] }
            let token = DragToken(owner: self, cardID: id)
            // Export ONLY an opaque, transient layout ID, never hosted content/telemetry.
            let dragItem = UIDragItem(itemProvider: NSItemProvider(object: token.layoutID as NSString))
            dragItem.localObject = token
            session.localContext = token
            activeDrag = token
            return [dragItem]
        }

        func collectionView(_ collectionView: UICollectionView, itemsForAddingTo session: UIDragSession,
                            at indexPath: IndexPath, point: CGPoint) -> [UIDragItem] { [] }

        func collectionView(_ collectionView: UICollectionView,
                            dragSessionAllowsMoveOperation session: UIDragSession) -> Bool { parent.isEditing }

        func collectionView(_ collectionView: UICollectionView,
                            dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }

        func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
            activeDrag = nil
            refresh(in: collectionView)
        }

        private func localToken(for session: UIDropSession) -> DragToken? {
            guard parent.isEditing, session.items.count == 1,
                  let token = session.localDragSession?.localContext as? DragToken,
                  token.owner === self, token === activeDrag, !token.committed,
                  let itemToken = session.items.first?.localObject as? DragToken, itemToken === token,
                  parent.sections.contains(where: {
                      $0.items.contains(where: { $0.id == token.cardID && $0.isDraggable })
                  }) else { return nil }
            return token
        }

        func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
            localToken(for: session) != nil
        }

        func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                            withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
            guard let token = localToken(for: session),
                  let destination = destination(at: destinationIndexPath, session: session, in: collectionView),
                  parent.canMove(token.cardID, destination.sectionID)
            else { return UICollectionViewDropProposal(operation: .forbidden) }
            return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }

        func collectionView(_ collectionView: UICollectionView,
                            performDropWith coordinator: UICollectionViewDropCoordinator) {
            guard let token = localToken(for: coordinator.session), coordinator.items.count == 1,
                  let item = coordinator.items.first, item.sourceIndexPath != nil,
                  let itemToken = item.dragItem.localObject as? DragToken, itemToken === token,
                  let destination = destination(at: coordinator.destinationIndexPath,
                                                session: coordinator.session, in: collectionView),
                  parent.canMove(token.cardID, destination.sectionID) else { return }
            token.committed = true
            // Animate a local preview, not replacement/import or speculative model mutation.
            let target = UIDragPreviewTarget(container: collectionView,
                                             center: coordinator.session.location(in: collectionView))
            coordinator.drop(item.dragItem, to: target)
            if let source = parent.sections.first(where: { $0.id == destination.sectionID }),
               let sourceIndex = source.items.filter(\.isDraggable).firstIndex(where: { $0.id == token.cardID }),
               destination.index == sourceIndex || destination.index == sourceIndex + 1 {
                return // Same position: leave the model untouched.
            }
            // Original PARAMETER array insertion boundary, before removing the source.
            // The caller corrects the offset for a forward move within the same section.
            parent.onMove(token.cardID, destination.sectionID, destination.index)
        }

        private func destination(at suggested: IndexPath?, session: UIDropSession,
                                 in collectionView: UICollectionView) -> Destination? {
            if let suggested { return destination(at: suggested) }
            // UIKit may supply nil over headers/gaps/empty groups. Use visible layout
            // geometry, including the empty header, rather than silently selecting the last group.
            let point = session.location(in: collectionView)
            let attributes = collectionView.collectionViewLayout.layoutAttributesForElements(in: collectionView.bounds) ?? []
            let candidates = attributes.filter {
                $0.representedElementCategory == .cell
                    || $0.representedElementKind == UICollectionView.elementKindSectionHeader
            }
            guard let nearest = candidates.min(by: { distance(point, to: $0.frame) < distance(point, to: $1.frame) })
            else { return nil }
            if nearest.representedElementCategory != .cell {
                return destination(at: IndexPath(item: 0, section: nearest.indexPath.section))
            }
            let after: Bool
            if point.y > nearest.frame.maxY {
                after = true
            } else if point.y < nearest.frame.minY {
                after = false
            } else {
                after = parent.layoutDirection == .rightToLeft
                    ? point.x < nearest.frame.midX : point.x > nearest.frame.midX
            }
            return destination(at: IndexPath(item: nearest.indexPath.item + (after ? 1 : 0),
                                             section: nearest.indexPath.section))
        }

        private func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
            let dx = max(0, max(rect.minX - point.x, point.x - rect.maxX))
            let dy = max(0, max(rect.minY - point.y, point.y - rect.maxY))
            return dx * dx + dy * dy
        }

        private func destination(at indexPath: IndexPath) -> Destination? {
            guard layoutSections.indices.contains(indexPath.section) else { return nil }
            let row = layoutSections[indexPath.section]
            guard let logical = parent.sections.first(where: { $0.id == row.id.sectionID }),
                  indexPath.item >= 0, indexPath.item <= row.items.count else { return nil }
            let boundary: Int
            if row.items.isEmpty {
                guard logical.items.isEmpty else { return nil }
                boundary = 0
            } else if indexPath.item < row.items.count {
                guard let index = logical.items.firstIndex(where: { $0.id == row.items[indexPath.item] })
                else { return nil }
                boundary = index
            } else {
                guard let last = row.items.last,
                      let index = logical.items.firstIndex(where: { $0.id == last }) else { return nil }
                boundary = index + 1
            }
            // Fixed headers/status/chart/edit/add cards are anchors, never parameters.
            let parameterIndex = logical.items.prefix(boundary).filter(\.isDraggable).count
            return Destination(sectionID: logical.id, index: parameterIndex)
        }
    }
}

private final class ParameterGridHeader: UICollectionReusableView {
    private var hostedView: (UIView & UIContentView)?

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes {
        guard let fitted = layoutAttributes.copy() as? UICollectionViewLayoutAttributes else {
            return layoutAttributes
        }
        // Estimated supplementary height must be measured at the compositional
        // layout's proposed width, including wrapped/accessibility-size titles.
        let target = CGSize(width: layoutAttributes.size.width, height: UIView.layoutFittingCompressedSize.height)
        let size = systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required,
                                          verticalFittingPriority: .fittingSizeLevel)
        fitted.size = CGSize(width: layoutAttributes.size.width, height: ceil(size.height))
        return fitted
    }

    func setContent(_ configuration: UIContentConfiguration) {
        if let hostedView {
            hostedView.configuration = configuration
        } else {
            let view = configuration.makeContentView()
            hostedView = view
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }
}

struct NativeParameterGrid_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            previewGrid.previewDisplayName("编辑与空分类")
            previewGrid.preferredColorScheme(.dark).previewDisplayName("深色")
            previewGrid.environment(\.dynamicTypeSize, .accessibility5)
                .environment(\.accessibilityReduceMotion, true)
                .previewDisplayName("大字号与减少动态效果")
        }
    }

    private static var previewGrid: some View {
        NativeParameterGrid(
            sections: [
                ParameterGridSection(id: "battery", title: "电池", items: [
                    ParameterGridItem(id: "voltage"), ParameterGridItem(id: "current"),
                    ParameterGridItem(id: "add.battery", isDraggable: false, fullWidth: true)
                ]),
                ParameterGridSection(id: "empty", title: "空分类", items: [
                    ParameterGridItem(id: "add.empty", isDraggable: false, fullWidth: true)
                ])
            ],
            isEditing: true, usesSingleColumn: false, accessibilityIdentifier: "preview.parameter-grid",
            content: { id in
                if id.hasPrefix("add.") {
                    return AnyView(Button("添加参数") {}.frame(maxWidth: .infinity, minHeight: 44))
                }
                return AnyView(AppMetricCard(title: id == "voltage" ? "电压" : "电流",
                                             value: "--", detail: "未连接"))
            },
            canMove: { _, _ in true }, onMove: { _, _, _ in }
        )
    }
}
