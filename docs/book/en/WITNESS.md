# Witness

A change is not done until something failed before it and passed after it. That is the witness. A person may also film the same path. The film is not a test of the person’s body.

This follows ChuuMind: no CAPTCHA, no face video as proof of humanity, no timed puzzle, no “move the mouse naturally.” Those exclude people. They are refused here.

## What runs by itself

| Test | What it proves |
| --- | --- |
| `tests/Test-ManagedServerAddress.py` | Host names are accepted or refused on purpose |
| `tests/Test-StatePhaseScrubber.py` | Secrets do not survive a scrub |
| `scripts/Build-Release.ps1` | The Windows package matches its version and layout |

You can run the Python tests with no window and no camera. That is enough for a pull request.

## What a person may film

Only if they want a human to see the app, and only on a machine they control.

1. Run the automated tests. Keep the output.
2. Film the screen, not a face, unless they choose to be on camera.
3. Add captions. A transcript is better than none. See the template below.
4. No timer. Stopping to rest is fine.
5. Put the film next to the test output. One does not replace the other.

A good short demo:

1. Closed lock: DISCONNECT + UNLOCK
2. Sign-in is already saved, or show SET UP SIGN-IN without reading the password aloud
3. CONNECT + ARM
4. Eye green and shut
5. DISCONNECT + UNLOCK
6. Internet works again

That is the same path as `docs/media/vpn-working-demo/`. Keep new films in that spirit: the product, not a performance.

## Transcript template

```text
Title:
Date:
Machine: Windows 10 / 11
Build:
Automated tests: PASS / FAIL (paste the last lines)
Caption language:

[00:00] Window opens.
[00:00] Unlock is shown.
[00:00] Connect and arm.
[00:00] Eye is green and shut.
[00:00] Unlock.
[00:00] Done.
```

## Access

Any way of talking about the film counts: typed notes, email over days, voice, a letter board, an interpreter. Taking longer is not a fail.
