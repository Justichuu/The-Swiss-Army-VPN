# Proposals

These are not built yet. They are the honest plan.

## Use

The old story: a lighter window for one Swiss NordVPN login.

A better story: a fail-closed lock around any IKEv2 login you already pay for. Home lab. Work. Another country. The Swiss list stays the default so a first install is still boring and safe.

Do not sell VPN accounts here. That is a different business and a worse trust story.

## Price

Free for people who use it and for people who build proof they can ship.

Charging for a lock that can take someone’s internet needs a help desk this project does not have. So the app stays free.

If the tools ever earn money, use the ChuuPayMe split: a fixed slice, divided by what people built, never a percent-per-person that cannot be paid. Nothing has been earned yet. That is fine.

Credential building means: you can point at a real witness (a test, a film, a merged change) without buying a seat.

## Docker, all systems

Ship two things. Do not pretend they are one.

| Image | What it is for | What it is not |
| --- | --- | --- |
| `swiss-army-vpn-tools` | tests, scrubber, this book, on Linux and Mac | not the tunnel |
| Windows host / future Windows container | the real app, RAS, firewall | not a laptop replacement in a cloud VM without care |

A Linux container cannot arm a Windows kill switch. Anyone who says it can is selling a demo.

Proposal, when someone is ready to build it:

```text
docker compose run --rm tools python3 tests/Test-StatePhaseScrubber.py
```

The compose file should mount the repo read-only, run offline, and write reports to a local folder. No secrets in the image.

Phones and other desktops: out of scope until Windows is boring.

## Remote

Remote help must not mean remote control of the lock. A stranger who can unlock or arm your computer is a stranger who can take your internet.

What is safe later:

1. You run the scrubber on your machine.
2. You send the clean report.
3. Someone reads it.

What is not safe:

- A back door
- A persistent admin tunnel
- “Just share your screen and the password”

GitHub already covers remote code: issues, releases, private updates through `gh`. That is enough remote for production of the bits. Production of the lock stays on the machine that can lose the internet.

## Production

Before calling a build production:

1. Automated witnesses pass on Windows CI
2. A person on a real PC walks START.md once
3. Emergency Unlock is tested while the lock is on
4. The scrubber is used on any log that leaves the house
5. Version, tag, and installer agree
6. The film, if any, has captions

Unsigned builds will still scare SmartScreen. Say so. The verifier checks checksums. It does not turn an unsigned file into a signed one.
