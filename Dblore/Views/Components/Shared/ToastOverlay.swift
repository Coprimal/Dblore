//
//  ToastOverlay.swift
//  Dblore
//

import SwiftUI

/// Toast notification overlay (bottom-right corner)
/// Uses WorkspaceWindowManager for app-wide toast management
struct ToastOverlay: View {
  @Bindable var windowManager = WorkspaceWindowManager.shared
  @ReduceMotion private var reduceMotion
  @Environment(\.hidesToastOverlay) private var isHidden
  @Environment(\.toastWorkspaceID) private var workspaceID

  var body: some View {
    // Always present, so the toast's insertion and removal can animate
    ZStack {
      if !isHidden, let toast = windowManager.toastState.currentToast,
        Self.isVisible(toastWorkspace: toast.workspaceID, overlayScope: workspaceID)
      {
        VStack {
          Spacer()
          HStack {
            Spacer()
            ToastView(toast: toast, windowManager: windowManager)
              .padding(.horizontal, Spacing.lg)
              .padding(.vertical, Spacing.xxl)
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
      }
    }
    .animation(
      reduceMotion ? nil : .snappy(duration: 0.2), value: windowManager.toastState.currentToast
    )
    // Opt out of the app-wide animation kill switch, only for the show/dismiss change
    .transaction(value: windowManager.toastState.currentToast) { $0.disablesAnimations = false }
  }
}

extension ToastOverlay {
  /// Whether an overlay scoped to `overlayScope` (a workspace window; nil outside one) shows a
  /// toast raised by `toastWorkspace` (nil for an app-level toast)
  static func isVisible(toastWorkspace: UUID?, overlayScope: UUID?) -> Bool {
    toastWorkspace == nil || toastWorkspace == overlayScope
  }
}

extension EnvironmentValues {
  /// True while a sheet over this window shows the toasts in its own overlay, so each toast
  /// shows once
  @Entry var hidesToastOverlay = false
  /// The workspace whose window hosts this view; nil outside a workspace window (Welcome), where
  /// only app-level toasts show
  @Entry var toastWorkspaceID: UUID?
}
