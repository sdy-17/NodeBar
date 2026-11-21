import Foundation
import Network

/// Routes this Mac's browser to a loopback listener through a LAN-address URL.
final class LocalRoute {
    private let queue = DispatchQueue(label: "NodeBar.local-route")
    private let listener: NWListener
    private let address: String
    private let port: NWEndpoint.Port
    private let target: NWEndpoint.Host
    private var connections: [UUID: (NWConnection, NWConnection)] = [:]

    init(address: String, target: String, port: UInt16, preservePort: Bool) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.address = address
        self.target = NWEndpoint.Host(target)
        self.port = NWEndpoint.Port(rawValue: port)!
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: preservePort ? self.port : .any)
        listener = try NWListener(using: params)
    }

    func start(_ completion: @escaping (Result<URL, Error>) -> Void) {
        var pending = true
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, pending else { return }
            let result: Result<URL, Error>
            switch state {
            case .ready:
                guard let port = self.listener.port, let url = URL(string: "http://" + self.address + ":" + String(port.rawValue)) else { return }
                result = .success(url)
            case .failed(let error): result = .failure(error)
            default: return
            }
            pending = false
            DispatchQueue.main.async { completion(result) }
        }
        listener.newConnectionHandler = { [weak self] incoming in
            guard let self, case .hostPort(let peer, _) = incoming.endpoint,
                  case .ipv4(let ip) = peer, ip.rawValue == IPv4Address(self.address)?.rawValue else {
                incoming.cancel()
                return
            }
            let id = UUID()
            let backend = NWConnection(host: self.target, port: self.port, using: .tcp)
            self.connections[id] = (incoming, backend)
            for connection in [incoming, backend] {
                connection.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.close(id) }
                }
                connection.start(queue: self.queue)
            }
            self.copy(incoming, to: backend, id: id)
            self.copy(backend, to: incoming, id: id)
        }
        listener.start(queue: queue)
    }
    private func copy(_ from: NWConnection, to: NWConnection, id: UUID) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, eof, error in
            guard let self, self.connections[id] != nil else { return }
            if error != nil { self.close(id); return }
            to.send(content: data, contentContext: eof ? .finalMessage : .defaultMessage, isComplete: true,
                    completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.close(id) }
                else if eof {
                    if !self.halfClosed.insert(id).inserted { self.close(id) }
                } else { self.copy(from, to: to, id: id) }
            })
        }
    }
    private var halfClosed = Set<UUID>()
    private func close(_ id: UUID) {
        halfClosed.remove(id)
        guard let pair = connections.removeValue(forKey: id) else { return }
        pair.0.cancel()
        pair.1.cancel()
    }
    func stop() {
        queue.async {
            self.listener.cancel()
            for id in Array(self.connections.keys) { self.close(id) }
        }
    }
}
