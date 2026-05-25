// main.swift — SentinelCore XPC service entry point
// Swift 6 / macOS 14

import Foundation

let delegate = SentinelServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
