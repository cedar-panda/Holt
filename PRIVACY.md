# Holt privacy notes

Holt is designed as a local-first application. This document describes the
open-source build; distributors should adapt it to their store listing and any
services they add.

## Stored on the device

- Conversations, character data, memories, summaries and usage records
- App preferences, downloaded models and user-selected media
- API credentials, which are stored through platform secure storage where the
  platform supports it

Android system backup is disabled for the app. User-controlled JSON export and
import is the supported migration mechanism. Exported JSON may contain private
conversation data and should be protected by the user.

## Data sent off the device

When a remote provider is selected, the prompt and relevant conversation
context are sent to that provider or to the user-configured compatible
endpoint. Provider handling is governed by that provider's terms and privacy
policy. Voice, image, X/OAuth and model-download features contact their
respective service only when configured or invoked.

Local-model inference remains on the device after the required model files have
been downloaded. Android speech recognition behavior depends on the recognition
service installed on the device and may use that service's network processing.

## Deletion

Users can delete characters and conversations in the app or clear the app's
storage through Android settings. Remote providers may retain requests
according to their own policies; deleting local data cannot delete provider
records.

## Logs

Debug builds can emit diagnostic information to Android logs. Distributors
should use release builds and review logging before publication.
