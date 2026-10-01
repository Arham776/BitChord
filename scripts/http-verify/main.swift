import Foundation
import BitChordShared
func check(_ value: Bool, _ message: String) {
    guard value else { fatalError(message) }; print("PASS \(message)")
}
@main struct Verify {
    static func main() async throws {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Int]
        let root = "http://127.0.0.1:\(config["first"]!)"
        let other = "http://127.0.0.1:\(config["other"]!)"
        let secret = ["Authorization":"Basic synthetic-fixture", "Cookie":"fixture=synthetic"]
        func swift(_ path: String, headers: [String: String]) async throws -> [String:Any] {
            var request = URLRequest(url: URL(string: root+path)!)
            for (name,value) in headers { request.setValue(value, forHTTPHeaderField:name) }
            let bytes = try await GuardedHTTP.shared.data(for: request)
            return try JSONSerialization.jsonObject(with: bytes) as! [String:Any]
        }
        func kotlin(_ path: String, headers: [String:String]) async throws -> [String:Any] {
            let result: String = try await withCheckedThrowingContinuation { continuation in
                Http.shared.getText(url:root+path, headers:headers, query:[:], timeoutMillis:5000) { value,error in
                    if let error { continuation.resume(throwing:error) }
                    else { continuation.resume(returning:value!) }
                }
            }
            return try JSONSerialization.jsonObject(with:Data(result.utf8)) as! [String:Any]
        }
        let swiftSame = try await swift("/same",headers:secret)
        check(swiftSame["authenticated"] as? Bool == true, "Swift same-origin redirect retains synthetic credentials")
        let sharedSame = try await kotlin("/same",headers:secret)
        check(sharedSame["authenticated"] as? Bool == true, "shared HTTP same-origin redirect retains synthetic credentials")
        let swiftPublic = try await swift("/cross",headers:[:])
        let sharedPublic = try await kotlin("/cross",headers:[:])
        check(swiftPublic["authenticated"] as? Bool == false && sharedPublic["cookie"] as? Bool == false,
              "both HTTP clients follow public redirects without credentials")
        let countBefore = try await swift("/counts",headers:[:])["other"] as! Int
        do { _ = try await swift("/cross",headers:secret); fatalError("Swift forwarded secrets") } catch {}
        do { _ = try await kotlin("/cross",headers:secret); fatalError("shared HTTP forwarded secrets") } catch {}
        let countAfter = try await swift("/counts",headers:[:])["other"] as! Int
        check(countBefore == countAfter, "authenticated redirects never reach another origin")
        check(!GuardedHTTP.sameOrigin(URL(string:root)!,URL(string:other)!), "origin includes port")
        check(!GuardedHTTP.sameOrigin(URL(string:root)!,URL(string:root.replacingOccurrences(of:"http:",with:"https:"))!), "origin includes scheme")
        _ = try await kotlin("/set-jar", headers:[:])
        let jar = try await kotlin("/target", headers:[:])
        check(jar["cookieValue"] as? String == "fixture=jar-stale", "provider cookie jar remains available for ordinary requests")
        let explicit = try await kotlin("/target", headers:secret)
        check(explicit["cookieValue"] as? String == "fixture=synthetic", "explicit session cookie is not replaced or duplicated by jar cookies")
        _ = try await kotlin("/clear-jar", headers:[:])
    }
}
