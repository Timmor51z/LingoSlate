import Foundation

public enum SessionLifecycleState: Equatable, Sendable {
    case idle
    case preparing
    case running
    case paused
    case finalizing
    case completed
    case failed(message: String)
}

public enum SessionTransitionError: Error, Equatable, Sendable {
    case invalidTransition(from: SessionLifecycleState, to: SessionLifecycleState)
}

public actor SessionStateMachine {
    private var state: SessionLifecycleState = .idle

    public init() {}

    public func currentState() -> SessionLifecycleState {
        state
    }

    public func transition(to newState: SessionLifecycleState) throws {
        guard Self.canTransition(from: state, to: newState) else {
            throw SessionTransitionError.invalidTransition(from: state, to: newState)
        }
        state = newState
    }

    @discardableResult
    public func beginFinalizing() throws -> Bool {
        switch state {
        case .running, .paused:
            state = .finalizing
            return true
        case .finalizing, .completed:
            return false
        default:
            throw SessionTransitionError.invalidTransition(from: state, to: .finalizing)
        }
    }

    private static func canTransition(
        from current: SessionLifecycleState,
        to next: SessionLifecycleState
    ) -> Bool {
        switch (current, next) {
        case (.idle, .preparing),
             (.preparing, .running),
             (.preparing, .idle),
             (.preparing, .failed),
             (.running, .paused),
             (.running, .finalizing),
             (.running, .failed),
             (.paused, .running),
             (.paused, .finalizing),
             (.paused, .failed),
             (.finalizing, .completed),
             (.finalizing, .failed),
             (.completed, .idle),
             (.failed, .idle):
            return true
        default:
            return false
        }
    }
}
