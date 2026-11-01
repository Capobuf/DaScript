# MSP Windows Update

## Avvio da URL GitHub

I comandi seguenti caricano il bootstrap da `main`. A ogni nuovo avvio il bootstrap scarica il worker corrente dallo stesso branch, quindi le versioni pubblicate su `main` diventano disponibili senza cambiare il comando. Le esecuzioni già avviate continuano a usare la propria copia locale, anche dopo un riavvio.

Client e Server (Windows PowerShell 5.1 come amministratore):

```powershell
irm 'https://raw.githubusercontent.com/Capobuf/DaScript/main/windows/windows-update/bootstrap.ps1' | iex
```

Su **Windows Server**, il bootstrap chiede prima di scaricare e avviare il worker:

```text
Autorizzi i riavvii automatici del server? [s/N]
```

Solo `s` (anche maiuscola) autorizza l'avvio e passa `-AllowServerReboot` al worker. Invio o qualsiasi altra risposta annullano l'avvio. I riavvii interrompono i servizi e chiudono forzatamente le applicazioni: salvare il lavoro e pianificare una finestra di manutenzione. Il riconoscimento usa `Win32_OperatingSystem.ProductType`, includendo i controller di dominio; se non riesce, l'avvio si interrompe.

Server senza domanda iniziale (consenso esplicito ai riavvii):

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Capobuf/DaScript/main/windows/windows-update/bootstrap.ps1'))) -AllowServerReboot
```

Per avvii unattended su Server è necessario `-AllowServerReboot`: senza consenso, una sessione non interattiva o con input reindirizzato viene bloccata. Il bootstrap accetta anche `-Windows11Upgrade Allow|Skip` per scegliere senza la domanda sull'upgrade e `-NoMonitor` per esecuzioni senza interfaccia. `-NoMonitor` non disabilita la domanda sui riavvii. Driver e facoltativi sono già inclusi; il monitor si apre per impostazione predefinita.

**Attenzione:** questi comandi eseguono codice scaricato da Internet con i privilegi della sessione. Verificare il contenuto del repository e del bootstrap prima di usarli su macchine di clienti.

Script PowerShell per la manutenzione unattended di Windows. Usa le API native Windows Update Agent (WUA) e una attività pianificata come `SYSTEM` per cercare, scaricare e installare aggiornamenti; riavvia quando necessario e riprende automaticamente dopo il boot, fino a due scansioni consecutive senza ulteriori aggiornamenti **eleggibili**.

**Stato:** sviluppo. Compatibilità progettata sulle API Microsoft; i controlli di sintassi e dei flussi isolati non sostituiscono il collaudo di installazione, firmware, upgrade e ripresa su VM/snapshot o hardware di prova.

## Compatibilità prevista

- **Windows 10 / 11**: comprese, come obiettivo progettuale, Pro, Enterprise, Education, LTSC e IoT Enterprise.
- **Windows Server 2019 e successivi con Desktop Experience**: incluse edizioni Standard/Datacenter. **Server Core è escluso** e viene rifiutato prima di iniziare gli aggiornamenti.
- **Requisito:** Windows PowerShell **5.1**, diritti amministrativi, Windows Update Agent funzionante, attività pianificate e accesso alla sorgente aggiornamenti configurata (Windows Update, Microsoft Update se già abilitato, oppure WSUS). Il worker usa un piccolo callback COM compilato con `Add-Type`: policy che vietano la compilazione/esecuzione devono essere gestite dall'amministratore, non vengono aggirate.
- La ripresa verifica l'ultimo evento **12 di Microsoft-Windows-Kernel-General** nel registro **System**, letto con `Get-WinEvent`. Se l'evento manca o non è accessibile, lo script non presume un riavvio: l'avvio fallisce o la ripresa viene bloccata. Non cancellare il registro durante un'esecuzione. Uno stato di una vecchia versione con un'operazione incerta e senza questo identificativo richiede verifica dell'operatore; non sostituire il worker durante un'esecuzione attiva.
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

Lo script usa solo le offerte della sorgente configurata: non modifica requisiti TPM/CPU/Secure Boot, policy, canale LTSC/IoT o licenze e non scarica ISO/Installation Assistant. La disponibilità dell'upgrade non è garantita per ogni dispositivo o edizione. Il completamento viene confermato soltanto rilevando Windows 11 dopo il riavvio. Un'offerta assente (`NotOffered`) o esclusa viene distinta da un errore di installazione; un upgrade offerto, non escluso e non completato resta `CompletedWithErrors`, con dettaglio `NotCompleted`.

Server (riavvio automatico autorizzato esplicitamente):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MSP-WindowsUpdate.ps1 -Action Start -AllowServerReboot
```

