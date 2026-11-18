// ToastScopeTests.swift
// Toasts live in one shared store; a toast raised by a workspace window carries that workspace's
// id and shows only in that window's overlay, never in another workspace window or on Welcome.
// An untagged (app-level) toast shows everywhere. No database server.

import AppKit
import Testing

@testable import Dblore

@MainActor
@Suite("Toast scope")
struct ToastScopeTests {
  nonisolated private static let workspaceA = UUID(
    uuidString: "00000000-0000-0000-0000-00000000000A")!
  nonisolated private static let workspaceB = UUID(
    uuidString: "00000000-0000-0000-0000-00000000000B")!

  @Test(
    "A workspace toast shows only in its own window; an app-level toast shows everywhere",
    arguments: [
      (workspaceA, workspaceA, true),
      (workspaceA, workspaceB, false),
      (workspaceA, nil, false),
      (nil, workspaceA, true),
      (nil, nil, true),
    ] as [(UUID?, UUID?, Bool)])
  func visibility(toastWorkspace: UUID?, overlayScope: UUID?, visible: Bool) {
    #expect(
      ToastOverlay.isVisible(toastWorkspace: toastWorkspace, overlayScope: overlayScope) == visible)
  }

  /// A workspace window as the toast check sees it: on screen when ordered front; a window
  /// never ordered in reports not visible, as a background native tab does
  private func makeWindow(onScreen: Bool) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    if onScreen { window.orderFront(nil) }
    return window
  }

  @Test("A notebook of a workspace with its window on screen raises toasts tagged with it")
  func notebookToastTaggedWithItsWorkspace() throws {
    let windows = WorkspaceWindowManager.shared
    let findWindow = windows.findWorkspaceWindow
    let window = makeWindow(onScreen: true)
    windows.dismissToast()
    defer {
      windows.dismissToast()
      windows.findWorkspaceWindow = findWindow
      window.orderOut(nil)
    }
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)
    windows.findWorkspaceWindow = { $0 == manager.id ? window : nil }
    let viewModel = try #require(manager.viewModel(for: manager.newSQLFile()))

    viewModel.showToast("Toast scope probe", type: .warning)

    let toast = try #require(windows.toastState.currentToast)
    #expect(toast.message == "Toast scope probe")
    #expect(toast.workspaceID == manager.id)
  }

  @Test("A workspace whose window is not on screen raises app-level toasts, so none is lost")
  func hiddenWorkspaceToastIsAppLevel() throws {
    let windows = WorkspaceWindowManager.shared
    let findWindow = windows.findWorkspaceWindow
    let backgroundTab = makeWindow(onScreen: false)
    windows.dismissToast()
    defer {
      windows.dismissToast()
      windows.findWorkspaceWindow = findWindow
    }
    windows.findWorkspaceWindow = { _ in nil }
    let manager = WorkspaceManager(workspace: Workspace(), restoreTabs: false)

    manager.showToast("No window yet", type: .warning)
    #expect(try #require(windows.toastState.currentToast).workspaceID == nil)

    windows.findWorkspaceWindow = { _ in backgroundTab }
    manager.showToast("Background tab", type: .warning)
    let toast = try #require(windows.toastState.currentToast)
    #expect(toast.message == "Background tab")
    #expect(toast.workspaceID == nil)
  }
}
