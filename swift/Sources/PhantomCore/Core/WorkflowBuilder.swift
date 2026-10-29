import Foundation

/// Turns a raw capture into the event list that gets stored.
public enum WorkflowBuilder {

    /// Drops mouse movements that carry no information: a pointer that has
    /// barely moved since the last sample within the same display frame.
    /// Drags are never dropped — the path of a drag is the gesture.
    public static func compress(_ events: [PhantomEvent],
                                minimumDistance: Int = 2,
                                minimumInterval: Double = 0.008) -> [PhantomEvent] {
        var result: [PhantomEvent] = []
        result.reserveCapacity(events.count)

        var lastMove: PhantomEvent?
        for event in events {
            guard event.kind == .move else {
                result.append(event)
                if event.kind.isMouseMotion { lastMove = event }
                continue
            }

            if let previous = lastMove {
                let dx = abs(event.x - previous.x)
                let dy = abs(event.y - previous.y)
                let dt = event.t - previous.t
                if dx < minimumDistance, dy < minimumDistance, dt < minimumInterval {
                    continue
                }
            }
            result.append(event)
            lastMove = event
        }
        return result
    }
}
