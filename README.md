# DaScript

Raccolta di script PowerShell per **MSP, sysadmin e assistenza IT su Windows**. Obiettivo: automatizzare operazioni ricorrenti senza aggiungere complessità inutile.

## Script

| Script | Funzione | Stato |
| --- | --- | --- |
| [MSP Windows Update](windows/windows-update/README.md) | Cerca, installa e verifica aggiornamenti Windows; gestisce riavvii e ripresa automatica | Prima versione |

## Piattaforme

Gli script sono progettati considerando Windows 10, Windows 11 e Windows Server, incluse varianti Enterprise, LTSC, IoT e Server Core dove applicabile. La compatibilità viene valutata attraverso documentazione Microsoft e controlli delle funzionalità disponibili; eventuali limitazioni specifiche sono riportate nel README dello script.

Le operazioni sensibili, in particolare i riavvii dei server, possono richiedere opzioni esplicite.

## Regole di sviluppo

Vedi [AGENTS.md](AGENTS.md): niente supposizioni, soluzioni native e semplici, controlli e test proporzionati, errori espliciti.

## Sicurezza

Gli script possono richiedere privilegi amministrativi ed eseguire modifiche al sistema. Leggere codice e README prima dell'uso, specialmente per esecuzioni remote con `irm | iex`. Provare prima in un ambiente di test.
