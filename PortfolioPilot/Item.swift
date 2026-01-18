//
//  Item.swift
//  PortfolioPilot
//
//  Created by Liuyang on 2026/1/18.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
