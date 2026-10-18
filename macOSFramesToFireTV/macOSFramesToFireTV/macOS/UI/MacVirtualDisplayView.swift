//
//  MacVirtualDisplayView.swift
//  macOSFramesToFireTV
//
//  Created by Aryan Rogye on 10/18/26.
//

import SwiftUI
import VirtualDisplayKit

enum MacVirtualDisplayWindow {
    static let id = "virtual-display"
}

struct MacVirtualDisplayView: View {
    @Bindable var model: MacStreamingModel

    let landscapeAspect: CGFloat = 16.0 / 9.0

    var body: some View {
        Group {
            if let virtualDisplay = model.virtualDisplay {
                GeometryReader { proxy in
                    let targetWidth = min(
                        proxy.size.width,
                        proxy.size.height * landscapeAspect
                    )
                    let targetHeight = targetWidth / landscapeAspect

                    VirtualDisplayKit.VirtualDisplayView(
                        virtualDisplay: virtualDisplay,
                        highlightWhenCursorInside: true
                    ) { point in
                        model.moveCursor(to: point)
                    }
                    .frame(width: targetWidth, height: targetHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
                    .overlay {
                        Text("No Virtual Display Running")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(.ultraThinMaterial)
        }
    }
}
