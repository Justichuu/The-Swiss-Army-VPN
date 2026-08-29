# VPN server selector manual test

Run these checks on a disposable feature build before publishing a release. Compilation and the widget preview do not prove that Windows RAS, DNS, firewall state, elevation, or rollback works on the installed machine.

## Preconditions

1. Record the current server from the widget and from elevated PowerShell:

   ```powershell
   Get-VpnConnection -Name 'Swiss Army VPN' -AllUserConnection | Select-Object Name,ServerAddress,ConnectionStatus
   ```

2. Confirm **DISCONNECT + UNLOCK** leaves the VPN disconnected and no managed kill-switch rules remain.
3. Keep **Emergency Unlock** available before testing connection or firewall behavior.

## Swiss dropdown

1. Open the dropdown and confirm the packaged Swiss servers appear.
2. Select a different `ch<number>.nordvpn.com` entry and choose **APPLY**.
3. Approve elevation.
4. Confirm the widget displays the new hostname.
5. Rerun `Get-VpnConnection` and confirm `ServerAddress` exactly matches.
6. Close and reopen the widget; confirm the selection persists.
7. Connect and arm, then confirm protected status and normal traffic through the VPN.

## Custom NordVPN country

1. Disconnect and unlock.
2. With the mode set to **Swiss NordVPN**, enter a known non-Swiss numbered NordVPN hostname. Confirm Apply rejects it before elevation.
3. Switch the mode to **Any NordVPN**, enter the same hostname, and apply it.
4. Confirm the widget, `Get-VpnConnection`, and a restarted widget all show the same hostname.
5. Connect and arm. Confirm the tunnel connects and the kill switch reports protected.
6. Run the application's diagnostic output and confirm `RESULT: PASS`, the expected server, and at least one server IPv4 address.

## Bring your own

1. Disconnect and unlock.
2. With the mode set to **Swiss NordVPN** or **Any NordVPN**, enter `ikev2.example.com` or another non-NordVPN hostname. Confirm Apply rejects it before elevation.
3. Switch the mode to **Bring your own**, enter a real IKEv2 hostname you control (or a lab IPv4 such as `10.0.0.1`), and apply it.
4. Confirm the widget, `Get-VpnConnection`, `VPN Server.txt`, and a restarted widget all show the same value.
5. Close and reopen the widget. Confirm upgrade, uninstall, and Emergency Unlock still accept the installation record.
6. Save that provider's username and password with **SET UP SIGN-IN**, then connect and arm. Confirm protected status.
7. Confirm URLs, ports, `127.0.0.1`, IPv6 literals, and shell punctuation are still rejected in bring-your-own mode.

## Safety and failure behavior

1. While connected, attempt a server change. Confirm it fails and the existing tunnel/server remain unchanged.
2. Disconnect without unlocking and attempt a change. Confirm it fails while managed firewall rules remain.
3. In Swiss or Any NordVPN mode, enter `example.com`, `ch.nordvpn.com`, `ch123.example.com`, an IP address, and command-line punctuation. Confirm each is rejected. In bring-your-own mode, confirm only the punctuation, URLs, ports, loopback, link-local, multicast, and IPv6 literals are rejected.
4. Enter a syntactically valid but nonexistent NordVPN hostname. Confirm DNS failure leaves the widget, RAS profile, `VPN Server.txt`, and install state on the previous server.
5. Cancel administrator approval. Confirm no server value changes.
6. Return to a known working Swiss server, reconnect, and repeat the protected-status check.

Do not call the feature release-ready until the installed widget, RAS profile, kill switch, persistence, and rollback checks all pass on the real machine.
