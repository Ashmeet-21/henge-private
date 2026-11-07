import AppKit
import Foundation
import Darwin

private struct Command: Decodable {
    let version: Int
    let epoch: UInt32
    let enabled: Bool
    let contacts: [NativeTouchContact]

    var isValid: Bool {
        version == 1 && epoch != 0 && contacts.count <= 5 && contacts.allSatisfy(\.isValid)
            && Set(contacts.map(\.id)).count == contacts.count
    }
}

/// Runs only inside the guest. No listening socket and no changes to OS security policy.
@main
private enum TouchAgent {
    @MainActor static func main() async {
        let parent = CommandLine.arguments.dropFirst().first.flatMap(Int32.init) ?? getppid()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.5
        configuration.timeoutIntervalForResource = 1
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let url = URL(string: "http://10.0.2.4/.henge/native-touch")!
        let state = AgentState()
        // A hung network operation must not leave fingers held in the guest.
        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if ProcessInfo.processInfo.systemUptime-state.lastCommand > 0.7 {
                    state.device?.releaseAll(); state.neutralRequired = true
                }
                if getppid() != parent || kill(parent, 0) != 0 { break }
            }
        }
        while getppid() == parent && kill(parent, 0) == 0 {
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let command = try JSONDecoder().decode(Command.self, from: data)
                guard command.isValid else { throw URLError(.cannotParseResponse) }
                state.lastCommand = ProcessInfo.processInfo.systemUptime
                if command.epoch != state.generation || !command.enabled {
                    await state.device?.stop(); state.device = nil
                    state.generation = command.epoch; state.failure = 0; state.neutralRequired = true
                }
                guard command.enabled else { continue }
                if state.device == nil && state.failure == 0 {
                    if #available(macOS 27.2, *) {
                        if !AXIsProcessTrusted() { state.failure = 4 }
                        else {
                            let next = SystemNativeTouchDevice()
                            next.onFailure = { _ in state.failure = 5 }
                            do {
                                state.display = CGMainDisplayID(); state.bounds = CGDisplayBounds(state.display)
                                try await next.start(displayID: state.display)
                                state.device = next
                            } catch { await next.stop(); state.failure = 5 }
                        }
                    } else { state.failure = 3 }
                }
                if state.device != nil && (CGMainDisplayID() != state.display || CGDisplayBounds(state.display) != state.bounds || !AXIsProcessTrusted()) {
                    state.failure = 5
                }
                if state.failure != 0 { await state.device?.stop(); state.device = nil }
                else {
                    if command.contacts.isEmpty { state.neutralRequired = false }
                    if !state.neutralRequired { state.device?.enqueue(command.contacts) }
                }
                var report = URLRequest(url: url)
                report.httpMethod = "PUT"
                report.httpBody = Data("\(state.generation) \(state.failure == 0 ? 2 : state.failure)".utf8)
                let (_, acknowledgment) = try await session.data(for: report)
                guard (acknowledgment as? HTTPURLResponse)?.statusCode == 204 else { throw URLError(.badServerResponse) }
            } catch {
                await state.device?.stop(); state.device = nil; state.generation = 0; state.neutralRequired = true
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        watchdog.cancel()
        await state.device?.stop()
        session.invalidateAndCancel()
    }
}

@MainActor
private final class AgentState {
    var device: SystemNativeTouchDevice?
    var generation: UInt32 = 0
    var display: CGDirectDisplayID = 0
    var bounds = CGRect.zero
    var failure = 0
    var neutralRequired = true
    var lastCommand = ProcessInfo.processInfo.systemUptime
}