Nell'avvio locale diretto del worker su Windows Server, senza `-AllowServerReboot`, l'avvio viene **bloccato prima di installare**. Il bootstrap da URL passa questa opzione solo dopo il consenso iniziale o quando è già specificata nel comando. Pianificare una finestra di manutenzione.

Il comando avvia un **monitor WPF/XAML separato**, integrato nello stesso `.ps1`, con un'unica superficie da terminale ambra: logo vettoriale fornito come filigrana centrale sullo sfondo del terminale, senza intestazione dedicata, etichette essenziali, righe compatte di stato e conteggi, comandi testuali sulla riga inferiore e trama CRT. Il logo resta intero e fermo: un passaggio di luce lento e variazioni graduali di intensità ne animano la superficie. Rumore di caratteri e banda di scansione animano lo sfondo dell'intera finestra; il cursore resta intermittente. Sono effetti decorativi: non alterano log, stato o percentuali. Mostra fase, percentuale della singola operazione WUA quando disponibile, aggiornamento corrente, conteggi, countdown e log. Il lavoro prosegue come `SYSTEM`, anche chiudendo la finestra o senza login.

Il monitor usa le librerie WPF di **.NET Framework** e Consolas, senza asset remoti, moduli o installazioni aggiuntive. Il tracciato del logo SVG è incorporato nel `.ps1` in forma compressa e letto come geometria WPF, senza file esterni; `WindowChrome` mantiene spostamento e ridimensionamento della cornice personalizzata. Richiede un desktop interattivo e un thread **STA** (già impostato dal lancio automatico e dal task al login); per un lancio manuale usare `powershell.exe -STA -File .\MSP-WindowsUpdate.ps1 -Action Monitor`. Stato, log e comando di stop sono gestiti in un runspace del monitor; il `DispatcherTimer` aggiorna i controlli senza attendere file o lock sul thread grafico. Nessuna operazione WUA viene eseguita dalla UI.

Le righe ricevute dal worker compaiono progressivamente a piccoli gruppi; la coda resta limitata allo snapshot corrente e non inventa eventi. Errori, warning, stop, countdown, riavvii confermati ed esiti conclusivi vengono mostrati senza ritardo di animazione. Il riepilogo finale viene reso integralmente prima della conferma di lettura al worker.

La barra segmentata rappresenta soltanto una percentuale comunicata da WUA; `--` indica un valore non disponibile, anche a lavoro concluso. Le animazioni decorative restano attive in tutte le fasi, nel riepilogo finale e dopo la pulizia dei file runtime; si sospendono soltanto quando la finestra è minimizzata. Non dipendono dall'impostazione delle animazioni di Windows e non modificano tale impostazione. Il movimento dello sfondo non indica che il worker sia ancora operativo: fa fede lo stato mostrato. Il countdown mostra **l'ultimo valore comunicato dal worker**, senza stimare autonomamente il momento del riavvio. La finestra è ridimensionabile, con contenuto scorrevole e comandi sempre visibili; il log è selezionabile/copiabile e non torna in fondo mentre si consultano righe precedenti. `Tab` sposta il focus, `Alt+A` richiede **Arresta**, `Alt+C` chiude solo la finestra. WPF usa unità indipendenti dai pixel; su monitor con DPI diversi lo scaling dipende anche dall'host Windows PowerShell e non viene forzata una modalità DPI del processo. Non sono richiesti effetti GPU: il rendering resta disponibile anche in software/RDP.

