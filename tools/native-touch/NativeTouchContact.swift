import Foundation
import CoreGraphics

public struct NativeTouchContact: Codable, Equatable, Sendable {
    public let id: UInt8
    public let x: Double
    public let y: Double

    public init(id: UInt8, x: Double, y: Double) {
        self.id = id; self.x = x; self.y = y
    }

    public var isValid: Bool {
        (1...127).contains(id) && x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }
}

enum NativeTouchFrame { static let maximumContacts = 5 }
@MainActor
protocol NativeTouchDevice: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func start(displayID: CGDirectDisplayID) async throws
    func enqueue(_ contacts: [NativeTouchContact])
    func releaseAll()
    func stop() async
}
