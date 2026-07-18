import Foundation

final class CaptureDelegateRegistry {
    private var delegates: [AnyObject] = []

    var count: Int { delegates.count }

    func retain(_ delegate: AnyObject) {
        delegates.append(delegate)
    }
}
