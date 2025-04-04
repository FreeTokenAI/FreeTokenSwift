//
//  VersionTester.swift
//  FreeToken
//
//  Created by Vince Francesi on 12/4/24.
//


import Foundation

extension FreeToken {
    class VersionTester {
        private let minVersion: String
        private let maxVersion: String
        
        init(minVersion: String, maxVersion: String) {
            self.minVersion = minVersion
            self.maxVersion = maxVersion
        }
        
        public func isVersionSupported(version: String) -> Bool {
            return compareVersions(version, minVersion) != .orderedAscending &&
            compareVersions(version, maxVersion) != .orderedDescending
        }
        
        private func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
            let version1Components = v1.split(separator: ".").map { Int($0) ?? 0 }
            let version2Components = v2.split(separator: ".").map { Int($0) ?? 0 }
            
            for (component1, component2) in zip(version1Components, version2Components) {
                if component1 < component2 { return .orderedAscending }
                if component1 > component2 { return .orderedDescending }
            }
            
            // Handle cases where versions have different lengths (e.g., "1.0" vs "1.0.1")
            if version1Components.count < version2Components.count {
                return .orderedAscending
            } else if version1Components.count > version2Components.count {
                return .orderedDescending
            }
            
            return .orderedSame
        }
    }
}
