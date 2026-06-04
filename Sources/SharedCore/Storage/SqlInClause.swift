import Foundation

/// Builds the `(?, ?, …)` placeholder list + the sorted bind values for a
/// `col IN (...)` clause over a set of String-raw-valued enums.
///
/// Shared so the
/// `files.origin IN (...)` query in `FileRepository` and `ProjectStore` use one
/// definition (deterministic order → stable SQL). Callers bind `values` in
/// order after their fixed leading parameters.
enum SqlInClause {
    static func build<T: RawRepresentable & Hashable>(
        _ set: Set<T>
    ) -> (placeholders: String, values: [String]) where T.RawValue == String {
        let values = set.map(\.rawValue).sorted()
        let placeholders = values.map { _ in "?" }.joined(separator: ", ")
        return (placeholders, values)
    }
}
