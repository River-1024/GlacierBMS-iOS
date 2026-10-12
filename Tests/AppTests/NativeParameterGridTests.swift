import SwiftUI
import UIKit
import XCTest
@testable import ANTuRide

/// Real UIKit layout tests with static, test-only content: no telemetry or peripherals.
/// These belong to the iOS App test target, not the domain-only SwiftPM target.
final class NativeParameterGridTests: XCTestCase {
    @MainActor private var window: UIWindow?
    @MainActor private var container: UIViewController?
    @MainActor private var host: UIHostingController<AnyView>?

    private struct MeasuredCell: Equatable {
        let id: String
        let frame: CGRect
        let cellFrame: CGRect
    }

    private struct Measurement {
        let viewport: CGRect
        let cells: [MeasuredCell]
    }

    private static let compactIDs = (0..<7).map { "compact.\($0)" }
    private static let addID = "add.parameters"
    private static let tolerance: CGFloat = 0.5 // Allow pixel rounding at 2x/3x scale.

    override func tearDown() async throws {
        await releaseHost()
        try await super.tearDown()
    }

    @MainActor
    func test375PointCompactGridHasTwoColumnsAndAnIncompleteLastRow() async throws {
        let measurement = try await measure(width: 375, items: compactItems,
                                            sectionCounts: [7])
        assertViewport(measurement, width: 375)
        assertCompactRun(Self.compactIDs, columns: 2, in: measurement)
    }

    @MainActor
    func test812PointCompactGridHasThreeColumnsAndAnIncompleteLastRow() async throws {
        let measurement = try await measure(width: 812, items: compactItems,
                                            sectionCounts: [7])
        assertViewport(measurement, width: 812)
        assertCompactRun(Self.compactIDs, columns: 3, in: measurement)
    }

    @MainActor
    func test375PointMixedGridKeepsFullWidthCardsAndTrailingAddButtonFullWidth() async throws {
        try await assertMixedGrid(width: 375, columns: 2)
    }

    @MainActor
    func test812PointMixedGridKeepsFullWidthCardsAndTrailingAddButtonFullWidth() async throws {
        try await assertMixedGrid(width: 812, columns: 3)
    }

    @MainActor
    func test812PointXXXLargeTypeOverridesThreeColumns() async throws {
        let measurement = try await measure(width: 812, items: compactItems,
                                            sectionCounts: [7], dynamicTypeSize: .xxxLarge)
        assertViewport(measurement, width: 812)
        assertCompactRun(Self.compactIDs, columns: 1, in: measurement)
    }

    private var compactItems: [ParameterGridItem] {
        Self.compactIDs.map { ParameterGridItem(id: $0) }
    }

    private var mixedItems: [ParameterGridItem] {
        // Odd compact runs plus adjacent full-width cards exercise section splitting.
        Array(compactItems.prefix(3))
            + [ParameterGridItem(id: "wide.0", fullWidth: true),
               ParameterGridItem(id: "wide.1", fullWidth: true)]
            + Array(compactItems.suffix(4))
            + [ParameterGridItem(id: Self.addID, isDraggable: false, fullWidth: true)]
    }

    @MainActor
    private func assertMixedGrid(width: CGFloat, columns: Int) async throws {
        let measurement = try await measure(width: width, items: mixedItems,
                                            sectionCounts: [3, 1, 1, 4, 1], isEditing: true)
        assertViewport(measurement, width: width)
        assertCompactRun(Array(Self.compactIDs.prefix(3)), columns: columns, in: measurement)
        assertCompactRun(Array(Self.compactIDs.suffix(4)), columns: columns, in: measurement)
        for id in ["wide.0", "wide.1", Self.addID] {
            assertFullWidth(id, in: measurement)
        }
        let frames = Dictionary(uniqueKeysWithValues: measurement.cells.map { ($0.id, $0.frame) })
        for (before, after) in [("compact.2", "wide.0"), ("wide.0", "wide.1"),
                                ("wide.1", "compact.3"), ("compact.6", Self.addID)] {
            let previous = try XCTUnwrap(frames[before])
            let next = try XCTUnwrap(frames[after])
            XCTAssertGreaterThanOrEqual(next.minY, previous.maxY + 8 - Self.tolerance,
                                        "\(after) must start below \(before)")
        }
        XCTAssertEqual(measurement.cells.last?.id, Self.addID)
        let addFrame = try XCTUnwrap(frames[Self.addID])
        for cell in measurement.cells where cell.id != Self.addID {
            XCTAssertGreaterThanOrEqual(addFrame.minY, cell.frame.maxY + 8 - Self.tolerance,
                                        "The add button must occupy its own final row")
        }
    }

