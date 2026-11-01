# MSP Windows Update

Script PowerShell per la manutenzione unattended di Windows. Usa le API native Windows Update Agent (WUA) e una attività pianificata come `SYSTEM` per cercare, scaricare e installare aggiornamenti; riavvia quando necessario e riprende automaticamente dopo il boot, fino a due scansioni consecutive senza ulteriori aggiornamenti **eleggibili**.

**Stato:** sviluppo. Compatibilità progettata sulle API Microsoft; i controlli di sintassi e dei flussi isolati non sostituiscono il collaudo di installazione, firmware, upgrade e ripresa su VM/snapshot o hardware di prova.

## Compatibilità prevista

- **Windows 10 / 11**: comprese, come obiettivo progettuale, Pro, Enterprise, Education, LTSC e IoT Enterprise.
- **Windows Server 2019 e successivi con Desktop Experience**: incluse edizioni Standard/Datacenter. **Server Core è escluso** e viene rifiutato prima di iniziare gli aggiornamenti.
- **Requisito:** Windows PowerShell **5.1**, diritti amministrativi, Windows Update Agent funzionante, attività pianificate e accesso alla sorgente aggiornamenti configurata (Windows Update, Microsoft Update se già abilitato, oppure WSUS). Il worker usa un piccolo callback COM compilato con `Add-Type`: policy che vietano la compilazione/esecuzione devono essere gestite dall'amministratore, non vengono aggirate.
- Sulle edizioni IoT/Enterprise con **Unified Write Filter (UWF) attivo**, lo script **rifiuta l'avvio**: gli aggiornamenti rischiano di andare persi al riavvio. Usare la modalità di manutenzione UWF prevista da Windows.

Il riconoscimento di client/server usa i dati del sistema operativo, non stringhe localizzate o liste di nomi delle edizioni.
La distinzione Windows 10/11 usa versione e build (Windows 11 parte da 22000); il minimo Server è la build 17763. Il tipo di installazione Server viene letto da `InstallationType` nel registro.

## Avvio locale

Aprire **Windows PowerShell 5.1 come amministratore**.

Client Windows 10/11:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MSP-WindowsUpdate.ps1 -Action Start
```

Su **Windows 10**, prima dell'avvio compare una sola domanda:

```text
Esegui anche aggiornamento a Windows 11? [s/N]
```

Invio oppure `n` mantiene Windows 10; `s` autorizza anche il passaggio a Windows 11 e i relativi riavvii. La scelta viene salvata e non viene richiesta dal worker, neppure dopo il riavvio. Su Windows 11 e Server la domanda non compare.

Per esecuzioni unattended scegliere esplicitamente `-Windows11Upgrade Allow` oppure `-Windows11Upgrade Skip`; senza una scelta, un avvio Windows 10 non interattivo viene rifiutato. `-NoMonitor` disabilita soltanto il monitor, non la domanda iniziale.

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\MSP-WindowsUpdate.ps1 -Action Start -Windows11Upgrade Allow -NoMonitor
```

`Allow` è accettato soltanto quando si avvia da Windows 10. Consente gli upgrade classificati come **Upgrades** che riportano il nome **Windows 11** nel titolo WUA, anche se facoltativi; non abilita indiscriminatamente gli altri upgrade. Il titolo è un filtro conservativo, non una proprietà strutturata della versione di destinazione: offerte non riconoscibili vengono escluse e segnalate. `-IncludeFeatureUpgrades` da solo non autorizza il passaggio Windows 10 → 11.

Lo script usa solo le offerte della sorgente configurata: non modifica requisiti TPM/CPU/Secure Boot, policy, canale LTSC/IoT o licenze e non scarica ISO/Installation Assistant. La disponibilità dell'upgrade non è garantita per ogni dispositivo o edizione. Il completamento viene confermato soltanto rilevando Windows 11 dopo il riavvio; se l'upgrade richiesto non viene offerto o non si completa, l'esito è `CompletedWithErrors`, con dettaglio `NotOffered` o `NotCompleted`.

