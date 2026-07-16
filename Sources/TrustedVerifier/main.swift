import Darwin
import Foundation
import LogicProMCP

let result = QualificationRunner.runTrusted(arguments: CommandLine.arguments)
if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}
exit(Int32(result.exitCode))
