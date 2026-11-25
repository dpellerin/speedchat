import Foundation
import Testing
@testable import ChatCore

private func writeSavedConversation(
    _ conversation: SavedConversation,
    to stateURL: URL
) throws {
    try StateStore.saveActiveConversation(conversation, to: stateURL)
}

@Test func searchMatchesAllWordsCaseInsensitivelyRanksTitleMatchesFirstAndExcludesBeamReasoning() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-search-rank-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")

    // Newer conversation: matches "espresso" and "burr" only in body (not all terms in title).
    let bodyOnlyNewer = SavedConversation(
        id: "conv-body-newer",
        title: "Morning coffee notes",
        createdAt: "2026-04-05T10:00:00.000Z",
        updatedAt: "2026-04-05T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-1",
        messages: [
            ChatMessage(id: "b1-u1", role: "user", text: "Dialing in ESPRESSO shots today."),
            ChatMessage(id: "b1-a1", role: "assistant", text: "Try adjusting the BURR spacing slightly finer."),
        ]
    )

    // Older conversation: matches ALL query words in title -> must rank ahead of bodyOnlyNewer!
    let titleMatchOlder = SavedConversation(
        id: "conv-title-older",
        title: "Espresso burr grinder guide",
        createdAt: "2026-04-01T10:00:00.000Z",
        updatedAt: "2026-04-01T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-2",
        messages: [
            ChatMessage(id: "t1-u1", role: "user", text: "Compare flat and conical designs."),
            ChatMessage(id: "t1-a1", role: "assistant", text: "Both styles work well for espresso."),
        ]
    )

    // Medium-age conversation: also matches ALL query words in title -> must rank ahead of titleMatchOlder by updatedAt!
    let titleMatchNewer = SavedConversation(
        id: "conv-title-newer",
        title: "Best BURR for espresso",
        createdAt: "2026-04-03T10:00:00.000Z",
        updatedAt: "2026-04-03T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-3",
        messages: [
            ChatMessage(id: "t2-u1", role: "user", text: "What burr size is ideal for espresso?"),
        ]
    )

    // Partial match: only contains "espresso", missing "burr" -> must NOT match.
    let partialOnly = SavedConversation(
        id: "conv-partial",
        title: "Espresso machine cleaning",
        createdAt: "2026-04-06T10:00:00.000Z",
        updatedAt: "2026-04-06T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-4",
        messages: [
            ChatMessage(id: "p1-u1", role: "user", text: "How do I backflush my espresso machine?"),
        ]
    )

    // Reasoning-only match: "burr" appears ONLY inside private Beam reasoning -> must NOT match!
    let reasoningOnly = SavedConversation(
        id: "conv-beam-reasoning",
        title: "Espresso roast levels",
        createdAt: "2026-04-07T10:00:00.000Z",
        updatedAt: "2026-04-07T10:00:00.000Z",
        model: "openrouter/beam-test",
        threadId: "openrouter-beam",
        messages: [
            ChatMessage(id: "r1-u1", role: "user", text: "Light vs medium espresso roasts?"),
            ChatMessage(
                id: "r1-a1",
                role: "assistant",
                text: "Medium roasts balance sweetness and acidity.",
                reasoning: "PRIVATE BEAM REASONING ABOUT BURR GEOMETRY AND ESPRESSO GRINDERS"
            ),
        ]
    )

    for conv in [titleMatchOlder, titleMatchNewer, bodyOnlyNewer, partialOnly, reasoningOnly] {
        try writeSavedConversation(conv, to: stateURL)
    }

    let fixtureNow = try #require(StateStore.parseTimestamp("2026-04-08T10:00:00Z"))
    let options = ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"),
        stateURL: stateURL,
        env: [:],
        now: { fixtureNow }
    )
    let rpc = FakeCodexTransport()
    let client = ChatClient(rpc: rpc, options: options)
    _ = try await client.connect()

    let results = client.listHistory(query: "  EsPrEsSo   burr ")
    #expect(results.map(\.id) == ["conv-title-newer", "conv-title-older", "conv-body-newer"])

    // Whitespace-only query acts as empty query (all conversations, newest first).
    let all = client.listHistory(query: "   \n  ")
    #expect(all.map(\.id) == [
        "conv-beam-reasoning",
        "conv-partial",
        "conv-body-newer",
        "conv-title-newer",
        "conv-title-older",
    ])
    #expect(all.allSatisfy { $0.firstMatchingMessageId == nil && $0.titleMatchRanges.isEmpty && $0.previewMatchRanges.isEmpty })

    // Query with no hits returns empty list.
    #expect(client.listHistory(query: "quantum xylophone").isEmpty)

    await client.close()
}

