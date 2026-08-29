# Start here

This page assumes you have never installed a tool from GitHub.

## You need

- Windows 10 or Windows 11
- A VPN login that works with Windows IKEv2 (many paid VPNs have this; some only have their own app)
- Permission to say yes when Windows asks for administrator

You do not need to be a programmer.

## Get the app

1. Open https://github.com/Justichuu/The-Swiss-Army-VPN/releases/latest
2. Download the file named `Swiss Army VPN Distribution` and a version number. It ends in `.zip`.
3. Right-click the zip. Choose Extract All. Keep the folder as it is.

## Install

1. Open the extracted folder.
2. Double-click `Install Swiss Army VPN.exe`.
3. Read the warning. The kill switch can cut the whole computer off the internet. That is real.
4. Say yes only if you want that.
5. When it finishes, open Swiss Army VPN from the desktop or the Start menu.

## Sign in

1. Click SET UP SIGN-IN.
2. Type the username and password your VPN gave you for manual / IKEv2 / Windows setup. That is often not the same password as the website.
3. Save.

If you do not have those details, ask your VPN’s own help pages. This project does not sell logins and will not send you one.

## First good day

1. Click CONNECT + ARM.
2. The eye should go green and shut. That means the app thinks you are hidden.
3. Use the internet as you normally would.
4. When you are done, click DISCONNECT + UNLOCK.

If the eye is red and open, something is visible or blocked. Click REFRESH. If it stays wrong, unlock and stop.

## If the internet dies

1. Start menu → Swiss Army VPN → Emergency Unlock
2. Say yes to administrator
3. Wait until it says the lock is off

Then you can open the app again and try a calmer path.

## Private updates

Updates use GitHub CLI on the computer, signed in as a person who can read this repository. The app never stores that token. If that is too much, skip updates and install the next zip by hand.