Server (riavvio automatico autorizzato esplicitamente):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MSP-WindowsUpdate.ps1 -Action Start -AllowServerReboot
```

Su Windows Server, senza `-AllowServerReboot`, l'avvio viene **bloccato prima di installare**. Questa protezione evita riavvii accidentali di server in produzione. Pianificare una finestra di manutenzione.

Il comando avvia un **monitor Windows Forms separato**, con fase, percentuale WUA quando disponibile, aggiornamento corrente, conteggi, countdown e log. Il lavoro prosegue come `SYSTEM`, anche chiudendo la finestra o senza login.

Un secondo task riapre il monitor **al login dello stesso account che ha avviato lo script**, con token interattivo elevato e senza salvare password. A fine lavoro la finestra rimane aperta; chiudendola si rimuove il task del monitor. Se il lavoro finisce senza utente connesso, l'esito appare al login successivo. Non viene modificato l'accesso automatico di Windows.

Il suono di sistema **Asterisk** viene richiesto una sola volta per esecuzione e soltanto per `Completed`; audio disponibile, volume e schema sonoro dipendono dalla sessione. Errori, blocchi e arresti hanno un esito visivo distinto e non producono il suono di successo. `-NoMonitor` disabilita finestra, riapertura al login e suono; è necessario per l'avvio da una sessione di servizio senza desktop.

## Avvio da URL GitHub

I comandi seguenti fissano il bootstrap alla revisione `93f7d68f58e4d3d70c32337964e7137eaab8d1d1`, che scarica il worker `bb5447cb5aa9b7a2aefe41ea47bcdee8668bbcc1`. Entrambi gli URL usano **commit Git immutabili**; il bootstrap deve essere aggiornato intenzionalmente quando lo script principale cambia.

Client (PowerShell amministrativa):

```powershell
irm 'https://raw.githubusercontent.com/Capobuf/DaScript/93f7d68f58e4d3d70c32337964e7137eaab8d1d1/windows/windows-update/bootstrap.ps1' | iex
```

Server (con consenso ai riavvii):

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Capobuf/DaScript/93f7d68f58e4d3d70c32337964e7137eaab8d1d1/windows/windows-update/bootstrap.ps1'))) -AllowServerReboot
```

Il bootstrap accetta anche `-Windows11Upgrade Allow|Skip` per scegliere senza domanda iniziale e `-NoMonitor` per esecuzioni senza interfaccia. Driver e facoltativi sono già inclusi; il monitor si apre per impostazione predefinita.

**Attenzione:** questi comandi eseguono codice scaricato da Internet con i privilegi della sessione. Verificare il contenuto del repository e del bootstrap prima di usarli su macchine di clienti.

## Stato e arresto

Il worker si copia in `C:\ProgramData\MSPTools\WindowsUpdate\MSP-WindowsUpdate.ps1`. Da PowerShell amministrativa:

```powershell
$script = "$env:ProgramData\MSPTools\WindowsUpdate\MSP-WindowsUpdate.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action Monitor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action Stop
```

`Stop`, disponibile anche con il pulsante **Arresta**, è **cooperativo**: richiede l'annullamento nativo di ricerca/download e attende la conclusione dell'installazione già in corso. Il worker è l'unico autore dello stato operativo; una richiesta non viene presentata come un arresto già completato.

Il countdown è gestito dallo script: durante l'attesa lo stop impedisce il riavvio. Il controllo finale e la richiesta di stop usano lo stesso lock; dopo che il riavvio è stato confermato a Windows non se ne promette l'annullamento. Uno stop arrivato dopo quel punto impedisce la ripresa degli aggiornamenti al boot successivo. Lo script non usa `shutdown /a`, quindi non annulla riavvii richiesti da altri processi.

I dati restano in:

```text
C:\ProgramData\MSPTools\WindowsUpdate\activity.log
C:\ProgramData\MSPTools\WindowsUpdate\state.json
C:\ProgramData\MSPTools\WindowsUpdate\state.json.bak
```

Gli stati conclusivi sono `Completed`, `CompletedWithErrors`, `Blocked` e `Stopped`. L'esito distingue update installati da errori e aggiornamenti esclusi.

## Politica aggiornamenti

