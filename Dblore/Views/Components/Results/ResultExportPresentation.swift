// ResultExportPresentation.swift
// The Export sheet of a result, shared by the result bar (`QueryCopyBar`) and the data viewer.
// The sheet opens at once when the result has an all-rows source (`openingExportRequest`):
// "Shown rows" loads the cut cells then, "All rows" never does. Without one, it opens once the
// cut cells loaded, and not at all when they could not (`openExport`).

import SwiftUI

/// Presents `ResultExportSheet` for `request`, then downloads the exported rows
struct ResultExportPresentation: ViewModifier {
  @Binding var request: QueryCopyBar.ExportRequest?
  let viewModel: NotebookViewModel?
  /// Nil in editor mode and the data viewer
  let cellId: UUID?
  /// Query index for multi-statement downloads (nil for single statement)
  let queryIndex: Int?
  /// Connection dialect of INSERT export
  let dialect: SQLDialect
  let queryLanguage: DatabaseCapabilities.QueryLanguage

  func body(content: Content) -> some View {
    content
      .sheet(item: $request) { request in
        ResultExportSheet(
          result: request.result,
          format: request.format,
          queryLanguage: queryLanguage,
          queryIndex: queryIndex,
          allRows: allRowsChoice(request.allRows),
          loadShownRows: shownRowsLoader(request.result),
          onExport: { options, exported in
            let index = queryIndex
            let exportDialect = dialect
            let table = QueryCopyBar.insertTarget(
              for: exported, viewModel: viewModel, cellId: cellId)
            self.request = nil
            DispatchQueue.main.async {
              DataExporter.download(
                result: exported, options: options, queryIndex: index, dialect: exportDialect,
                schema: table.schema, name: table.name)
            }
          },
          onCancel: { self.request = nil })
      }
  }

  /// The sheet's "All rows" for `offer`: the view model runs the read again
  private func allRowsChoice(_ offer: AllRowsExportOffer?) -> AllRowsExportChoice? {
    guard let offer else { return nil }
    let viewModel = viewModel
    return AllRowsExportChoice(
      offer: offer,
      write: { source, options, url, progress in
        guard let viewModel else { throw DatabaseError.notConnected }
        return try await viewModel.exportAllRows(
          source, options: options, to: url, progress: progress)
      },
      workspaceID: viewModel?.allRowsExportWorkspaceID)
  }

  /// Loads the cut cells of `result` before a "Shown rows" export; nil when it has none
  private func shownRowsLoader(_ result: CellResult) -> (() async -> CellResult?)? {
    guard let viewModel, viewModel.hasUnloadedCells(in: result) else { return nil }
    return { await QueryCopyBar.loadedResult(result, viewModel: viewModel, action: "Export") }
  }
}

extension QueryCopyBar {
  /// The Export sheet's format, the result it exports (cut cells already loaded, unless
  /// `allRows` has a source) and its all-rows offer
  struct ExportRequest: Identifiable {
    let id = UUID()
    let format: ExportFormat
    let result: CellResult
    var allRows: AllRowsExportOffer? = nil
  }

  /// The Export sheet request for `format`, its result fully loaded; nil opens no sheet
  static func exportRequest(
    format: ExportFormat, result: CellResult, viewModel: NotebookViewModel?, cellId: UUID? = nil
  ) async -> ExportRequest? {
    guard let loaded = await loadedResult(result, viewModel: viewModel, action: "Export") else {
      return nil
    }
    return ExportRequest(
      format: format, result: loaded,
      allRows: viewModel?.allRowsExportOffer(for: loaded, cellId: cellId))
  }

  /// The Export sheet request that opens at once, with the result as shown: one with no cut
  /// cell, or one with an all-rows source (its cut cells load only for a "Shown rows" export).
  /// Nil: the cut cells load first (`exportRequest`).
  static func openingExportRequest(
    format: ExportFormat, result: CellResult, viewModel: NotebookViewModel?, cellId: UUID?
  ) -> ExportRequest? {
    let allRows = viewModel?.allRowsExportOffer(for: result, cellId: cellId)
    if let viewModel, viewModel.hasUnloadedCells(in: result), allRows?.source == nil {
      return nil
    }
    return ExportRequest(format: format, result: result, allRows: allRows)
  }

  /// Opens the Export sheet of `result` through `open`: at once when it can
  /// (`openingExportRequest`), else once the cut cells loaded
  static func openExport(
    _ format: ExportFormat, result: CellResult, viewModel: NotebookViewModel?, cellId: UUID?,
    open: @escaping (ExportRequest) -> Void
  ) {
    if let request = openingExportRequest(
      format: format, result: result, viewModel: viewModel, cellId: cellId)
    {
      open(request)
      return
    }
    Task {
      guard
        let request = await exportRequest(
          format: format, result: result, viewModel: viewModel, cellId: cellId)
      else { return }
      open(request)
    }
  }

  /// The unquoted table of `result`'s INSERT script: the editor's data viewer relation, else
  /// the result's edit target (`insertTable(dataViewer:editTarget:)`)
  static func insertTarget(
    for result: CellResult, viewModel: NotebookViewModel?, cellId: UUID?
  ) -> (schema: String?, name: String?) {
    insertTable(
      dataViewer: cellId == nil ? viewModel?.dataViewer : nil, editTarget: result.editTarget)
  }
}
