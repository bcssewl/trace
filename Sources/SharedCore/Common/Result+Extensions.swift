import Foundation

extension Result where Failure == Error {
    /// Maps any throwing closure into a Result.
    public init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
