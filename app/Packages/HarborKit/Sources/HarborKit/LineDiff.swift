import Foundation

/// Line diff for the Edit/Write/MultiEdit cards.
public enum LineDiff {
    public enum Line: Equatable, Sendable { case same(String), added(String), removed(String), separator }

    /// LCS line diff; inputs beyond 600 lines each fall back to remove+add.
    public static func diff(_ a: String, _ b: String) -> [Line] {
        let x = a.isEmpty ? [] : a.components(separatedBy: "\n")
        let y = b.isEmpty ? [] : b.components(separatedBy: "\n")
        if x.count > 600 || y.count > 600 { return x.map { .removed($0) } + y.map { .added($0) } }
        let n = x.count, m = y.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = x[i] == y[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < n && j < m {
            if x[i] == y[j] { out.append(.same(x[i])); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { out.append(.removed(x[i])); i += 1 }
            else { out.append(.added(y[j])); j += 1 }
        }
        while i < n { out.append(.removed(x[i])); i += 1 }
        while j < m { out.append(.added(y[j])); j += 1 }
        return out
    }
}

