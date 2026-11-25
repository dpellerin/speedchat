# SpeedChat

SpeedChat is a native macOS quick-chat panel for conversations with OpenAI and OpenRouter models.

## Language

### Panel and conversation

**Panel**:
The keyboard-summoned window that shows either the active conversation (model picker, transcript, and composer) or History in place. An in-progress response can continue while the panel is hidden.

**Composer**:
The text entry area where the user writes and sends a message.

**Draft**:
The unsent text in the composer, preserved per conversation while the app is running.

**Conversation**:
The user's ongoing exchange with SpeedChat. It can continue across model and provider switches and can be reopened from saved messages if its Codex thread is unavailable.
_Avoid_: Codex thread, session, discussion

**Saved conversation**:
SpeedChat's local record of a conversation with at least one message. Its messages are the primary record when the conversation is reopened.

**History**:
The searchable list of saved conversations shown inside the panel for browsing, deleting, or reopening earlier conversations.
_Avoid_: archive, library, chat list

**Transcript**:
The messages shown in the panel for the current conversation, including the reply as it streams.

**Message**:
A user submission or an assistant reply in a conversation.

**Turn**:
One exchange initiated by sending a user message. A turn can complete, fail, or be stopped.

**Active turn**:
The turn whose response SpeedChat is preparing or receiving. It can be active before the provider starts work.

**Stop**:
The action that ends a turn’s response and keeps the submitted message in the conversation.

**New Chat**:
The action that starts a fresh conversation with an empty transcript and carries over the selected model.

### Providers and models

**Provider**:
A service SpeedChat uses to get model responses. The model picker groups its choices under OpenAI and OpenRouter.

**Model catalog**:
The available model choices in the picker, drawn from the connected Codex installation and the configured OpenRouter model list.

**Selected model**:
The model checked in the picker and requested for the next turn.

**Active model**:
The model shown in the panel header for the response. It can differ from the selected model when OpenAI reroutes the turn.

**Codex thread**:
The OpenAI-side record SpeedChat uses to continue a conversation through Codex. A conversation can have a Codex thread while an OpenRouter model is selected.

**Standalone OpenRouter**:
Using SpeedChat with OpenRouter while Codex is unavailable.

**Codex handoff**:
Continuing a standalone OpenRouter conversation on an OpenAI model by carrying its prior messages into a new Codex thread.

### Search and follow-ups

**Web search**:
An on-demand lookup through the provider for a turn that needs current information.

**Citation**:
A source link in an assistant reply that points to a web search result.

**Beam reasoning**:
Private response metadata used to continue a conversation with Beam. It stays out of the transcript and is reserved for Beam follow-ups.