private func extractedMatches(in text: String, ranges: [HistoryMatchRange]) -> [String] {
    ranges.map { range in
        let start = text.index(text.startIndex, offsetBy: range.start)
        let end = text.index(text.startIndex, offsetBy: range.end)
        return String(text[start..<end])
    }
}

@Test func searchBuildsCenteredHighlightedSnippetsSelectsFirstMatchingMessageAndWorksOffline() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-search-snippet-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stateURL = dir.appendingPathComponent("state.json")

    let longPrefix = String(repeating: "Introductory discussion about travel logistics. ", count: 6)
    let longSuffix = String(repeating: " Additional closing remarks for the itinerary.", count: 6)
    let deepMessageText = longPrefix + "Ride Tram 28 through historic Alfama at sunrise." + longSuffix

    let lisbon = SavedConversation(
        id: "conv-lisbon",
        title: "Portugal coastal itinerary",
        createdAt: "2026-04-02T10:00:00.000Z",
        updatedAt: "2026-04-02T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-lisbon",
        messages: [
            ChatMessage(id: "m1", role: "user", text: "Plan a relaxed trip to Portugal."),
            ChatMessage(id: "m2", role: "assistant", text: "Start in Lisbon for three days."),
            ChatMessage(id: "m3", role: "assistant", text: deepMessageText),
            ChatMessage(id: "m4", role: "assistant", text: "Later mention of Alfama cafes and Tram schedules."),
        ]
    )

    // Cross-message match: "portugal" in title & m1, "pastel" only in m3.
    let pastries = SavedConversation(
        id: "conv-pastries",
        title: "Portugal food list",
        createdAt: "2026-04-01T10:00:00.000Z",
        updatedAt: "2026-04-01T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-pastries",
        messages: [
            ChatMessage(id: "p1", role: "user", text: "What should I eat in Portugal?"),
            ChatMessage(id: "p2", role: "assistant", text: "Grilled sardines are everywhere."),
            ChatMessage(id: "p3", role: "assistant", text: "Be sure to try warm Pastel de Nata in Belem."),
        ]
    )

    // Title-only match where messages do not contain the searched word.
    let titleOnly = SavedConversation(
        id: "conv-title-only",
        title: "Ceramics studio checklist",
        createdAt: "2026-04-03T10:00:00.000Z",
        updatedAt: "2026-04-03T10:00:00.000Z",
        model: "gpt-6-luna",
        threadId: "codex-title-only",
        messages: [
            ChatMessage(id: "c1", role: "user", text: "Pack aprons and towels."),
        ]
    )

    for conv in [pastries, lisbon, titleOnly] {
        try writeSavedConversation(conv, to: stateURL)
    }

    // Run completely offline (Codex fails to start, no OpenRouter key configured).
    let offlineRPC = FakeCodexTransport()
    offlineRPC.failStart = true
    let fixtureNow = try #require(StateStore.parseTimestamp("2026-04-08T10:00:00Z"))
    let options = ChatClientOptions(
        openRouterConfigURL: dir.appendingPathComponent("openrouter.json"),
        stateURL: stateURL,
        env: [:],
        now: { fixtureNow }
    )
    let client = ChatClient(rpc: offlineRPC, options: options)
    let initial = try await client.connect()
    #expect(initial.offlineReason != nil)

    // Deep multi-word match centers snippet around the match, highlights all matched words,
    // and targets the first message matching both terms (m3, not m4).
    let deepHits = client.listHistory(query: "alfama tram")
    let lisbonHit = try #require(deepHits.first)
    #expect(deepHits.count == 1)
    #expect(lisbonHit.id == "conv-lisbon")
    #expect(lisbonHit.firstMatchingMessageId == "m3")
    #expect(lisbonHit.preview.hasPrefix("…"))
    #expect(lisbonHit.preview.hasSuffix("…"))
    #expect(lisbonHit.preview.count <= 160)
    #expect(extractedMatches(in: lisbonHit.preview, ranges: lisbonHit.previewMatchRanges) == ["Tram", "Alfama"])

    // Cross-message match highlights title term AND jumps to the body message matching the non-title term.
    let pastryHits = client.listHistory(query: "portugal pastel")
    let pastryHit = try #require(pastryHits.first)
    #expect(pastryHit.id == "conv-pastries")
    #expect(pastryHit.firstMatchingMessageId == "p3")
    #expect(extractedMatches(in: pastryHit.title, ranges: pastryHit.titleMatchRanges) == ["Portugal"])
    #expect(extractedMatches(in: pastryHit.preview, ranges: pastryHit.previewMatchRanges) == ["Pastel"])

    // Title-only match highlights the title and leaves firstMatchingMessageId nil.
    let titleHits = client.listHistory(query: "ceramics")
    let titleHit = try #require(titleHits.first)
    #expect(titleHit.id == "conv-title-only")
    #expect(titleHit.firstMatchingMessageId == nil)
    #expect(extractedMatches(in: titleHit.title, ranges: titleHit.titleMatchRanges) == ["Ceramics"])
    #expect(titleHit.preview == "Pack aprons and towels.")

    await client.close()
}

