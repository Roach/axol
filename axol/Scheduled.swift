import Foundation

/// Single-slot main-queue scheduler. Each instance owns at most one pending
/// block; scheduling a new one cancels the previous. Replaces the
/// "var x: DispatchWorkItem?; x?.cancel(); x = DispatchWorkItem {...}; asyncAfter(x)"
/// pattern that was repeated throughout this file.
final class Scheduled {
    private var item: DispatchWorkItem?
    func cancel() { item?.cancel(); item = nil }
    func run(after delay: TimeInterval, _ block: @escaping () -> Void) {
        cancel()
        let w = DispatchWorkItem(block: block)
        item = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}