Un secondo task riapre il monitor **al login dello stesso account che ha avviato lo script**, con token interattivo elevato e senza salvare password, finché il lavoro è in corso. A fine lavoro il worker concede al monitor aperto fino a 10 secondi per leggere il risultato, poi rimuove automaticamente i propri file e i due task. La finestra già aperta conserva il riepilogo **in memoria**, fino alla chiusura. Se il lavoro termina senza monitor aperto o senza login, la pulizia avviene comunque: non resta un riepilogo da mostrare al login successivo. Non viene modificato l'accesso automatico di Windows.

Il suono di sistema **Asterisk** viene richiesto una sola volta per esecuzione per `Completed` e `CompletedWithExclusions`; le esclusioni restano evidenziate nella finestra. Audio disponibile, volume e schema sonoro dipendono dalla sessione. Errori, blocchi e arresti hanno un esito visivo distinto e non producono il suono di successo. `-NoMonitor` disabilita finestra, riapertura al login e suono; è necessario per l'avvio da una sessione di servizio senza desktop.

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

Durante il lavoro i dati si trovano in:

```text
C:\ProgramData\MSPTools\WindowsUpdate\activity.log
C:\ProgramData\MSPTools\WindowsUpdate\state.json
C:\ProgramData\MSPTools\WindowsUpdate\state.json.bak
```

Gli stati conclusivi sono:

- `Completed`: nessun altro aggiornamento eleggibile, senza errori aperti o esclusioni.
- `CompletedWithExclusions`: nessun errore aperto, ma offerte escluse (per esempio driver potenzialmente interattivi) oppure upgrade richiesto non offerto. Le esclusioni non incrementano il conteggio degli errori.
- `CompletedWithErrors`: errori aperti o upgrade offerto e non completato, senza un'esclusione che lo spieghi.
- `Blocked` e `Stopped`: esecuzione bloccata oppure arrestata dall'operatore.

Le esclusioni descrivono l'ultima scansione riuscita, evitando di mantenere offerte precedenti non più presenti.

## Pulizia automatica

A esecuzione conclusa e senza operazioni o riavvii di esito incerto, vengono rimossi i task `MSP-WindowsUpdate` e `MSP-WindowsUpdate-Monitor`, la copia del worker, stato e backup, log, richieste di stop, marcatori e file temporanei della cartella `MSPTools\WindowsUpdate`. Anche la cartella viene rimossa; il contenitore `MSPTools` viene eliminato solo se creato dall'esecuzione e rimasto vuoto. La pulizia non richiede di chiudere il monitor e funziona anche con `-NoMonitor`.

Lo script non elimina file estranei, directory reindirizzate, il sorgente dell'operatore, la cronologia aggiornamenti, la cache WUA o i registri eventi/audit di Windows. Il bootstrap elimina già il proprio download temporaneo. I mutex nativi usati per la sincronizzazione non lasciano file di lock.

Un'operazione WUA ancora attiva/incerta o un riavvio già confermato impediscono la pulizia dello stato di sicurezza. Errori di rimozione sono segnalati come **pulizia incompleta**, separatamente dall'esito degli aggiornamenti; non vengono presentati come successo. Dopo aver risolto il problema, `-Action Worker` dal sorgente locale può ritentare la pulizia di uno stato conclusivo e sicuro. Dopo una pulizia riuscita `Status` non trova più l'esecuzione e la copia in ProgramData non è più disponibile.

## Politica aggiornamenti

