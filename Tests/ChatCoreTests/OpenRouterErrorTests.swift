import Foundation
import Testing
@testable import ChatCore

@Test func openRouterProviderErrorsIncludeNestedReasonAndProvider() {
    let body = #"{"error":{"message":"Provider returned error","code":400,"metadata":{"provider_name":"Example provider","raw":"{\"error\":{\"message\":\"Unsupported request parameter: reasoning_effort\"}}"}}}"#
    let error = OpenRouterClient.extractError(status: 400, bodyText: body)
    #expect(error.status == 400)
    #expect(error.rawBody == body)
    #expect(error.message.contains("Example provider"))
    #expect(error.message.contains("Unsupported request parameter: reasoning_effort"))
    #expect(error.message.contains("400"))
}

@Test func openRouterErrorsAreNotRewrittenAsCodexFailures() {
    let error = OpenRouterClient.extractError(status: 429, bodyText: #"{"error":{"message":"Rate limit exceeded"}}"#)
    #expect(StateStore.friendlyError(error) == error.message)
}

@Test func openRouterStreamErrorsRetainProviderStatusAndReason() async throws {
    let payload = #"{"error":{"message":"Provider returned error","code":503,"metadata":{"provider_name":"Example provider","raw":"Upstream temporarily unavailable","error_type":"provider_unavailable"}}}"#
    let fetch: OpenRouterFetch = { _ in
        OpenRouterHTTPResponse(statusCode: 200, lines: AsyncThrowingStream { continuation in
            continuation.yield("data: \(payload)")
            continuation.finish()
        })
    }
    do {
        _ = try await OpenRouterClient.streamTurn(OpenRouterStreamOptions(
            key: "test-key", model: "reflection/beam-1.0-501b-a23b", instructions: "Test",
            messages: [], onDelta: { _ in }, onSearching: {}, fetch: fetch
        ))
        Issue.record("Expected the provider error to be thrown")
    } catch let error as OpenRouterHTTPError {
        #expect(error.status == 503)
        #expect(error.message.contains("Example provider"))
        #expect(error.message.contains("Upstream temporarily unavailable"))
        #expect(error.message.contains("provider_unavailable"))
    }
}
