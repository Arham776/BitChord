import Foundation
import JavaScriptCore

/// Confined to YouTubePlayerJs's actor. The pinned AST solver understands the
/// current obfuscated player; regex extraction of split/reverse helpers does not.
final class YouTubeChallengeSolver {
    private let context: JSContext
    private var functions: JSValue?

    init(directory: URL) throws {
        guard let context = JSContext() else { throw Failure("JavaScript engine unavailable") }
        self.context = context
        for name in ["yt.solver.lib.js", "yt.solver.core.js"] {
            if name == "yt.solver.core.js" {
                context.evaluateScript("var meriyah = lib.meriyah; var astring = lib.astring;")
            }
            let code = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            context.evaluateScript(code)
            try checkException()
        }
        context.evaluateScript("function bitChordPrepare(code) { var result = {}; Function('_result', code)(result); return result; }")
        try checkException()
    }

    func solve(_ type: String, challenge: String, player: String) throws -> String {
        if functions == nil {
            let input: [String: Any] = ["type": "player", "player": player,
                "output_preprocessed": true, "requests": []]
            let result = context.objectForKeyedSubscript("jsc")?.call(withArguments: [input])
            try checkException()
            guard let code = result?.objectForKeyedSubscript("preprocessed_player")?.toString(),
                  !code.isEmpty else { throw Failure("Player JavaScript could not be prepared") }
            functions = context.objectForKeyedSubscript("bitChordPrepare")?.call(withArguments: [code])
            try checkException()
        }
        guard let function = functions?.objectForKeyedSubscript(type), !function.isNull, !function.isUndefined else {
            throw Failure("Player JavaScript has no \(type) transform")
        }
        let value = function.call(withArguments: [challenge])
        try checkException()
        guard let value, !value.isNull, !value.isUndefined,
              let result = value.toString(), !result.isEmpty,
              !result.hasPrefix("enhanced_except_") else {
            throw Failure("Player \(type) transform returned no solution")
        }
        return result
    }

    private func checkException() throws {
        if context.exception != nil {
            context.exception = nil
            // JS stack traces can contain player data; keep diagnostics generic.
            throw Failure("Player JavaScript challenge evaluation failed")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
