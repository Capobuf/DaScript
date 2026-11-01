# MSP Windows Update

Script PowerShell per la manutenzione unattended di Windows. Usa le API native Windows Update Agent (WUA) e una attività pianificata come `SYSTEM` per cercare, scaricare e installare aggiornamenti; riavvia quando necessario e riprende automaticamente dopo il boot, fino a due scansioni consecutive senza ulteriori aggiornamenti **eleggibili**.

**Stato:** prototipo. Codice verificato logicamente e contro le API Microsoft, **non eseguito né collaudato su Windows**. Non utilizzare direttamente in produzione senza test.

## Compatibilità prevista

- **Windows 10 / 11**: comprese, come obiettivo progettuale, Pro, Enterprise, Education, LTSC e IoT Enterprise.
- **Windows Server 2012 e successivi**: incluse edizioni Standard/Datacenter e installazioni Server Core, quando i componenti richiesti sono presenti.
- **Requisito:** Windows PowerShell **5.1**, diritti amministrativi, Windows Update Agent funzionante, attività pianificate e accesso alla sorgente aggiornamenti configurata (Windows Update, Microsoft Update se già abilitato, oppure WSUS).
- Server 2012/2012 R2 possono richiedere l'installazione separata di WMF 5.1 e sono fuori supporto ordinario. L'assenza di update visibili non prova che un sistema sia supportato o sicuro.
- Sulle edizioni IoT/Enterprise con **Unified Write Filter (UWF) attivo**, lo script **rifiuta l'avvio**: gli aggiornamenti rischiano di andare persi al riavvio. Usare la modalità di manutenzione UWF prevista da Windows.
- Non è stata ancora verificata la compatibilità reale delle singole edizioni e versioni qui elencate.

Il riconoscimento di client/server usa i dati del sistema operativo, non stringhe localizzate o liste di nomi delle edizioni.

## Avvio locale

Aprire **Windows PowerShell 5.1 come amministratore**.

Client Windows 10/11:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MSP-WindowsUpdate.ps1 -Action Start
```

Server (riavvio automatico autorizzato esplicitamente):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MSP-WindowsUpdate.ps1 -Action Start -AllowServerReboot -NoMonitor
```

Su Windows Server, senza `-AllowServerReboot`, l'avvio viene **bloccato prima di installare**. Questa protezione evita riavvii accidentali di server in produzione. Pianificare una finestra di manutenzione.

`-NoMonitor` permette di chiudere subito la console; il worker resta attivo. Per impostazione predefinita, la console iniziale mostra lo stato e accetta **S** per chiedere uno stop. **Dopo un riavvio la console non si riapre**: l'attività prosegue in background come `SYSTEM`.

## Avvio da URL GitHub

Il bootstrap scarica una **revisione fissata a un commit Git** dello script e non un file arbitrario del branch `main`. Il bootstrap deve essere aggiornato intenzionalmente quando lo script principale cambia.

Client (PowerShell amministrativa):

```powershell
irm 'https://raw.githubusercontent.com/Capobuf/DaScript/main/windows/windows-update/bootstrap.ps1' | iex
```

Server (con consenso ai riavvii):

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Capobuf/DaScript/main/windows/windows-update/bootstrap.ps1'))) -AllowServerReboot -NoMonitor
```

**Attenzione:** questi comandi eseguono codice scaricato da Internet con i privilegi della sessione. Verificare il contenuto del repository e del bootstrap prima di usarli su macchine di clienti.

## Stato e arresto

Il worker si copia in `C:\ProgramData\MSPTools\WindowsUpdate\MSP-WindowsUpdate.ps1`. Da PowerShell amministrativa:

```powershell
$script = "$env:ProgramData\MSPTools\WindowsUpdate\MSP-WindowsUpdate.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action Monitor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action Stop
```

`Stop` è **cooperativo**: non interrompe un'installazione già in corso; annulla, se ancora possibile, il riavvio pianificato. La finestra di monitoraggio non è necessaria per la prosecuzione dopo il boot.

I dati restano in:

```text
C:\ProgramData\MSPTools\WindowsUpdate\activity.log
C:\ProgramData\MSPTools\WindowsUpdate\state.json
C:\ProgramData\MSPTools\WindowsUpdate\state.json.bak
```

Gli stati conclusivi sono `Completed`, `CompletedWithErrors`, `Blocked` e `Stopped`. L'esito distingue update installati da errori e aggiornamenti esclusi.

## Politica aggiornamenti

- Rispetta la sorgente configurata dal PC/server e non modifica **WSUS, GPO, MDM** o le policy di Windows Update.
- Non installa, per impostazione predefinita, **driver, aggiornamenti facoltativi e upgrade di versione**. Le opzioni `-IncludeDrivers`, `-IncludeOptional`, `-IncludeFeatureUpgrades` modificano questa scelta; gli update beta e quelli che richiedono input restano esclusi.
- Non gestisce Microsoft Store, WinGet, applicazioni di terze parti o firmware fuori da WUA.
- Limiti predefiniti: **8 riavvii**, **3 tentativi per aggiornamento**, **3 errori generali consecutivi**, **30 passaggi per worker** e **7 giorni** per esecuzione. Retry periodico ogni **15 minuti**; riavvio richiesto con **90 secondi** di preavviso.
- Se il riavvio richiesto non avviene entro 15 minuti, registra `Blocked` anziché attendere indefinitamente.
- `Completed` significa solo che WUA non segnala ulteriori **aggiornamenti eleggibili nella sorgente configurata**. Non costituisce una verifica di sicurezza o supporto del sistema.

## Rischi e test necessari

I riavvii possono chiudere applicazioni e interrompere servizi. Prima del test, salvare i dati, avere un backup, verificare BitLocker/pre-boot PIN, alimentazione, accesso di rete e, sui server, la finestra di manutenzione.

Test manuali minimi prima dell'uso operativo:

1. Windows 11: nessun aggiornamento, due scansioni, stato finale e rimozione task.
2. Aggiornamento cumulativo che richiede un riavvio: ripresa senza login e convergenza.
3. Download fallito/rete assente: retry limitato, log e stato di errore affidabile.
4. `Stop` durante il lavoro e durante il countdown del riavvio.
5. Un Windows Server (preferibilmente Server Core): rifiuto senza `-AllowServerReboot`, quindi test autorizzato.
6. Dove disponibili: Windows 10 LTSC/IoT, UWF attivo (blocco previsto), policy WSUS.

**Non eseguiti:** tutti i test pratici sopra elencati. È necessario un ambiente Windows per convalidarli.

## Riferimenti

- [Windows Update Agent API](https://learn.microsoft.com/en-us/windows/win32/wua_sdk/portal-client)
- [Ricerca, download e installazione con WUA](https://learn.microsoft.com/en-us/windows/win32/wua_sdk/searching--downloading--and-installing-updates)
- [Scheduled Tasks PowerShell](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/register-scheduledtask)
- [Aggiornamenti di dispositivi protetti da UWF](https://learn.microsoft.com/en-us/windows/configuration/unified-write-filter/uwf-apply-windows-updates)