- Rispetta la sorgente configurata dal PC/server e non modifica **WSUS, GPO, MDM** o le policy di Windows Update.
- **Driver e aggiornamenti facoltativi sono inclusi di default**, compresi firmware/BIOS distribuiti come driver applicabili da WUA. `-ExcludeDrivers` e `-ExcludeOptional` consentono di escluderli; i precedenti `-IncludeDrivers`/`-IncludeOptional` restano accettati. Gli upgrade di versione richiedono `-IncludeFeatureUpgrades` o il consenso specifico per Windows 11; beta e pacchetti che richiedono input restano esclusi.
- Non gestisce Microsoft Store, WinGet, applicazioni di terze parti o firmware fuori da WUA.
- Il successo WUA descrive il pacchetto installato; non è una certificazione universale dell'avvenuto flash del BIOS. Il firmware deve essere pubblicato dal produttore per quel dispositivo. Alimentazione e requisiti di applicazione del firmware restano vincoli del dispositivo.
- Limiti predefiniti: **8 riavvii**, **3 tentativi per aggiornamento**, **3 errori generali consecutivi**, **30 passaggi per worker** e **7 giorni** per esecuzione. Retry periodico ogni **15 minuti**; riavvio richiesto con **90 secondi** di preavviso.
- `-RebootDelaySeconds` configura il countdown (predefinito **90 secondi**). Se il riavvio confermato non avviene entro 15 minuti, un successivo controllo registra `Blocked`.
- Ricerca, download e installazione sono asincroni, con heartbeat e progresso. `-OperationTimeoutMinutes` imposta il limite **per operazione** (predefinito **180 minuti**). Alla scadenza si richiede l'annullamento cooperativo WUA. Dopo altri 5 minuti senza conclusione, l'esito diventa `Blocked` e il task worker viene rimosso; il processo resta in attesa dell'operazione nativa, senza uccidere servizi/installazioni, avviare altro lavoro o riavviare automaticamente. Il monitor mostra che l'operazione potrebbe essere ancora attiva.
- Mutex con accesso limitato a SYSTEM e amministratori impediscono worker, avvii e pulizia concorrenti. Se il processo termina lasciando un'operazione WUA di esito sconosciuto, viene impedito un nuovo avvio nello stesso boot; occorre verificare/ripristinare il sistema. Dopo un nuovo boot confermato dall'evento Windows, la ripresa registra operazione, PID, ora iniziale e identificativi dei due avvii, salva subito l'avvenuto recupero e ricontrolla gli aggiornamenti. Un normale riavvio richiesto dopo la conclusione dell'installazione non produce questo warning. Non si forza un riavvio per risolvere il blocco.
- `Completed` significa solo che WUA non segnala ulteriori **aggiornamenti eleggibili nella sorgente configurata**. Non costituisce una verifica di sicurezza o supporto del sistema.

## Rischi e test necessari

Alla fine del countdown il riavvio usa esplicitamente `/f`: chiude forzatamente le applicazioni, può perdere dati non salvati e interrompe servizi. Prima del test, salvare i dati, avere un backup, verificare BitLocker/pre-boot PIN, alimentazione, accesso di rete e, sui server, la finestra di manutenzione.

Controlli rapidi di riconoscimento piattaforma, consenso, filtri e ciclo operativo su dati sintetici e file temporanei, senza avviare aggiornamenti o riavvii (arresto al primo errore):

```powershell
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-BootstrapConsent.ps1
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap consent checks failed' }
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-UpdateSelection.ps1
if ($LASTEXITCODE -ne 0) { throw 'Selection checks failed' }
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-UpdateLifecycle.ps1
if ($LASTEXITCODE -ne 0) { throw 'Lifecycle checks failed' }
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-UwfDetection.ps1
if ($LASTEXITCODE -ne 0) { throw 'UWF checks failed' }
powershell.exe -NoProfile -NonInteractive -STA -File .\tests\Test-Monitor.ps1
if ($LASTEXITCODE -ne 0) { throw 'WPF checks failed' }
```

`Test-BootstrapConsent.ps1` isola il consenso senza scaricare né avviare il worker. Usa dati CIM e risposte sintetiche per client, server e controller di dominio, consenso esplicito, risposta negativa e lettura fallita. In una console verifica le risposte; con input reindirizzato verifica il blocco prima della domanda. L'output indica quale percorso è stato verificato.

