// Regression check (review 2026-10-21, finding 1): an external model's API key is bound to the
// service it was entered for, so a model URL changed on another device (the list syncs, keys
// never do) cannot send the key to a new address. Compiled against the real ExternalModels.swift
// with small stand-ins for Core, the keychain and the model engine: scripts/checks/run.sh
import Foundation
import CoreImage

enum Core {
    static var settings: [String:String] = [:]
    static func setting(_ k:String)->String? { settings[k] }
    static func setSetting(_ k:String,_ v:String?) {settings[k]=v}
}
enum Keychain {
    static var items: [String:String] = [:]
    static func get(_ k:String)->String? {items[k]}
    @discardableResult static func set(_ k:String,_ v:String?)->Bool {items[k]=v;return true}
}
enum ModelStore {static let changed=Notification.Name("test-models")}
enum AIEngine {
    struct Prompt: Codable, Equatable {
        var system=""; var prompt=""; var context=""; var existing=""; var vocabulary=""
        static let changed=Notification.Name("test-prompt")
        static let defaults=Prompt()
        static func load()->Prompt {defaults}
        static func save(_ p:Prompt) {}
    }
    static func cleanContext(_ s:String?)->String? {s}
    static func parseTags(_ s:String)->[String] {[]}
}
final class MockTransport: URLProtocol {
    static var captured: URLRequest?
    override class func canInit(with request: URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        Self.captured=request
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data("{\"data\":[{\"id\":\"audit-model\"}]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
struct BoundaryHarness {
    static func main() async throws {
        let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[MockTransport.self]
        ExternalAI.session=URLSession(configuration:config)
        var m=ExternalModel(id:"ext:audit",name:"test",url:"https://original.example/v1",model:"audit-model")
        m.apiKey="SYNTHETIC_TEST_KEY_ONLY"
        ExternalModels.save(m)
        m.url="https://changed-by-peer.example/v1"
        Core.setSetting("ai.external",String(decoding:try JSONEncoder().encode([m]),as:UTF8.self))
        _ = try await ExternalAI.models(ExternalModels.find(m.id)!)
        let captured=MockTransport.captured!
        print("Synced endpoint change -> host=\(captured.url!.host!), Authorization=\(captured.value(forHTTPHeaderField:"Authorization") ?? "nil")")
        if captured.value(forHTTPHeaderField:"Authorization") != nil { print("FAIL the key followed the URL"); exit(1) }
    }
}
// more cases
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { exit(1) } }
var n = ExternalModel(id: "ext:two", name: "t", url: "https://api.x.ai/v1", model: "m")
n.apiKey = "K1"
check(ExternalModels.find("ext:two") == nil, "not saved yet")
check(n.apiKey == "K1", "key readable for the URL it was entered for")
n.url = "https://API.x.ai:443/v1/chat/completions"
check(n.apiKey == "K1", "same origin (case, default port, path) keeps the key")
n.url = "https://evil.example/v1"
check(n.apiKey == nil, "another host: no key")
n.url = "https://api.x.ai/v1"
check(n.apiKey == "K1", "back to the bound origin: key again")
n.apiKey = nil
check(Keychain.get("ai.keyorigin.ext:two") == nil && n.apiKey == nil, "clearing removes the binding")
Keychain.items["ai.key.ext:old"] = "LEGACY"
let old = ExternalModel(id: "ext:old", name: "", url: "http://127.0.0.1:11434", model: "")
check(old.apiKey == "LEGACY" && Keychain.get("ai.keyorigin.ext:old") == "http://127.0.0.1:11434", "legacy key binds to where it points now")
var moved = old; moved.url = "http://other.example"
check(moved.apiKey == nil, "and then does not follow a changed URL")
try await BoundaryHarness.main()
