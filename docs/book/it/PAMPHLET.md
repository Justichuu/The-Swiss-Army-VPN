# Swiss Army VPN

Una pagina. Se ne leggi una sola, questa.

## Che cos’è

Una piccola finestra Windows per una VPN che Windows sa già usare. Può anche tagliare il resto di internet se quella VPN cade. Quel blocco si chiama kill switch (lucchetto).

Non è l’azienda NordVPN. Non è un servizio nuovo. Porti tu nome e password.

## Cosa fa al computer

- Aggiunge una VPN Windows chiamata Swiss Army VPN.
- Può accendere quattro regole firewall che bloccano internet normale.
- Può salvare nome e password. Windows li tiene.
- Può cambiare il server.

Non legge i tuoi file. Non tiene i siti visitati. Non tiene il token GitHub.

## Cosa non fa

Non esegue WireGuard o OpenVPN.

Non ti rende al sicuro da solo su una rete cattiva. Il lucchetto aiuta solo se è acceso e il tunnel è quello che l’app guarda.

## Inizio

1. Scarica lo zip dall’ultima Release su GitHub. Non il pulsante verde Code.
2. Apri la cartella. Lascia i file insieme.
3. Avvia `Install Swiss Army VPN.exe`. Windows chiede l’amministratore.
4. Apri l’app. SET UP SIGN-IN. Inserisci il login della tua VPN.
5. CONNECT + ARM per il lucchetto. CONNECT senza.

## Stop

DISCONNECT + UNLOCK.

Se la finestra non si apre e internet è morto: Emergency Unlock nel menu Start.

## Se ti blocchi

Il lucchetto può staccare tutto il computer. Prima sblocca.

Non mandare un log grezzo. Passa lo scrubber prima di condividere.

## Privacy

Le password restano in Windows. Niente viso, voce, o gioco a tempo.

Un problema di sicurezza: GitHub security advisories. Mai una password in una issue.

## Chi

Justichuu. Non ufficiale. GPL-3.0-only. Il codice si può leggere.