@Test func sessionTracksScrollTargetMessageIdAcrossReadyOfflineSendAndNewChat() {
    var session = ChatSession()
    let models = [ChatModel(model: "gpt-6-luna", displayName: "GPT-6 Luna", provider: "openai")]
    let messages = [
        ChatMessage(id: "m1", role: "user", text: "First"),
        ChatMessage(id: "m2", role: "assistant", text: "Second"),
    ]

    // Opening from a search hit sets scrollTargetMessageId and rotates transcriptID.
    session.receive(BridgeEvent(
        type: "ready",
        conversationId: "conv-a",
        messages: messages,
        models: models,
        model: "gpt-6-luna",
        scrollToMessageId: "m1"
    ))
    let firstTranscriptID = session.transcriptID
    #expect(session.conversationId == "conv-a")
    #expect(session.scrollTargetMessageId == "m1")

    // Re-selecting the SAME active conversation from another search hit rotates transcriptID again
    // and updates scrollTargetMessageId.
    session.receive(BridgeEvent(
        type: "ready",
        conversationId: "conv-a",
        messages: messages,
        models: models,
        model: "gpt-6-luna",
        scrollToMessageId: "m2"
    ))
    #expect(session.transcriptID != firstTranscriptID)
    #expect(session.scrollTargetMessageId == "m2")

    // Sending a message clears scrollTargetMessageId so the transcript follows the new turn.
    let sentText = session.beginSend("Follow up")
    #expect(sentText == "Follow up")
    #expect(session.scrollTargetMessageId == nil)
    session.receive(BridgeEvent(type: "done", conversationId: "conv-a", executionID: session.executionID))

    // Opening while offline preserves scrollTargetMessageId.
    session.receive(BridgeEvent(
        type: "offlineConversation",
        conversationId: "conv-a",
        messages: messages,
        models: [],
        model: "gpt-6-luna",
        notice: "Offline · Codex unavailable",
        scrollToMessageId: "m1"
    ))
    #expect(session.phase == .offline)
    #expect(session.scrollTargetMessageId == "m1")

    // Opening with empty query clears scrollTargetMessageId (scrolls to bottom).
    session.receive(BridgeEvent(
        type: "ready",
        conversationId: "conv-a",
        messages: messages,
        models: models,
        model: "gpt-6-luna"
    ))
    #expect(session.scrollTargetMessageId == nil)

    // Starting New Chat also clears any scrollTargetMessageId.
    session.receive(BridgeEvent(
        type: "ready",
        conversationId: "conv-a",
        messages: messages,
        models: models,
        model: "gpt-6-luna",
        scrollToMessageId: "m1"
    ))
    let startedNewChat = session.beginNewChat()
    #expect(startedNewChat)
    #expect(session.scrollTargetMessageId == nil)

    // Consuming a scroll target returns it once and clears it so a remounted transcript cannot re-jump.
    session.receive(BridgeEvent(
        type: "ready",
        conversationId: "conv-a",
        messages: messages,
        models: models,
        model: "gpt-6-luna",
        scrollToMessageId: "m2"
    ))
    #expect(session.consumeScrollTarget() == "m2")
    #expect(session.scrollTargetMessageId == nil)
    #expect(session.consumeScrollTarget() == nil)

    // Clearing a scroll target explicitly (e.g. clicking Latest or opening History) clears it.
    session.receive(BridgeEvent(
        type: "ready",
        conversationId: "conv-a",
        messages: messages,
        models: models,
        model: "gpt-6-luna",
        scrollToMessageId: "m1"
    ))
    session.clearScrollTarget()
    #expect(session.scrollTargetMessageId == nil)
}


