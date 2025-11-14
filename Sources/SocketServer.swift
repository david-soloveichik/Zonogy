import Foundation
import AppKit

/// JSON-RPC style protocol for Unix domain socket communication
class SocketServer {
    private let socketPath: String
    private var socketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let appController: AppController
    private var acceptTimer: Timer?

    init(socketPath: String = "/tmp/zonogy.sock", appController: AppController) {
        self.socketPath = socketPath
        self.appController = appController
    }

    func start() {
        // Remove existing socket file if it exists
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create Unix domain socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            Logger.debug("Failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        // Set socket to non-blocking
        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        // Bind to the socket path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Logger.debug("Socket path too long")
            close(socketFD)
            return
        }

        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            pathBytes.withUnsafeBufferPointer { buffer in
                memcpy(ptr, buffer.baseAddress, buffer.count)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            Logger.debug("Failed to bind socket: \(String(cString: strerror(errno)))")
            close(socketFD)
            return
        }

        // Listen for connections
        guard listen(socketFD, 5) == 0 else {
            Logger.debug("Failed to listen on socket: \(String(cString: strerror(errno)))")
            close(socketFD)
            return
        }

        // Set socket file permissions
        chmod(socketPath, 0o666)

        Logger.debug("Socket server listening on \(socketPath)")

        // Use a timer to poll for connections (workaround for DispatchSource issues)
        acceptTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkForConnections()
        }
        RunLoop.main.add(acceptTimer!, forMode: .common)
        Logger.debug("Accept timer started, fd=\(socketFD)")
    }

    func stop() {
        acceptTimer?.invalidate()
        acceptTimer = nil
        acceptSource?.cancel()
        if socketFD >= 0 {
            close(socketFD)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func checkForConnections() {
        // Try to accept a connection (non-blocking)
        var addr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(socketFD, sockaddrPtr, &addrLen)
            }
        }

        if clientFD < 0 {
            let err = errno
            if err != EAGAIN && err != EWOULDBLOCK {
                Logger.debug("Accept error (errno=\(err)): \(String(cString: strerror(err)))")
            }
            return
        }

        Logger.debug("Accepted connection on fd \(clientFD)")

        // Handle client on background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handleClient(clientFD)
        }
    }

    private func handleClient(_ clientFD: Int32) {
        // Set client socket to blocking for simpler I/O
        let flags = fcntl(clientFD, F_GETFL, 0)
        _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)

        // Read data from client until newline or EOF
        var receivedData = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let bytesRead = read(clientFD, &buffer, bufferSize)

            if bytesRead <= 0 {
                break
            }

            receivedData.append(buffer, count: bytesRead)

            // Check if we've received a newline
            if let lastByte = receivedData.last, lastByte == UInt8(ascii: "\n") {
                break
            }

            // Also break if we've read a complete JSON object (check for closing brace)
            if receivedData.count > 0,
               let str = String(data: receivedData, encoding: .utf8),
               str.trimmingCharacters(in: .whitespacesAndNewlines).last == "}" {
                break
            }
        }

        guard receivedData.count > 0 else {
            close(clientFD)
            return
        }

        let response = processRequest(receivedData)

        // Write response
        response.withUnsafeBytes { ptr in
            _ = write(clientFD, ptr.baseAddress, response.count)
        }

        close(clientFD)
    }

    private func processRequest(_ data: Data) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return errorResponse(id: nil, message: "Invalid request format")
        }

        let id = json["id"] as? Int
        let params = json["params"] as? [String: Any] ?? [:]

        let result = executeCommand(method: method, params: params)
        return successResponse(id: id, result: result)
    }

    private func executeCommand(method: String, params: [String: Any]) -> [String: Any] {
        // All AppController methods must run on the main thread for AppKit safety
        return DispatchQueue.main.sync {
            switch method {
            case "add-zone":
                return appController.addZoneJSON()

            case "remove-zone":
                guard let index = params["index"] as? Int else {
                    return ["error": "Missing required parameter: index"]
                }
                return appController.removeZoneJSON(at: index)

            case "resize-zone":
                guard let index = params["index"] as? Int else {
                    return ["error": "Missing required parameter: index"]
                }
                guard let frameDict = params["frame"] as? [String: Any],
                      let frame = parseFrame(from: frameDict) else {
                    return ["error": "Missing or invalid frame parameter. Expected {\"x\":<number>,\"y\":<number>,\"width\":<number>,\"height\":<number>}"]
                }
                return appController.resizeZoneJSON(at: index, frame: frame)

            case "capture-frontmost":
                return appController.captureFrontmostWindowJSON()

            case "close-window":
                guard let windowId = params["window_id"] as? Int else {
                    return ["error": "Missing required parameter: window_id"]
                }
                return appController.closeWindowJSON(withId: windowId)

            case "minimize":
                guard let windowId = params["window_id"] as? Int else {
                    return ["error": "Missing required parameter: window_id"]
                }
                return appController.minimizeWindowJSON(withId: windowId)

            case "unminimize":
                guard let windowId = params["window_id"] as? Int else {
                    return ["error": "Missing required parameter: window_id"]
                }
                return appController.unminimizeWindowJSON(withId: windowId)

            case "list":
                return appController.listZonesJSON()

            case "layout":
                return appController.relayoutJSON()

            case "window-info":
                guard let windowId = params["window_id"] as? Int else {
                    return ["error": "Missing required parameter: window_id"]
                }
                return appController.windowInfoJSON(windowId: windowId)

            case "frames":
                return appController.printFramesJSON()

            case "managed-windows":
                return appController.managedWindowsJSON()

            case "validate-application":
                guard let pidParam = params["pid"] else {
                    return ["error": "Missing required parameter: pid"]
                }
                let pidValue: Int?
                if let number = pidParam as? Int {
                    pidValue = number
                } else if let string = pidParam as? String {
                    pidValue = Int(string)
                } else {
                    pidValue = nil
                }
                guard let pidInt = pidValue else {
                    return ["error": "Invalid pid parameter"]
                }
                return appController.validateApplicationJSON(pid: pid_t(pidInt))

            default:
                return ["error": "Unknown command: \(method)"]
            }
        }
    }

    private func successResponse(id: Int?, result: [String: Any]) -> Data {
        let response: [String: Any] = [
            "id": id as Any,
            "success": result["error"] == nil,
            "result": result["error"] == nil ? result : NSNull(),
            "error": result["error"] as Any? ?? NSNull()
        ]
        var data = try! JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted])
        data.append("\n".data(using: .utf8)!)
        return data
    }

    private func errorResponse(id: Int?, message: String) -> Data {
        let response: [String: Any] = [
            "id": id as Any,
            "success": false,
            "result": NSNull(),
            "error": message
        ]
        var data = try! JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted])
        data.append("\n".data(using: .utf8)!)
        return data
    }

    private func parseFrame(from dict: [String: Any]) -> CGRect? {
        guard let x = numberToCGFloat(dict["x"]),
              let y = numberToCGFloat(dict["y"]),
              let width = numberToCGFloat(dict["width"]),
              let height = numberToCGFloat(dict["height"]) else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func numberToCGFloat(_ value: Any?) -> CGFloat? {
        switch value {
        case let number as NSNumber:
            return CGFloat(truncating: number)
        case let string as String:
            if let doubleValue = Double(string) {
                return CGFloat(doubleValue)
            }
            return nil
        default:
            return nil
        }
    }
}
