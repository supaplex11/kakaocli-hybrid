import ArgumentParser
import Foundation
import KakaoCore

struct SchemaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema",
        abstract: "Dump the database schema (for reverse engineering)"
    )

    @OptionGroup var access: DatabaseAccessOptions

    func run() throws {
        let reader = try access.open()
        defer { reader.close() }

        let tables = try reader.schema()
        if tables.isEmpty {
            print("No tables found (database may be encrypted).")
            return
        }

        for table in tables {
            print("-- \(table.name)")
            print("\(table.sql);")
            print()
        }
    }
}
