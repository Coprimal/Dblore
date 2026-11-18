// PostgresStatementNULTests.swift
// PostgreSQL statement text with a NUL is refused before PostgresNIO writes it null-terminated.

import Foundation
import Testing

@testable import Dblore

@Suite("PostgreSQL statement NUL")
struct PostgresStatementNULTests {
  @Test("A statement with a NUL character is refused (the server would cut the text there)")
  func nulRefused() {
    let error = #expect(throws: PostgresNULRefusal.self) {
      try PostgresSession.refuseNUL("DELETE FROM t\u{0} WHERE id = 1")
    }
    #expect(error?.localizedDescription.contains("NUL character") == true)
  }

  @Test("A statement without a NUL character passes")
  func plainTextPasses() throws {
    try PostgresSession.refuseNUL("DELETE FROM t WHERE id = 1")
  }

  /// The refusal runs before the closed-connection check, so an unopened session shows it
  @Test("A command with a NUL character is refused before it is sent")
  @MainActor func commandRefused() async {
    let session = PostgresSession(config: Self.config())
    await #expect(throws: PostgresNULRefusal.self) {
      _ = try await session.command("DELETE FROM t\u{0} WHERE id = 1", binds: [])
    }
  }

  @Test("A query with a NUL character is refused before it is sent")
  @MainActor func queryRefused() async {
    let session = PostgresSession(config: Self.config())
    await #expect(throws: PostgresNULRefusal.self) {
      _ = try await session.query("SELECT 1\u{0}; DELETE FROM t", binds: [])
    }
  }

  @MainActor private static func config() -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
      password: "p", sslMode: .disable, protectionLevel: .none, safeMode: .silent,
      protectedMode: false)
  }
}
