# DaScript

## Avvio rapido — DaScript Windows Update

Aprire **Windows PowerShell 5.1 come amministratore** ed eseguire:

```powershell
irm 'https://raw.githubusercontent.com/Capobuf/DaScript/main/windows/windows-update/bootstrap.ps1' | iex
```

Il comando scarica a ogni avvio l'**ultima versione pubblicata su `main`**, senza dover aggiornare l'URL. Installa aggiornamenti e può riavviare automaticamente il PC: salvare il lavoro prima di avviarlo. Su Windows Server chiede il consenso iniziale ai riavvii automatici: solo `s` autorizza l'avvio; Invio o qualsiasi altra risposta lo annullano. Vedere [opzioni, prerequisiti e rischi](windows/windows-update/README.md).

Raccolta di script PowerShell per **MSP, sysadmin e assistenza IT su Windows**. Obiettivo: automatizzare operazioni ricorrenti senza aggiungere complessità inutile.

## Script

| Script | Funzione | Stato |
| --- | --- | --- |
| [DaScript Windows Update](windows/windows-update/README.md) | Cerca, installa e verifica aggiornamenti Windows; gestisce riavvii e ripresa automatica | Prima versione |

## Piattaforme

Gli script sono progettati considerando Windows 10, Windows 11 e Windows Server dal 2019 con Desktop Experience, incluse varianti Enterprise, LTSC e IoT Enterprise. Server Core è escluso dal supporto. La compatibilità viene valutata attraverso documentazione Microsoft e controlli delle funzionalità disponibili; eventuali limitazioni specifiche sono riportate nel README dello script.

Le operazioni sensibili, in particolare i riavvii dei server, possono richiedere opzioni esplicite.

## Regole di sviluppo

Vedi [AGENTS.md](AGENTS.md): niente supposizioni, soluzioni native e semplici, controlli e test proporzionati, errori espliciti.

## Sicurezza

Gli script possono richiedere privilegi amministrativi ed eseguire modifiche al sistema. Leggere codice e README prima dell'uso, specialmente per esecuzioni remote con `irm | iex`. Provare prima in un ambiente di test.