    @MainActor
    private func measure(width: CGFloat, items: [ParameterGridItem], sectionCounts: [Int],
                         dynamicTypeSize: DynamicTypeSize = .large,
                         isEditing: Bool = false) async throws -> Measurement {
        XCTAssertEqual(sectionCounts.reduce(0, +), items.count)
        // A tall, fixed viewport realizes every cell, including the final add button.
        // The child constraints keep 812pt independent of the simulator's screen width.
        let viewport = CGRect(x: 0, y: 0, width: width, height: 1_600)
        let grid = NativeParameterGrid(
            sections: [ParameterGridSection(id: "fixture", items: items)],
            isEditing: isEditing, usesSingleColumn: false,
            accessibilityIdentifier: "test.native-parameter-grid",
            content: { id in
                if id == Self.addID {
                    return AnyView(Button("添加参数") {}
                        .frame(maxWidth: .infinity).frame(height: 96))
                }
                return AnyView(Text(id).font(.body)
                    .frame(maxWidth: .infinity).frame(height: 96))
            },
            canMove: { _, _ in false }, onMove: { _, _, _ in }
        )
        let host = UIHostingController(rootView: AnyView(grid
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.accessibilityReduceMotion, true)
            .ignoresSafeArea()))
        let container = UIViewController()
        container.loadViewIfNeeded()
        container.view.frame = viewport
        container.addChild(host)
        container.view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            host.view.widthAnchor.constraint(equalToConstant: width),
            host.view.heightAnchor.constraint(equalToConstant: viewport.height)
        ])
        host.didMove(toParent: container)
        let category: UIContentSizeCategory
        switch dynamicTypeSize {
        case .xxxLarge: category = .extraExtraExtraLarge
        default: category = .large
        }
        container.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category),
                                             forChild: host)
        let window = UIWindow(frame: viewport)
        window.rootViewController = container
        self.host = host
        self.container = container
        self.window = window
        window.isHidden = false // Do not steal the app's key window.

        // The diffable apply completion is private. Wait for its observable result:
        // installed section/item counts, all realized cells, and unchanged attributes
        // across three passes. Each sleep yields the main actor for apply/self-sizing.
        // Never assert on the initial empty snapshot or spin the main run loop.
        var previous: [MeasuredCell]?
        var stablePasses = 0
        for _ in 0..<100 { // At most 100 passes / about 2 seconds of scheduled waiting.
            window.layoutIfNeeded()
            container.view.layoutIfNeeded()
            host.view.layoutIfNeeded()
            if let collection = findCollection(in: host.view) {
                collection.contentInsetAdjustmentBehavior = .never
                collection.layoutIfNeeded()
                if let cells = readCells(in: collection, items: items, sectionCounts: sectionCounts) {
                    stablePasses = cells == previous ? stablePasses + 1 : 0
                    previous = cells
                    if stablePasses >= 2 {
                        XCTAssertEqual(collection.bounds.width, width, accuracy: Self.tolerance)
                        XCTAssertEqual(collection.bounds.height, viewport.height, accuracy: Self.tolerance)
                        XCTAssertEqual(collection.contentOffset.x, 0, accuracy: Self.tolerance)
                        XCTAssertEqual(collection.contentOffset.y, 0, accuracy: Self.tolerance)
                        XCTAssertLessThanOrEqual(collection.contentSize.width,
                                                 width + Self.tolerance, "No horizontal overflow")
                        return Measurement(viewport: collection.bounds, cells: cells)
                    }
                } else {
                    previous = nil
                    stablePasses = 0
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("NativeParameterGrid did not finish applying and settling \(items.count) cells in 100 passes")
        throw LayoutError.didNotSettle
    }

    private enum LayoutError: Error { case didNotSettle }

    @MainActor
    private func findCollection(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView,
           collection.accessibilityIdentifier == "test.native-parameter-grid" { return collection }
        for child in view.subviews {
            if let collection = findCollection(in: child) { return collection }
        }
        return nil
    }

    @MainActor
    private func readCells(in collection: UICollectionView, items: [ParameterGridItem],
                           sectionCounts: [Int]) -> [MeasuredCell]? {
        guard collection.dataSource != nil, collection.numberOfSections == sectionCounts.count else { return nil }
        var result: [MeasuredCell] = []
        for (section, count) in sectionCounts.enumerated() {
            guard collection.numberOfItems(inSection: section) == count else { return nil }
            for item in 0..<count {
                let path = IndexPath(item: item, section: section)
                guard let attributes = collection.collectionViewLayout.layoutAttributesForItem(at: path),
                      let cell = collection.cellForItem(at: path),
                      attributes.frame.width > 0, attributes.frame.height > 0 else { return nil }
                result.append(MeasuredCell(id: items[result.count].id, frame: attributes.frame,
                                           cellFrame: cell.frame))
            }
        }
        return result
    }

    private func assertViewport(_ measurement: Measurement, width: CGFloat,
                                file: StaticString = #filePath, line: UInt = #line) {
        let epsilon = Self.tolerance
        XCTAssertEqual(measurement.viewport.width, width, accuracy: epsilon, file: file, line: line)
        for cell in measurement.cells {
            let frame = cell.frame
            XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite },
                          cell.id, file: file, line: line)
            XCTAssertGreaterThan(frame.width, 0, cell.id, file: file, line: line)
            XCTAssertGreaterThan(frame.height, 0, cell.id, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, measurement.viewport.minX + 16 - epsilon,
                                        cell.id, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, measurement.viewport.maxX - 16 + epsilon,
                                     cell.id, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, measurement.viewport.minY - epsilon,
                                        cell.id, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, measurement.viewport.maxY + epsilon,
                                     cell.id, file: file, line: line)
            for (actual, expected) in [(cell.cellFrame.minX, frame.minX), (cell.cellFrame.minY, frame.minY),
                                       (cell.cellFrame.width, frame.width), (cell.cellFrame.height, frame.height)] {
                XCTAssertEqual(actual, expected, accuracy: epsilon, cell.id, file: file, line: line)
            }
        }
        for (index, cell) in measurement.cells.enumerated() {
            for other in measurement.cells.dropFirst(index + 1) {
                let intersection = cell.frame.intersection(other.frame)
                XCTAssertFalse(intersection.width > epsilon && intersection.height > epsilon,
                               "Overlapping cells: \(cell.id), \(other.id)", file: file, line: line)
            }
        }
    }

    private func assertFullWidth(_ id: String, in measurement: Measurement,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let frame = measurement.cells.first(where: { $0.id == id })?.frame else {
            XCTFail("Missing cell \(id)", file: file, line: line)
            return
        }
        XCTAssertEqual(frame.minX, 16, accuracy: Self.tolerance, id, file: file, line: line)
        XCTAssertEqual(frame.width, measurement.viewport.width - 32, accuracy: Self.tolerance,
                       id, file: file, line: line)
    }

    private func assertCompactRun(_ ids: [String], columns: Int, in measurement: Measurement,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let frames = Dictionary(uniqueKeysWithValues: measurement.cells.map { ($0.id, $0.frame) })
        let expectedWidth = (measurement.viewport.width - 32 - CGFloat(columns - 1) * 8) / CGFloat(columns)
        for (index, id) in ids.enumerated() {
            guard let frame = frames[id], let rowStart = frames[ids[(index / columns) * columns]] else {
                XCTFail("Missing compact cell \(id)", file: file, line: line)
                continue
            }
            XCTAssertEqual(frame.width, expectedWidth, accuracy: Self.tolerance, id, file: file, line: line)
            XCTAssertEqual(frame.minX, 16 + CGFloat(index % columns) * (expectedWidth + 8),
                           accuracy: Self.tolerance, id, file: file, line: line)
            XCTAssertEqual(frame.minY, rowStart.minY, accuracy: Self.tolerance, id, file: file, line: line)
            if index % columns == 0, index > 0, let prior = frames[ids[index - columns]] {
                XCTAssertGreaterThanOrEqual(frame.minY, prior.maxY + 8 - Self.tolerance,
                                            "Rows must not overlap", file: file, line: line)
            }
        }
    }

    @MainActor
    private func releaseHost() {
        host?.willMove(toParent: nil)
        host?.view.removeFromSuperview()
        host?.removeFromParent()
        window?.isHidden = true
        window?.rootViewController = nil
        host = nil
        container = nil
        window = nil
    }
}
