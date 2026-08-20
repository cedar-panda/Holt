# Holt privacy notes

Holt is designed as a local-first application. This document describes the
open-source build; distributors should adapt it to their store listing and any
services they add.

## Stored on the device

- Conversations, character data, memories, summaries and usage records
- App preferences, downloaded models and user-selected media
- API credentials, which are stored through platform secure storage where the
  platform supports it

Android system backup and device-transfer extraction are excluded for app data.
User-controlled export and import is the supported migration mechanism. New
portable exports are encrypted with a user-supplied password; existing JSON and
`.holt.zip` exports remain importable for compatibility and must still be
treated as plaintext private data.

## Data sent off the device

When a remote provider is selected, the prompt and relevant conversation
context are sent to that provider or to the user-configured compatible
endpoint. Provider handling is governed by that provider's terms and privacy
policy. Voice, image, X/OAuth and model-download features contact their
respective service only when configured or invoked.

User-configured public OpenAI-compatible endpoints must use HTTPS. Plain HTTP
is accepted only for localhost, private-network IP addresses and `.local`
hosts, where transport security remains the user's network responsibility.

Local-model inference remains on the device after the required model files have
been downloaded. Android speech recognition behavior depends on the recognition
service installed on the device and may use that service's network processing.

### Optional web search

Web search is a developer preview and is disabled by default. Release builds
also exclude live execution unless the distributor explicitly enables it at
build time after reviewing the current provider terms, audience and available
regions. Enabling web search authorizes the app to execute detected explicit
web-search requests without a separate confirmation dialog before each search.
The in-chat search activity shows the outgoing request and selected providers
while the search runs. A provider may rewrite that request into one or more
underlying search queries.

- Gemini mode sends the outgoing request to the selected Gemini model and
  Google Search. Gemini Developer API is intended for professional or business
  use, and API clients must not be directed to or likely accessed by people
  under 18. Google states that grounding prompt, context and output data may be
  retained for 30 days. If the API project uses unpaid quota, Google may use
  submitted content and generated responses to improve its products, and human
  reviewers may process them. The app blocks credential-like text and some
  recognizable personal-data patterns, but this detection is not complete; do
  not submit personal, sensitive, confidential or identifying information.
- OpenRouter mode sends the outgoing request to OpenRouter, one inference
  endpoint dynamically selected for the explicitly named model, and the Exa
  web-search tool. The app asks OpenRouter to use a non-collecting Zero Data
  Retention inference endpoint and disables endpoint fallback. Router aliases,
  latest aliases, search-native models and the deprecated `:online` route are
  rejected because they would change the model or add another search path. The
  app asks OpenRouter to disable its legacy web plugin, but an organization can
  configure that plugin so clients cannot override it. The app cannot verify
  this account setting in advance; the user must not proceed unless they have
  confirmed that no default web plugin is enforced, otherwise an additional
  search route and charge may occur. The Exa server-tool route can have separate
  retention terms, and each recipient's terms and privacy policy apply.
- Dual mode sends the same outgoing request to both routes and counts as two
  provider launches. The two providers may create different underlying search
  queries, and their results, retention and charges remain separate.

Provider answers, snippets, source URLs, Gemini Search Suggestions and the
outgoing search request are kept only in memory for the current app session;
they are not added to chat history, model prompt cache, app export or replay
fixtures. The on-device usage ledger stores only operational metadata needed
for limits and cost reconciliation: opaque call/turn identifiers, provider,
route, selected model, timestamps, execution state, token/search counts,
reported cost and whether that cost is known. Replay mode does not contact a
provider or add live usage records.

## Deletion

Users can delete characters and conversations in the app or clear the app's
storage through Android settings. Remote providers may retain requests
according to their own policies; deleting local data cannot delete provider
records.

## Logs

Debug builds can emit diagnostic metadata to Android logs. Confirmed sensitive
paths log counts or error types instead of search text, credentials or provider
response bodies. Distributors should still use release builds and review any
new logging before publication.
