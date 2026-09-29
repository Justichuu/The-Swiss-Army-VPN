# Swiss Army VPN

Eine Seite. Wenn du nur eine liest, dann diese.

## Was das ist

Ein kleines Windows-Fenster für ein VPN, das Windows schon kann. Es kann das restliche Internet sperren, wenn das VPN fällt. Diese Sperre heißt Kill Switch (Schloss).

Das ist nicht die Firma NordVPN. Das ist kein neuer Dienst. Du bringst Login und Passwort mit.

## Was es am Rechner tut

- Legt ein Windows-VPN namens Swiss Army VPN an.
- Kann vier Firewall-Regeln einschalten, die normales Internet sperren.
- Kann Benutzer und Passwort speichern. Windows behält sie.
- Kann den Server wechseln.

Es liest deine Dateien nicht. Es merkt sich keine besuchten Seiten. Es behält dein GitHub-Token nicht.

## Was es nicht tut

Kein WireGuard. Kein OpenVPN.

Es macht ein schlechtes Netz nicht allein sicher. Das Schloss hilft nur, wenn es an ist und der Tunnel der ist, den die App kennt.

## Start

1. Zip von der letzten GitHub-Release holen. Nicht den grünen Code-Knopf.
2. Ordner öffnen. Dateien zusammenlassen.
3. `Install Swiss Army VPN.exe` starten. Windows fragt nach Administrator.
4. App öffnen. SET UP SIGN-IN. VPN-Login eintragen.
5. CONNECT + ARM für das Schloss. CONNECT ohne.

## Stopp

DISCONNECT + UNLOCK.

Geht das Fenster nicht auf und das Netz ist tot: Emergency Unlock im Startmenü.

## Wenn es hakt

Das Schloss kann den ganzen Rechner vom Netz nehmen. Erst entsperren. Dann Login oder Server prüfen.

Keine rohen Logs schicken. Erst den Scrubber laufen lassen.

## Privatsphäre

Passwörter bleiben in Windows. Kein Gesicht, keine Stimme, kein Zeitspiel.

Sicherheitsproblem: GitHub security advisories. Nie ein Passwort in ein Issue.

## Wer

Justichuu. Inoffiziell. GPL-3.0-only. Der Code ist lesbar.
