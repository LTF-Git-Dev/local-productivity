//
//  LPWidgetsBundle.swift
//  LPWidgets
//
//  LP's widgets: the day at a glance, and a board's progress.
//

import SwiftUI
import WidgetKit

@main
struct LPWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        BoardWidget()
    }
}
