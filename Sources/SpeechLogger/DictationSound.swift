import AppKit

/// The dictation mode's only signal, with **two meanings**: the dictation failed, or
/// the text is ready but did not land (queued behind a braindump, the guard disarmed,
/// the grant withheld, the paste swallowed).
///
/// There is no success chime and no notification. The asymmetry is about presence, not
/// mode: a notification is for someone who walked away (braindump), a sound is for
/// someone sitting there staring at the cursor. The text appearing *is* the
/// confirmation, so a sound on the happy path would be noise on a mode used dozens of
/// times a day.
///
/// **Mandatory ordering: it plays after the paste decision, never before** — the caller
/// owns that, and it is why the decision returns a value instead of playing anything
/// itself. Playing it is safe there: a sound activates no app, so it cannot disarm the
/// guard it just ran behind (verified in the #39 prototype).
///
/// A sub-floor hold is silent — it never becomes an item, so nothing here is reached.
/// A protected web password field is silent too, undetectable by construction.
enum DictationSound {
    /// The system's error sound. Named rather than composed so it matches whatever the
    /// user already recognizes as "that did not work", and falls back to the alert beep
    /// if the system ever stops shipping it.
    private static let sound = NSSound(named: "Basso")

    /// Play it, restarting if one is already sounding — two dictations landing back to
    /// back should not swallow the second signal.
    static func play() {
        guard let sound else {
            NSSound.beep()
            return
        }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
