// PostgresExtensionValueDecodingTests.swift
// PostgresNIO reads every column in binary, so ltree, lquery, ltxtquery, hstore and citext values
// (and 1-D arrays of them) arrive as their send-function bytes. Each decodes to the exact text the
// server's output function writes; a 2-D array or an unknown type keeps its bytes (nil).

import Foundation
import NIOCore
import PostgresNIO
import Testing

@testable import Dblore

@Suite struct PostgresExtensionValueDecodingTests {
  /// A captured value: the type name, the server's `x::text` (nil: not decoded), and the hex of
  /// its binary send bytes
  nonisolated struct Row: Sendable, CustomTestStringConvertible {
    let typeName: String
    let text: String?
    let hex: String

    init(_ typeName: String, _ text: String?, _ hex: String) {
      self.typeName = typeName
      self.text = text
      self.hex = hex
    }

    var bytes: ByteBuffer {
      let digits = Array(hex.utf8)
      return ByteBuffer(
        bytes: stride(from: 0, to: digits.count, by: 2).map {
          UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        })
    }

    var testDescription: String { "\(typeName) \(text ?? "nil (2-D)")" }
  }

  /// Captured from PostgreSQL 16.14 (ltree 1.2, hstore 1.8, citext 1.6)
  nonisolated static let rows: [Row] = [
    Row("ltree", #"a.b.c"#, "01612e622e63"),
    Row("ltree", #"top"#, "01746f70"),
    Row("ltree", #""#, "01"),
    Row("ltree", #"Top.Science_1.x-y"#, "01546f702e536369656e63655f312e782d79"),
    Row("lquery", #"a.*.c"#, "01612e2a2e63"),
    Row("lquery", #"*{1,2}"#, "012a7b312c327d"),
    Row("lquery", #"a|b.c"#, "01617c622e63"),
    Row("lquery", #"!x.y@*"#, "0121782e79402a"),
    Row("ltxtquery", #"a & b"#, "016120262062"),
    Row("ltxtquery", #"!c"#, "012163"),
    Row("ltxtquery", #"x*"#, "01782a"),
    Row("ltxtquery", #"a@ | b%"#, "016140207c206225"),
    Row("hstore", #""a"=>"1", "b"=>"2""#, "000000020000000161000000013100000001620000000132"),
    Row("hstore", #""k"=>NULL"#, "00000001000000016bffffffff"),
    Row("hstore", #""q\"x"=>"v\\y""#, "000000010000000371227800000003765c79"),
    Row("hstore", "\"\"=>\"\"", "000000010000000000000000"),
    Row("hstore", #""#, "00000000"),
    Row("hstore", #""spa ce"=>"é""#, "000000010000000673706120636500000002c3a9"),
    Row("citext", #"MiXeD"#, "4d69586544"),
    Row("citext", #""#, ""),
    Row("citext", #"Ünïcødé ✓"#, "c39c6ec3af63c3b864c3a920e29c93"),
    Row("citext[]", #"{}"#, "0000000000000000000bdf2e"),
    Row(
      "citext[]", "{\"a\u{0B}b\",\"a\u{0C}b\",\"a\tb\"}",
      "0000000100000000000bdf2e000000030000000100000003610b6200000003610c6200000003610962"),
    Row(
      "citext[]", #"[0:1]={a,b}"#, "0000000100000000000bdf2e000000020000000000000001610000000162"),
    Row("citext[]", #"{a,b}"#, "0000000100000000000bdf2e000000020000000100000001610000000162"),
    Row(
      "citext[]", #"{"a,b","q\"x","b\\s",""," sp","NULL",NULL}"#,
      "0000000100000001000bdf2e000000070000000100000003612c620000000371227800000003625c"
        + "730000000000000003207370000000044e554c4cffffffff"),
    Row(
      "citext[]", nil,
      "0000000200000000000bdf2e00000002000000010000000200000001000000016100000001620000"
        + "0001630000000164"),
    Row("ltree[]", #"{}"#, "0000000000000000000bddf5"),
    Row(
      "ltree[]", #"{a.b,c}"#,
      "0000000100000000000bddf500000002000000010000000401612e62000000020163"),
    Row(
      "ltree[]", #"{a.b,NULL,""}"#,
      "0000000100000001000bddf500000003000000010000000401612e62ffffffff0000000101"),
    Row(
      "ltree[]", nil,
      "0000000200000000000bddf500000002000000010000000200000001000000020161000000020162"
        + "000000020163000000020164"),
    Row(
      "hstore[]", #"{"\"a\"=>\"1\"","\"b\"=>NULL",""}"#,
      "0000000100000000000bdeae00000003000000010000000e00000001000000016100000001310000"
        + "000d000000010000000162ffffffff0000000400000000"),
    Row(
      "lquery[]", #"{a.*,b}"#,
      "0000000100000000000bde2b00000002000000010000000401612e2a000000020162"),
    Row(
      "ltxtquery[]", #"{"a & b"}"#,
      "0000000100000000000bde3b000000010000000100000006016120262062"),
  ]

  @Test("A binary extension value decodes to the server's text, byte for byte", arguments: rows)
  func decodesToServerText(_ row: Row) {
    let text = PostgresExtensionValues.text(typeName: row.typeName, bytes: row.bytes)
    #expect(text.map { Array($0.utf8) } == row.text.map { Array($0.utf8) })
  }

  @Test("Another type keeps its bytes")
  func unknownTypeIsNotDecoded() {
    #expect(PostgresExtensionValues.text(typeName: "cube", bytes: ByteBuffer(bytes: [0x01])) == nil)
  }

  // MARK: - Result cells

  /// Any OID: extension types are named per database.
  private static let oid: UInt32 = 99_999

  private static func cell(
    _ bytes: [UInt8], dataType: PostgresDataType = PostgresDataType(oid)
  ) -> PostgresCell {
    PostgresCell(
      bytes: ByteBuffer(bytes: bytes), dataType: dataType, format: .binary,
      columnName: "value", columnIndex: 0)
  }

  /// A captured binary cell of `typeName` through `parseCellValue`, the OID named `typeName`
  private static func parse(_ typeName: String, _ hex: String) -> CellValue {
    let bytes = Row(typeName, nil, hex).bytes
    return DatabaseConnectionManager.parseCellValue(
      from: cell(Array(bytes.readableBytesView)), extensionTypes: [oid: typeName])
  }

  @MainActor @Test("A citext[] cell is the array's text, not JSON")
  func citextArrayCellIsString() {
    let value = Self.parse(
      "citext[]", "0000000100000000000bdf2e000000020000000100000001610000000162")
    #expect(value == .string("{a,b}"))
  }

  @MainActor @Test("An ltree cell is its text")
  func ltreeCellIsString() {
    #expect(Self.parse("ltree", "01612e622e63") == .string("a.b.c"))
  }

  @MainActor @Test("An edit binds back the server's text of an ltree and an hstore value")
  func decodedValuesBindServerText() {
    let ltree = Self.parse("ltree", "01612e622e63")
    let hstore = Self.parse("hstore", "000000020000000161000000013100000001620000000132")
    #expect(CellUpdateStatement.inputText(ltree, dialect: .postgresql) == "a.b.c")
    #expect(
      CellUpdateStatement.inputText(hstore, dialect: .postgresql) == #""a"=>"1", "b"=>"2""#)
  }

  @MainActor @Test("A staged DELETE keyed by an ltree column binds the server's text")
  func ltreeKeyBindsServerText() throws {
    let key = Self.parse("ltree", "01612e622e63")
    let target = EditTarget(
      qualifiedName: #""t""#, tableID: .postgresql(oid: 1), primaryKeyColumns: ["path"])
    var set = RowChangeSet(target: target)
    set.stageDelete(row: RowChangeSet.RowKey(values: [key]))
    let statements = try RowChangeSQLBuilder.statements(
      for: set, target: target, columns: [ColumnInfo(name: "path", type: "LTREE")],
      dialect: .postgresql)
    #expect(statements.count == 1)
    #expect(statements.first?.values == ["a.b.c"])
  }
}