Il controllo UWF include query CIM in sola lettura: verifica gli errori reali di classe/namespace assenti e distingue `NativeErrorCode` dal valore numerico di `StatusCode`. Errori di accesso o del provider restano bloccanti.

`Test-Monitor.ps1` verifica XAML, controlli WPF, stati sintetici e lettura asincrona su file temporanei, senza elevazione, aggiornamenti, task reali, riavvii o audio. Aggiungere `-Preview` per aprire la UI con dati sintetici; anche il pulsante Arresta agisce soltanto sui file temporanei del test. Sono stati verificati su Windows PowerShell 5.1 il rendering della finestra, il ridimensionamento a 640×480, il rendering WPF a 96/192 DPI e gli eventi di stop/chiusura con polling e riepilogo finale. Il rendering a DPI diversi non equivale a un collaudo del cambio monitor o di una sessione RDP.

Casi di collaudo consigliati, su sistemi rappresentativi:

1. Windows 11: nessun aggiornamento, due scansioni, riepilogo in memoria e suono singolo; rimozione automatica di entrambi i task e di tutti i file runtime, anche lasciando la finestra aperta.
2. Aggiornamento cumulativo che richiede un riavvio: ripresa senza login e convergenza.
3. Download fallito/rete assente: retry limitato, log e stato di errore affidabile.
4. `Stop` durante il lavoro e durante il countdown del riavvio.
5. Windows Server 2019 o successivo con Desktop Experience: rifiuto senza `-AllowServerReboot`, quindi test autorizzato. Verificare che Server Core venga rifiutato.
6. Dove disponibili: Windows 10 LTSC/IoT, UWF attivo (blocco previsto), policy WSUS.
7. Windows 10: scelta sì/no, upgrade non offerto, upgrade offerto e riavvio su Windows 11, errore/rollback con permanenza su Windows 10. Nessuna nuova domanda dopo il boot.
8. Completamento senza login e in modalità `-NoMonitor`: pulizia senza attendere l'utente, nessuna riapertura a lavoro concluso. Durante il lavoro: chiusura anticipata e riapertura al login dello stesso account. Errori di pulizia e file estranei: segnalazione e conservazione sicura.
9. Timeout WUA con annullamento concluso e operazione ancora attiva; nessun nuovo worker/riavvio né falso completamento. Driver/firmware su hardware di prova con alimentazione e recupero disponibili.

## Riferimenti

- [Win32_OperatingSystem e ProductType](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem)
- [PowerShell: modalità NonInteractive](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1#-noninteractive)
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
- [Diagnosi dei riavvii tramite eventi Windows](https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-unexpected-reboots-system-event-logs)
- [Get-WinEvent in Windows PowerShell 5.1](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.diagnostics/get-winevent?view=powershell-5.1)
- [Mutex nativi .NET](https://learn.microsoft.com/en-us/dotnet/api/system.threading.mutex?view=netframework-4.8.1)
- [Unregister-ScheduledTask](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/unregister-scheduledtask)
- [WPF DispatcherTimer](https://learn.microsoft.com/en-us/dotnet/api/system.windows.threading.dispatchertimer?view=netframework-4.8)
- [Threading WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/threading-model)
- [XamlReader.Load](https://learn.microsoft.com/en-us/dotnet/api/system.windows.markup.xamlreader.load)
- [Geometria vettoriale WPF](https://learn.microsoft.com/en-us/dotnet/api/system.windows.media.geometry.parse?view=netframework-4.8)
- [Scaling DPI in WPF](https://learn.microsoft.com/en-us/windows/win32/hidpi/declaring-managed-apps-dpi-aware)
- [Rendering WPF in sessioni remote](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/whats-new/net80#hardware-acceleration)
- Riferimenti visivi: [Watch Dogs 2 / Graphic Direction](https://www.behance.net/gallery/45126777/Watch-Dogs-2-Graphic-Direction), [Nicolas Fortin / Street Art](https://nickfortin.com/watchdogs-2-street-art). Il monitor non incorpora asset, loghi o personaggi del gioco.
