import NovaNetworkCore
import Foundation

extension NetworkClient {
    func executeWithHTTPAuthRefresh(
        _ context: NetworkClientHTTPExecutionContext
    ) async -> Result<NetworkResponse, NetworkError> {
        var currentContext = context
        var refreshAttempt = 0

        while true {
            let result = await httpExecutionPipeline.execute(currentContext)
            guard case .failure(let error) = result,
                  shouldRefreshAuthentication(after: error),
                  refreshAttempt < httpAuthRefreshPolicy.maxRefreshAttempts,
                  let provider = httpAuthRefreshProvider else {
                return result
            }

            do {
                let refreshedHeaders = try await httpAuthRefreshCoordinator.refresh(
                    authScope: context.authScope,
                    provider: provider
                )
                refreshAttempt += 1
                currentContext = NetworkClientHTTPExecutionContext(
                    key: context.key,
                    request: currentContext.request.withMergedHeaders(refreshedHeaders),
                    authScope: context.authScope,
                    retryPolicy: context.retryPolicy,
                    deadline: context.deadline,
                    coalescingMode: context.coalescingMode,
                    policyScope: context.policyScope
                )
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch {
                return .failure(.authenticationRefreshFailed(underlying: error))
            }
        }
    }

    private func shouldRefreshAuthentication(after error: NetworkError) -> Bool {
        guard case .httpStatus(let code, _, _) = error else { return false }
        return httpAuthRefreshPolicy.unauthorizedStatusCodes.contains(code)
    }
}
