#!/usr/bin/env bash
# Shared constants for the signing-identity scripts. Sourced, not executed.
# Keeps the identity name and keychain path in one place across
# create/delete/verify.

# Must match CODE_SIGN_IDENTITY in Project.swift.
IDENTITY_CN="speech-logger-selfsigned"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

# The app's fixed bundle id (Project.swift), used to locate a built .app and to
# assert the designated requirement.
BUNDLE_ID="app.speech-logger.SpeechLogger"
