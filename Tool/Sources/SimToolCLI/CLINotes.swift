import Foundation
import Noora

/// One line the operator should see but a script should not have to parse.
/// Under `--json` it goes to stderr, so stdout stays a single JSON document.
func emitNote(_ text: String, json: Bool) {
    if json {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    } else {
        makeNoora().info("\(text)")
    }
}
