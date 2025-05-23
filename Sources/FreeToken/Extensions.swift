//
//  Extensions.swift
//  FreeToken
//
//  Created by Vince Francesi on 5/16/25.
//

extension Array where Element: Sendable {
    func concurrentMap<T: Sendable>(
        _ transform: @Sendable @escaping (Element) async throws -> T
    ) async rethrows -> [T] {
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            for (index, element) in self.enumerated() {
                group.addTask {
                    let result = try await transform(element)
                    return (index, result)
                }
            }
            
            var results = Array<T?>(repeating: nil, count: count)
            
            for try await (index, result) in group {
                results[index] = result
            }
            
            return results.map { $0! }
        }
    }
}
