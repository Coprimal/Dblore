// PostgresExtensionValues.swift
// PostgresNIO asks for every result column in binary, so a value of an extension type reaches the
// app as the bytes of the type's send function. This decodes those bytes to the text the server's
// output function writes (`x::text`), for ltree, lquery, ltxtquery, hstore and citext and the
// one-dimensional arrays of them. Any other name, a multi-dimensional array or bytes that do not
// parse give nil: the caller keeps the bytes.

import Foundation
import NIOCore

nonisolated enum PostgresExtensionValues {
  /// The server's text form of `bytes`, a binary value of the extension type `typeName` ("ltree",
  /// "lquery", "ltxtquery", "hstore", "citext", or one of them followed by "[]"), or nil. Reads a
  /// copy of `bytes`, so the caller's reader index does not move.
  static func text(typeName: String, bytes: ByteBuffer) -> String? {
    var buffer = bytes
    if typeName.hasSuffix("[]") {
      let element = String(typeName.dropLast(2))
      guard let decode = decoder(element) else { return nil }
      return arrayText(buffer: &buffer, decode: decode)
    }
    guard let decode = decoder(typeName) else { return nil }
    return decode(&buffer)
  }

  /// The decoder of the type `name`, which reads the whole buffer, or nil for another type
  private static func decoder(_ name: String) -> ((inout ByteBuffer) -> String?)? {
    switch name {
    case "ltree", "lquery", "ltxtquery": versionedText
    case "citext": utf8Text
    case "hstore": hstoreText
    default: nil
    }
  }

  /// ltree, lquery, ltxtquery: the version byte 1, then the text
  private static func versionedText(_ buffer: inout ByteBuffer) -> String? {
    guard buffer.readInteger(as: UInt8.self) == 1 else { return nil }
    return utf8Text(&buffer)
  }

  /// The rest of the buffer as UTF-8, or nil when it is not valid UTF-8
  private static func utf8Text(_ buffer: inout ByteBuffer) -> String? {
    let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
    let text = String(decoding: bytes, as: UTF8.self)
    return Array(text.utf8) == bytes ? text : nil
  }

  /// hstore: the pair count, then per pair the key and the value (length -1: NULL), written as
  /// hstore_out does: `"key"=>"value"` joined by ", "
  private static func hstoreText(_ buffer: inout ByteBuffer) -> String? {
    guard let count = buffer.readInteger(as: Int32.self), count >= 0 else { return nil }
    var pairs: [String] = []
    for _ in 0..<count {
      guard case .some(let key?) = readField(&buffer, decode: utf8Text),
        case .some(let value) = readField(&buffer, decode: utf8Text)
      else { return nil }
      pairs.append("\(quoted(key))=>\(value.map(quoted) ?? "NULL")")
    }
    guard buffer.readableBytes == 0 else { return nil }
    return pairs.joined(separator: ", ")
  }

  /// A one-dimensional array: ndim, the has-null flag, the element OID, per dimension the size and
  /// the lower bound, then each element (length -1: NULL), written as array_out does
  private static func arrayText(
    buffer: inout ByteBuffer, decode: (inout ByteBuffer) -> String?
  ) -> String? {
    guard let dimensions = buffer.readInteger(as: Int32.self),
      let hasNull = buffer.readInteger(as: Int32.self), hasNull == 0 || hasNull == 1,
      buffer.readInteger(as: UInt32.self) != nil
    else { return nil }
    if dimensions == 0 { return buffer.readableBytes == 0 ? "{}" : nil }
    guard dimensions == 1,
      let size = buffer.readInteger(as: Int32.self), size >= 0,
      let lowerBound = buffer.readInteger(as: Int32.self)
    else { return nil }
    var items: [String] = []
    for _ in 0..<size {
      guard case .some(let item) = readField(&buffer, decode: decode) else { return nil }
      items.append(item.map(arrayItem) ?? "NULL")
    }
    guard buffer.readableBytes == 0 else { return nil }
    let upperBound = Int64(lowerBound) + Int64(size) - 1
    let bounds = lowerBound == 1 || size == 0 ? "" : "[\(lowerBound):\(upperBound)]="
    return bounds + "{" + items.joined(separator: ",") + "}"
  }

  /// A length-prefixed field: .some(nil) for NULL (length -1), .some(text) when its bytes decode,
  /// nil when the buffer is short or the bytes do not decode
  private static func readField(
    _ buffer: inout ByteBuffer, decode: (inout ByteBuffer) -> String?
  ) -> String?? {
    guard let length = buffer.readInteger(as: Int32.self) else { return nil }
    if length == -1 { return .some(nil) }
    guard length >= 0, var field = buffer.readSlice(length: Int(length)),
      let text = decode(&field), field.readableBytes == 0
    else { return nil }
    return .some(text)
  }

  /// An array element as array_out writes it: quoted when empty, "NULL" in any ASCII case, or
  /// holding a brace, comma, quote, backslash or whitespace
  private static func arrayItem(_ text: String) -> String {
    let special: Set<Unicode.Scalar> = [
      "{", "}", ",", "\"", "\\", " ", "\t", "\n", "\r", "\u{0B}", "\u{0C}",
    ]
    let isNull = text.utf8.elementsEqual("null".utf8) { (0x41...0x5A ~= $0 ? $0 | 0x20 : $0) == $1 }
    let needsQuotes =
      text.isEmpty || isNull || text.unicodeScalars.contains(where: special.contains)
    return needsQuotes ? quoted(text) : text
  }

  /// `text` in double quotes, with `"` and `\` escaped by a backslash
  private static func quoted(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    result.append("\"")
    for scalar in text.unicodeScalars {
      if scalar == "\"" || scalar == "\\" { result.append("\\") }
      result.append(scalar)
    }
    result.append("\"")
    return String(result)
  }
}