- Rispetta la sorgente configurata dal PC/server e non modifica **WSUS, GPO, MDM** o le policy di Windows Update.
- **Driver e aggiornamenti facoltativi sono inclusi di default**, compresi firmware/BIOS distribuiti come driver applicabili da WUA. `-ExcludeDrivers` e `-ExcludeOptional` consentono di escluderli; i precedenti `-IncludeDrivers`/`-IncludeOptional` restano accettati. Gli upgrade di versione richiedono `-IncludeFeatureUpgrades` o il consenso specifico per Windows 11; beta e pacchetti che richiedono input restano esclusi.
- Non gestisce Microsoft Store, WinGet, applicazioni di terze parti o firmware fuori da WUA.
- Il successo WUA descrive il pacchetto installato; non è una certificazione universale dell'avvenuto flash del BIOS. Il firmware deve essere pubblicato dal produttore per quel dispositivo. Alimentazione e requisiti di applicazione del firmware restano vincoli del dispositivo.
- Limiti predefiniti: **8 riavvii**, **3 tentativi per aggiornamento**, **3 errori generali consecutivi**, **30 passaggi per worker** e **7 giorni** per esecuzione. Retry periodico ogni **15 minuti**; riavvio richiesto con **90 secondi** di preavviso.
- `-RebootDelaySeconds` configura il countdown (predefinito **90 secondi**). Se il riavvio confermato non avviene entro 15 minuti, un successivo controllo registra `Blocked`.
- Ricerca, download e installazione sono asincroni, con heartbeat e progresso. `-OperationTimeoutMinutes` imposta il limite **per operazione** (predefinito **180 minuti**). Alla scadenza si richiede l'annullamento cooperativo WUA. Dopo altri 5 minuti senza conclusione, l'esito diventa `Blocked` e il task worker viene rimosso; il processo resta in attesa dell'operazione nativa, senza uccidere servizi/installazioni, avviare altro lavoro o riavviare automaticamente. Il monitor mostra che l'operazione potrebbe essere ancora attiva.
- Un lock impedisce worker e avvii concorrenti. Se il processo termina lasciando un'operazione WUA di esito sconosciuto, viene impedito un nuovo avvio nello stesso boot; occorre verificare/ripristinare il sistema. Non si forza un riavvio per risolvere il blocco.
- `Completed` significa solo che WUA non segnala ulteriori **aggiornamenti eleggibili nella sorgente configurata**. Non costituisce una verifica di sicurezza o supporto del sistema.

## Rischi e test necessari

Alla fine del countdown il riavvio usa esplicitamente `/f`: chiude forzatamente le applicazioni, può perdere dati non salvati e interrompe servizi. Prima del test, salvare i dati, avere un backup, verificare BitLocker/pre-boot PIN, alimentazione, accesso di rete e, sui server, la finestra di manutenzione.

Controlli rapidi di riconoscimento piattaforma, consenso, filtri e ciclo operativo su dati sintetici e file temporanei, senza avviare aggiornamenti o riavvii (arresto al primo errore):

```powershell
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-UpdateSelection.ps1
if ($LASTEXITCODE -ne 0) { throw 'Selection checks failed' }
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-UpdateLifecycle.ps1
if ($LASTEXITCODE -ne 0) { throw 'Lifecycle checks failed' }
```

Casi di collaudo consigliati, su sistemi rappresentativi:

1. Windows 11: nessun aggiornamento, due scansioni, riepilogo persistente, suono singolo; rimozione task worker a fine lavoro e task monitor alla chiusura del risultato.
2. Aggiornamento cumulativo che richiede un riavvio: ripresa senza login e convergenza.
3. Download fallito/rete assente: retry limitato, log e stato di errore affidabile.
4. `Stop` durante il lavoro e durante il countdown del riavvio.
5. Windows Server 2019 o successivo con Desktop Experience: rifiuto senza `-AllowServerReboot`, quindi test autorizzato. Verificare che Server Core venga rifiutato.
6. Dove disponibili: Windows 10 LTSC/IoT, UWF attivo (blocco previsto), policy WSUS.
7. Windows 10: scelta sì/no, upgrade non offerto, upgrade offerto e riavvio su Windows 11, errore/rollback con permanenza su Windows 10. Nessuna nuova domanda dopo il boot.
8. Completamento senza login, riapertura del monitor allo stesso account, chiusura anticipata della finestra, nuovo login e modalità `-NoMonitor`.
9. Timeout WUA con annullamento concluso e operazione ancora attiva; nessun nuovo worker/riavvio né falso completamento. Driver/firmware su hardware di prova con alimentazione e recupero disponibili.

## Riferimenti

- [Windows Update Agent API](https://learn.microsoft.com/en-us/windows/win32/wua_sdk/portal-client)
- [Ricerca, download e installazione con WUA](https://learn.microsoft.com/en-us/windows/win32/wua_sdk/searching--downloading--and-installing-updates)
- [Scheduled Tasks PowerShell](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/register-scheduledtask)
- [Aggiornamenti di dispositivi protetti da UWF](https://learn.microsoft.com/en-us/windows/configuration/unified-write-filter/uwf-apply-windows-updates)
- [Rilevamento Server Core](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/legacy/ee391629(v=vs.85))
- [Build Windows 11](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)
- [Build Windows Server](https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info)
- [Operazioni WUA asincrone](https://learn.microsoft.com/en-us/windows/win32/wua_sdk/guidelines-for-asynchronous-wua-operations)
- [Firmware distribuito tramite Windows](https://learn.microsoft.com/en-us/windows-hardware/drivers/bringup/windows-uefi-firmware-update-platform)
- [Contesti di sicurezza delle attività pianificate](https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks)
