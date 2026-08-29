# State, phases, and the scrubber

Short map. Use this when you share a bug, a screenshot, or a log.

## What the scrubber is

A local tool that makes a copy of state you can show someone else. It blacks out secrets. It does not send the copy anywhere. It works with the network unplugged.

It does not change the live VPN, the kill switch, or your saved sign-in.

## How to run it

From the repo, with the network off if you want proof:

```text
python3 scripts/scrub_core.py --source "path-to-dump" --output "path-to-clean-copy" --report report.json
```

On Windows you can call the same thing through `scripts/Scrub-SwissArmyVpnState.ps1`.

Print the colour key:

```text
powershell -File scripts/Scrub-SwissArmyVpnState.ps1 -PhaseMap
```

## What it blacks out

| Kind | Examples | Replacement |
| --- | --- | --- |
| secret | passwords, GitHub tokens, private keys, session tokens | `[secret]` |
| identity | home paths, emails, IP addresses | `[redacted]` |
| ai-id | lines that name an AI product or say "I am an AI" | `[removed]` |

If a secret is still readable after the pass, the tool fails. That is the witness.

## Justichuu's local witness

There is a second check on Justichuu's own machine. This repo does not have it. If that file is not present, the built-in checks still run, and the report says to ask later. That is on purpose.

Looked-for names, never downloaded:

- `%USERPROFILE%\Justichuu\witness\scrub.ps1`
- environment variable `JUSTICHUU_WITNESS`

The local witness must stay on disk. It must not upload the report.

## Phases of the widget

These are the states the window can show. The eye is the short version.

| Phase | What you see | Eye |
| --- | --- | --- |
| Disconnected | no tunnel, no kill switch | grey, half |
| Connecting | waiting on Windows | grey, half |
| Protected | tunnel up, kill switch on | green, shut |
| Connected without protection | tunnel up, kill switch off | red, open |
| Internet blocked | kill switch on, no tunnel | red, open |
| Protection incomplete | rules only half there | red, open |
| Firewall off | Windows Firewall is not protecting | red, open |
| Unavailable | Windows would not answer | grey, half |

## Colour key

| Colour | Hex | Meaning |
| --- | --- | --- |
| green | `#2CC478` | hidden / safe |
| red | `#E24448` | watched / stop |
| grey | `#808694` | not proven |
| connect green | `#1B8B5D` | go |
| disconnect red | `#B13F44` | stop |
| apply blue | `#375990` | change a setting |
| brown | `#744E2E` | forget the password |
| disabled | `#3F434C` | not available now |

Green and red stay opposite. Left column is go. Right column is stop. That symmetry is the map.

## What you may share

Share the clean copy and the report. Do not share `install-state.json`, update journals, or a raw diagnostic until they have been through this tool.

Online or offline, the rule is the same: the scrubber does not talk to the internet. If it ever does, it is broken.
