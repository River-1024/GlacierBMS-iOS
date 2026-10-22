import SwiftUI
import WidgetKit

/// Widget extension 的唯一入口。
///
/// 本目录（`Sources/Widgets`）**只能**属于 extension target：
/// 其中的 `@main` 若被编进 App target，会与 `ANTuRideApp` 的 `@main` 直接冲突。
@main
struct ANTuRideWidgetBundle: WidgetBundle {
    var body: some Widget {
        RideLiveActivityWidget()
    }
}
