# Swiss Army VPN

A one-page note. If you read nothing else, read this.

## What this is

A small Windows window for a VPN that Windows already knows how to run. It can also lock the rest of the internet if that VPN drops. That lock is called a kill switch.

It is not NordVPN the company. It is not a new VPN service. You bring the login.

## What it does to your computer

- Adds one Windows VPN named Swiss Army VPN.
- Can turn on four firewall rules that block normal internet.
- Can save a username and password that Windows keeps.
- Can change which server that VPN calls.

It does not read your files. It does not keep a list of sites you visit. It does not keep your GitHub token.

## What it does not do

It does not run WireGuard or OpenVPN. Those are other programs.

It does not make you safe on a bad network by itself. The kill switch only helps if it is on and the tunnel is the one this app is watching.

## How to start

1. Get the zip from the latest GitHub Release. Do not use the green Code button. That zip is source, not the app.
2. Open the folder. Keep the files together.
3. Run `Install Swiss Army VPN.exe`. Windows will ask for administrator permission.
4. Open the app. Choose SET UP SIGN-IN. Type the username and password for your VPN.
5. Choose CONNECT + ARM if you want the lock. Choose CONNECT if you do not.

## How to stop

Choose DISCONNECT + UNLOCK.

If the window will not open and the internet is dead, run Emergency Unlock from the Start menu. That turns the lock off.

## If you get stuck

The lock can block the whole computer. That is the point. Unlock first. Then fix the login or the server.

Do not send a raw log to anyone. If you must share state, run the scrubber first. See the state and phases page.

## Your privacy

Passwords stay in Windows. This app does not print them. It does not need your face, your voice, or a timed puzzle.

Report a safety problem in GitHub security advisories. Do not put a password in an issue.

## Who made it

Justichuu. Unofficial. Licensed GPL-3.0-only. You can read the code.
