import Foundation

let lossless = SourceSubstitution.decode(#"{"url":"https://source.invalid/audio.flac","format":{"codec":"flac","kbps":2304,"isLossless":true},"durationSec":180}"#)
precondition(lossless?.lossless == true && lossless?.codec == "flac" && lossless?.headers == [:])
precondition(lossless?.isDolbyAtmos == false && lossless?.belowRequest == false)
let authenticated = SourceSubstitution.decode(#"{"url":"https://source.invalid/audio","format":{"codec":"alac","isLossless":true},"headers":{"Authorization":"synthetic-provider"},"belowRequest":true}"#)
precondition(authenticated?.headers["Authorization"] == "synthetic-provider" && authenticated?.belowRequest == true)
precondition(SourceSubstitution.decode(#"{"format":{"codec":"flac"}}"#) == nil)
precondition(SourceSubstitution.decode(#"{"url":"https://source.invalid/audio","format":{"isLossless":"wrong type"}}"#) == nil)
print("PASS lossless source documents, omitted defaults, provider headers and malformed responses")
