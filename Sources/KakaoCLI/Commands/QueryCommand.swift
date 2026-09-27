import ArgumentParser
import Foundation
import KakaoCore

struct QueryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Run a raw SQL query (read-only)"
    )

    @Argument(help: "SQL query to execute")
    var sql: String

    @OptionGroup var access: DatabaseAccessOptions

    func run() throws {
        let reader = try access.open()
        defer { reader.close() }

        let results = try reader.rawQuery(sql)

        let encoder = JSONSerialization.self
        let data = try encoder.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
