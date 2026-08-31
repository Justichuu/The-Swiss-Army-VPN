# Captions for the remaining-state film

The GIF is the live widget, not a redraw. Windows CI runs `Swiss Army VPN.exe --preview-state <name> --preview-output <file>.png` for each remaining state, then those stills are captioned into one loop.

This is a screen film. It is not a test of anyone’s body. No face. No timer. No CAPTCHA.

## Remaining states

| # | Name | Caption |
| --- | --- | --- |
| 1 | disconnected | Disconnected. Eye open. Normal internet. |
| 2 | connecting | Connecting and arming. Waiting on Windows. |
| 3 | protected | Connected and protected. Eye shut. Green. |
| 4 | working | Protected with live latency and traffic. |
| 5 | unprotected | VPN up, kill switch off. Eye open. Red. |
| 6 | blocked | VPN down, internet blocked. Eye shut. |
| 7 | incomplete | Kill switch setup incomplete. Unlock. |
| 8 | firewalloff | Windows Firewall is off. Cannot arm. |
| 9 | error | Status unavailable. Click Refresh. |

Busy wait screens (connect-only, arm-only, unlock-only) share the same blue “waiting for Windows” look. They are not extra product screens, so they are not extra stills.

Deleted extras stay gone: `working2`, `working3`, `firewalloff-empty`.

## Colour

- Green `#2CC478` and a shut eye: this machine is hidden. Tunnel up with the kill switch armed, or the kill switch is blocking everything.
- Red `#E24448` and an open eye: traffic can still be watched.
- Left is go. Right is stop.

## Refresh on Windows

After `scripts/Build-Release.ps1`:

```powershell
$exe = Get-ChildItem .\artifacts\builds -Recurse -Filter 'Swiss Army VPN.exe' |
  Where-Object { $_.Directory.Name -eq 'Executables' } |
  Select-Object -First 1
.\scripts\Render-WidgetStatePreviews.ps1 -WidgetExecutable $exe.FullName
```

Then, where ffmpeg exists:

```powershell
python3 .\scripts\assemble_widget_state_gif.py --input-directory .\artifacts\widget-previews
```

## Transcript

```text
Title: Swiss Army VPN remaining states
Date: 2026-08-31
Machine: Windows CI preview renderer, then captioned stills
Build: 1.5.0.0 widget from this branch
Automated tests: Test-DeadCodeGone.py
Caption language: English

[00:00] Disconnected. Eye open. Normal internet.
[00:02] Connecting and arming.
[00:04] Connected and protected. Eye shut.
[00:06] Protected with live latency.
[00:08] Connected without the kill switch.
[00:11] VPN down, internet blocked.
[00:13] Kill switch incomplete.
[00:15] Firewall off.
[00:17] Status unavailable.
```

Credentials never appear. Preview stills use the packaged default server name only.
