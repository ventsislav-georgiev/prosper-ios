import Foundation
import Network

/// #661: a started listener on 127.0.0.1 that hands each accepted connection, started
/// on main, to `accept`. The listener holds every connection until it is cancelled and then
/// cancels them with it: a started NWConnection that nothing holds is not closed, it stays
/// open for the life of the test process, so each fake used to leak its server sockets.
/// #1017: bound to 127.0.0.1, not the wildcard: a wildcard listener can be given a port another
/// process holds on 127.0.0.1, and the kernel then hands it our connections, which hang unanswered.
func loopbackServer(_ accept: @escaping (NWConnection) -> Void) throws -> NWListener {
    let p = NWParameters.tcp
    p.requiredInterfaceType = .loopback
    p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: p)
    let conns = Box<[NWConnection]>([])
    listener.newConnectionHandler = { c in
        conns.v.append(c)
        c.start(queue: .main)
        accept(c)
    }
    listener.stateUpdateHandler = { state in
        guard case .cancelled = state else { return }
        conns.v.forEach { $0.cancel() }
        conns.v = []
    }
    listener.start(queue: .main)
    return listener
}
