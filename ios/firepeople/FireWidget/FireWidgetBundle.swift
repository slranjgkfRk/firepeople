//
//  FireWidgetBundle.swift
//  FireWidget
//
//  Extension entry point. One widget, four families (README §2.4):
//  systemSmall / systemMedium on the home screen, accessoryRectangular /
//  accessoryCircular on the lock screen.
//

import SwiftUI
import WidgetKit

@main
struct FireWidgetBundle: WidgetBundle {
    var body: some Widget {
        FireWidget()
    }
}
