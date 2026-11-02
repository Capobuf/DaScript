# Aggiornamenti Windows

Script di aggiornamento Windows della raccolta **DaScript**.

## Anteprima dell'interfaccia

Fare doppio clic su **Anteprima.bat**, oppure dalla radice del repository eseguire un solo comando:

```powershell
.\windows\windows-update\Anteprima.bat
```

Si apre la stessa finestra WPF del monitor con dati dimostrativi. Il selettore numerato e i pulsanti **Precedente / Successiva** permettono di esplorare 18 scenari: attesa, ricerca, download, installazione, verifica, retry, dati obsoleti, riavvio, ripresa, stop ed esiti. **Rivedi intro** ripete l'ingresso; cliccando su **UPDATE** o sul titolo dell'esito si apre il pannello unico con dettagli, **ACTIVITY** e **DIAGNOSTICS**. Per le segnalazioni indicare numero/nome della schermata e controllo interessato.

L'anteprima non richiede elevazione, non scarica nulla, non legge o modifica esecuzioni reali, non crea task o file runtime e non avvia WUA, aggiornamenti o riavvii. I campioni e il countdown restano fermi per permettere la revisione. **Stop** mostra la richiesta simulata; selezionare **Interrotto** per vedere la conferma. Il BAT non esegue la suite di test e rispetta la policy PowerShell esistente; in caso di errore lascia visibile il messaggio.

Richiede Windows PowerShell 5.1, WPF/.NET Framework e desktop interattivo. È una UI Windows nativa, non una pagina da aprire nel browser ([WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/), [avvio PowerShell da BAT](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1)). L'avvio diretto equivalente è `powershell.exe -NoProfile -STA -File .\WindowsUpdate.ps1 -Action Preview` dalla cartella dello script.

## Avvio da URL GitHub

I comandi seguenti caricano il bootstrap da `main`. A ogni nuovo avvio il bootstrap scarica il worker corrente dallo stesso branch, quindi le versioni pubblicate su `main` diventano disponibili senza cambiare il comando. Le esecuzioni già avviate continuano a usare la propria copia locale, anche dopo un riavvio.

Le modifiche presenti soltanto nel checkout locale non vengono scaricate dal bootstrap, neppure lanciando `bootstrap.ps1` da disco. Per provarle usare direttamente il worker come indicato in **Avvio locale**. Il vecchio messaggio `Started. Logs: ...activity.log` identifica una versione che scrive ancora il log su disco.

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

Con il comando `irm ... | iex`, dopo che il worker ha restituito successo e il download temporaneo è stato eliminato, il bootstrap termina la sessione PowerShell interattiva con `exit 0`. Il monitor è un processo separato e gli aggiornamenti proseguono tramite il task SYSTEM. Errori di download, avvio o pulizia lasciano la sessione aperta. La chiusura automatica è limitata a `ConsoleHost`, con desktop interattivo e input non reindirizzato; non viene richiesta con `-NoMonitor` o `-KeepConsole`. In Windows Terminal termina la sessione/scheda corrente; l'eventuale permanenza della scheda dipende dalle impostazioni del terminale. L'avvio diretto del worker locale non chiude la console chiamante.

Per mantenere aperta la console:

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Capobuf/DaScript/main/windows/windows-update/bootstrap.ps1'))) -KeepConsole
```

**Attenzione:** questi comandi eseguono codice scaricato da Internet con i privilegi della sessione. Verificare il contenuto del repository e del bootstrap prima di usarli su macchine di clienti.

Script PowerShell per la manutenzione unattended di Windows. Usa le API native Windows Update Agent (WUA) e una attività pianificata come `SYSTEM` per cercare, scaricare e installare aggiornamenti; riavvia quando necessario e riprende automaticamente dopo il boot, fino a due scansioni consecutive senza ulteriori aggiornamenti **eleggibili**.

**Stato:** sviluppo. Compatibilità progettata sulle API Microsoft; i controlli di sintassi e dei flussi isolati non sostituiscono il collaudo di installazione, firmware, upgrade e ripresa su VM/snapshot o hardware di prova.

## Compatibilità prevista

- **Windows 10 / 11**: comprese, come obiettivo progettuale, Pro, Enterprise, Education, LTSC e IoT Enterprise.
- **Windows Server 2019 e successivi con Desktop Experience**: incluse edizioni Standard/Datacenter. **Server Core è escluso** e viene rifiutato prima di iniziare gli aggiornamenti.
- **Requisito:** Windows PowerShell **5.1**, diritti amministrativi, Windows Update Agent funzionante, attività pianificate e accesso alla sorgente aggiornamenti configurata (Windows Update, Microsoft Update se già abilitato, oppure WSUS). Il worker usa un piccolo callback COM compilato con `Add-Type`: policy che vietano la compilazione/esecuzione devono essere gestite dall'amministratore, non vengono aggirate.
- La ripresa confronta **`Win32_OperatingSystem.LastBootUpTime`**, letto con `Get-CimInstance` e normalizzato in UTC. Non richiede che l'evento di avvio sia ancora presente nel registro System. Se CIM non è accessibile o il valore manca/non è valido, l'avvio fallisce o la ripresa viene bloccata. Uno stato precedente basato su `event12` con un'operazione incerta o un riavvio pendente richiede verifica dell'operatore: il cambio di formato non viene interpretato come un riavvio. Non sostituire il worker durante un'esecuzione attiva.
- Sulle edizioni IoT/Enterprise con **Unified Write Filter (UWF) attivo**, lo script **rifiuta l'avvio**: gli aggiornamenti rischiano di andare persi al riavvio. Usare la modalità di manutenzione UWF prevista da Windows.

Il riconoscimento di client/server usa i dati del sistema operativo, non stringhe localizzate o liste di nomi delle edizioni.
La distinzione Windows 10/11 usa versione e build (Windows 11 parte da 22000); il minimo Server è la build 17763. Il tipo di installazione Server viene letto da `InstallationType` nel registro.

## Avvio locale

Aprire **Windows PowerShell 5.1 come amministratore**.

Client Windows 10/11:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsUpdate.ps1 -Action Start
```

Su **Windows 10**, prima dell'avvio compare una sola domanda:

```text
Esegui anche aggiornamento a Windows 11? [s/N]
```

Invio oppure `n` mantiene Windows 10; `s` autorizza anche il passaggio a Windows 11 e i relativi riavvii. La scelta viene salvata e non viene richiesta dal worker, neppure dopo il riavvio. Su Windows 11 e Server la domanda non compare.

Per esecuzioni unattended scegliere esplicitamente `-Windows11Upgrade Allow` oppure `-Windows11Upgrade Skip`; senza una scelta, un avvio Windows 10 non interattivo viene rifiutato. `-NoMonitor` disabilita soltanto il monitor, non la domanda iniziale.

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\WindowsUpdate.ps1 -Action Start -Windows11Upgrade Allow -NoMonitor
```

`Allow` è accettato soltanto quando si avvia da Windows 10. Consente gli upgrade classificati come **Upgrades** che riportano il nome **Windows 11** nel titolo WUA, anche se facoltativi; non abilita indiscriminatamente gli altri upgrade. Il titolo è un filtro conservativo, non una proprietà strutturata della versione di destinazione: offerte non riconoscibili vengono escluse e segnalate. `-IncludeFeatureUpgrades` da solo non autorizza il passaggio Windows 10 → 11.

Lo script usa solo le offerte della sorgente configurata: non modifica requisiti TPM/CPU/Secure Boot, policy, canale LTSC/IoT o licenze e non scarica ISO/Installation Assistant. La disponibilità dell'upgrade non è garantita per ogni dispositivo o edizione. Il completamento viene confermato soltanto rilevando Windows 11 dopo il riavvio. Un'offerta assente (`NotOffered`) o esclusa viene distinta da un errore di installazione; un upgrade offerto, non escluso e non completato resta `CompletedWithErrors`, con dettaglio `NotCompleted`.

Server (riavvio automatico autorizzato esplicitamente):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WindowsUpdate.ps1 -Action Start -AllowServerReboot
```

Nell'avvio locale diretto del worker su Windows Server, senza `-AllowServerReboot`, l'avvio viene **bloccato prima di installare**. Il bootstrap da URL passa questa opzione solo dopo il consenso iniziale o quando è già specificata nel comando. Pianificare una finestra di manutenzione.

Il comando avvia un **monitor WPF/XAML separato**, integrato nello stesso `.ps1`. L'ingresso **Ghost Attack** parte solo all'apertura del monitor e dura 1,18 secondi: il fantasma originale parte minuscolo, diventa leggibile nei primi 450 ms, si avvicina brevemente e scatta quasi a pieno schermo in 60 ms. Continua a crescere del 10% nei successivi 80 ms, senza fermarsi, poi accelera nello zoom finale oltre i bordi, centrato verso il volto. Il logo chiaro e la cache grafica a scala 4 ne migliorano il contrasto e la resa durante lo zoom. Un flash nero (60 ms a piena opacità, con entrata/uscita brevi) copre la comparsa della finestra nelle dimensioni originali. Lo zoom usa una cache grafica WPF del logo. La superficie operativa mantiene gli accenti ambra su fondo blu ardesia e una trama CRT animata durante le fasi operative. Mostra fase, percentuale WUA quando disponibile, aggiornamento corrente, conteggi, countdown e log. Il lavoro prosegue come `SYSTEM`, anche chiudendo la finestra o senza login.

Il monitor usa le librerie WPF di **.NET Framework** e Consolas, senza asset remoti, moduli o installazioni aggiuntive. Il tracciato del logo SVG è incorporato nel `.ps1` in forma compressa e letto come geometria WPF, senza file esterni; `WindowChrome` mantiene i comandi nativi, con ridimensionamento manuale disabilitato; trascinando lo spettro si sposta la finestra con `Window.DragMove`. Richiede un desktop interattivo e un thread **STA** (già impostato dal lancio automatico e dal task al login); per un lancio manuale usare `powershell.exe -STA -File .\WindowsUpdate.ps1 -Action Monitor`. Stato, log e comando di stop sono gestiti in un runspace del monitor; il `DispatcherTimer` aggiorna i controlli senza attendere file o lock sul thread grafico. Nessuna operazione WUA viene eseguita dalla UI.

Il terminale operativo mantiene le etichette inglesi del registro; gli esiti hanno titoli e descrizioni in italiano. Titoli degli aggiornamenti ed errori restituiti da Windows mantengono la lingua della sorgente. La finestra segue il **contorno dello spettro**: il desktop resta visibile all'esterno, mentre il corpo è opaco. **UPDATE** è grande e indipendente dalla percentuale, con lettere vettoriali **8 bit** leggermente scheggiate, avorio e bordate di scuro. Le mani passano davanti alle estremità della composizione. Il contrasto segue le lettere, senza alone sul petto o riquadro attorno al titolo. Sotto restano barra segmentata, percentuale del singolo aggiornamento e icone pixelate con conteggi ingranditi. I numeri e le brevi descrizioni degli esiti hanno un fondo scuro limitato al testo. Non servono font o asset esterni.

Nel cappuccio restano solo minimizzazione e Chiudi. Il quadrato Stop è stato rimosso dal cappuccio: il comando esplicito **STOP AGGIORNAMENTI** è nel pannello dei dettagli, disponibile quando l'arresto cooperativo è consentito. Fase, aggiornamento corrente, percentuale del batch e avvisi operativi sono in Diagnostics. Hover e pressione modificano colore o opacità dei comandi, senza riquadri aggiuntivi. Non sono presenti presa di ridimensionamento o pulsante di massimizzazione. La sagoma operativa non limita l'intro a schermo intero.

La finestra usa **Update** come nome base e lo spettro incorporato come icona WPF nella taskbar e in Alt+Tab. Il titolo segue fase ed esito, per esempio `Update - Ricerca`, `Update - Installazione - batch 42%` o `Update - Completato`. Percentuale e ultimo countdown vengono ripresi dalla stessa telemetria validata del monitor; dati obsoleti non mantengono percentuali nel titolo. L'icona è generata in memoria dalla geometria esistente, senza file o download aggiuntivi.

**UPDATE** e tutti i titoli degli esiti sono cliccabili e centrati nella stessa fascia tra le mani, anche **INTERROTTO** e **PARZIALE**. Aprono un unico pannello **DETTAGLI**, inizialmente chiuso, in stile Windows 95 con i colori del progetto. Non rimangono etichette Activity/Diagnostics sotto lo spettro. Il pannello mostra prima gli errori ancora aperti con titolo e causa, le esclusioni con motivazione e gli aggiornamenti installati, ricavati dallo stato corrente e aggiornati anche mentre il pannello è aperto. Gli errori risolti non sono conteggiati tra quelli aperti.

**Activity** e **Diagnostics** sono sezioni `[+]`/`[-]` dello stesso pannello, chiuse all'inizio: log selezionabile da una parte, telemetria e dati tecnici dall'altra. La lettura prosegue anche a pannello chiuso; riaprendolo vengono conservate le sezioni aperte. Il titolo sullo spettro rimane visibile durante la consultazione. Un secondo clic sul titolo, **X** o `Esc` chiude il pannello; trascinando la sua barra del titolo lo si sposta. Lo spettro non cambia dimensioni e chiuderlo chiude anche il pannello.

Lo spettro fluttua con un movimento lento e leggero. Al passaggio del mouse rallenta progressivamente fino a fermarsi nella posizione raggiunta; all'uscita riparte gradualmente. Anche il mouse sopra il pannello frena il movimento; il pannello rimane fermo. Una trasformazione WPF muove la superficie grafica senza cambiare continuamente le coordinate della finestra. Il timer usa il tempo trascorso e una decelerazione esponenziale, senza azzerare bruscamente la posizione. Si ferma durante l'intro, la minimizzazione e alla chiusura. Animazioni Windows disabilitate, contrasto elevato o rendering tier 0 mantengono la presentazione statica.

Lo sfondo operativo conserva lo scorrimento delle linee CRT, una scansione luminosa tenue e la variazione di opacità del logo. Questi effetti non generano messaggi o progressi fittizi; si fermano anche negli esiti e nella lettura del log finale.

Le righe ricevute dal worker compaiono progressivamente a piccoli gruppi; la coda resta limitata allo snapshot corrente e non inventa eventi. Errori, warning, stop, countdown, riavvii confermati ed esiti conclusivi vengono mostrati senza ritardo di animazione. Il riepilogo finale viene reso integralmente prima della conferma di lettura al worker.

Lo storico delle attività è **solo in memoria**: lo script non crea né aggiorna `activity.log` e non riversa lo storico nei file JSON. Worker e monitor condividono una mappatura non persistente nativa .NET, limitata a **60 righe**, con un massimo di **4096 caratteri per riga** e troncamento esplicito dei messaggi più lunghi. La mappatura è distinta per esecuzione e accessibile a SYSTEM e amministratori; `Global\` consente il collegamento tra il worker di servizio e il desktop. Resta disponibile finché almeno un worker o monitor la mantiene aperta; si perde al riavvio e anche tra due avvii del worker se nel frattempo non resta aperto alcun monitor. Nessun servizio aggiuntivo conserva lo storico. Se la memoria condivisa non è disponibile, il monitor lo segnala, senza creare un log su disco.

La barra segmentata rappresenta soltanto una percentuale comunicata da WUA; `--` indica un valore non disponibile, anche a lavoro concluso. L'ingresso usa uno storyboard WPF finito su `RenderTransform` e `Opacity`. Negli esiti lo sfondo alterna due tinte scure ogni 800 ms; logo, titolo, riepilogo e comandi restano stabili. Il clock del colore si ferma durante ingresso, minimizzazione, lettura del log e chiusura. Il polling serve soltanto a stato, telemetria e lettura progressiva del log, e si arresta quando la sessione è stata rimossa e il risultato è conservato in memoria. Con animazioni Windows disabilitate, contrasto elevato, rendering software (tier 0) o errore di avvio dell'effetto, la scena compare direttamente. Solo l'ingresso occupa temporaneamente tutto il monitor della finestra, compresa la barra delle applicazioni, usando la stessa finestra WPF. Il desktop resta visibile attraverso una vignettatura nera radiale: circa 40% al centro, 60% a metà raggio e 92% ai bordi (alpha `#66`, `#99`, `#EB`), senza fondale colorato opaco: la trasparenza per pixel è abilitata alla creazione della finestra con `AllowsTransparency`. La vignettatura e il fantasma scompaiono sotto il flash finale; non vengono acquisite immagini del desktop. Alla fine vengono ripristinati posizione, dimensioni e stato precedenti; interfaccia operativa e schermate finali restano in finestra. `Esc` salta la transizione e ripristina subito la finestra. Minimizzazione e chiusura rimuovono i clock delle transizioni; il ripristino della posizione dopo la minimizzazione attende che l'operatore riapra la finestra, senza riportarla in primo piano; nessuna impostazione del sistema o della console host viene modificata. Il countdown mostra **l'ultimo valore comunicato dal worker**, senza stimare autonomamente il momento del riavvio. La finestra non si ridimensiona manualmente e il contenuto resta scorrevole quando lo spazio non basta; il log è selezionabile/copiabile e non torna in fondo mentre si consultano righe precedenti. `Tab` sposta il focus, `Alt+S` nel pannello richiede **Stop**, `Alt+C` nella finestra dello spettro chiude il monitor. WPF usa unità indipendenti dai pixel; su monitor con DPI diversi lo scaling dipende anche dall'host Windows PowerShell e non viene forzata una modalità DPI del processo. Non sono richiesti effetti GPU: il rendering resta disponibile anche in software/RDP.

Un secondo task riapre il monitor **al login dello stesso account che ha avviato lo script**, con token interattivo elevato e senza salvare password, finché il lavoro è in corso. A fine lavoro il worker concede al monitor aperto fino a 10 secondi per leggere il risultato, poi rimuove automaticamente i propri file e i due task. La finestra già aperta conserva il riepilogo **in memoria**, fino alla chiusura. Se il lavoro termina senza monitor aperto o senza login, la pulizia avviene comunque: non resta un riepilogo da mostrare al login successivo. Non viene modificato l'accesso automatico di Windows.

La conclusione mostra direttamente una schermata in finestra, senza ripetere lo zoom o passare a schermo intero. Lo sfondo lampeggia alternando la tinta scura dell'esito e una seconda tinta; il titolo pixel e il logo mantengono il loro colore, senza font esterni. Il riepilogo contiene una breve frase e solo i conteggi non nulli di installazioni, errori ed esclusioni. I controlli sono centrati e riprendono la tinta dell'esito. Cliccare sul titolo apre i dettagli senza sostituire l'esito; **Chiudi** chiude solo il monitor. Il risultato rimane leggibile fino alla chiusura, anche in caso di errore e dopo la pulizia automatica.

| Stato del worker | Schermata | Sfondo / accento |
|---|---|---|
| `Completed`, nessuna installazione nella sessione | GIRO A VUOTO | Blu ardesia |
| `Completed`, almeno un aggiornamento installato | COMPLETATO | Viola |
| `CompletedWithExclusions` o `CompletedWithErrors` con installazioni riuscite | PARZIALE | Ambra |
| `Blocked` o `CompletedWithErrors` senza installazioni riuscite | ERRORE | Corallo |
| `WaitingForReboot` | RIAVVIO RICHIESTO | Arancione |
| `Stopped` | INTERROTTO | Neutro |

La schermata di riavvio è **intermedia**: mostra solo il countdown ricevuto dal worker e mantiene lo stop cooperativo finché realmente disponibile. Alla ripresa ritorna al terminale operativo. Una richiesta di stop non è un arresto concluso. Se WUA risulta ancora attiva o di esito incerto, resta visibile il terminale con la diagnostica, anche in stato `Blocked`. Un errore di lettura del monitor riporta al terminale e non produce un esito fittizio. Errori e pulizia incompleta conservano il dettaglio diagnostico e l'accesso al log in memoria. GIRO A VUOTO riguarda gli aggiornamenti eleggibili nella sorgente configurata e non certifica la sicurezza del sistema.

Il suono di sistema **Asterisk** viene richiesto una sola volta per esecuzione per `Completed` e `CompletedWithExclusions`; le esclusioni restano evidenziate nella finestra. Audio disponibile, volume e schema sonoro dipendono dalla sessione. Errori, blocchi e arresti hanno un esito visivo distinto e non producono il suono di successo. `-NoMonitor` disabilita finestra, riapertura al login e suono; è necessario per l'avvio da una sessione di servizio senza desktop.

### Monitoraggio dell'operazione WUA

Il monitor distingue **UPDATE** (percentuale e posizione del singolo aggiornamento, per esempio 3/8) da **WUA BATCH** (percentuale del batch dell'operazione corrente, rappresentata dalla barra). Non esiste una percentuale complessiva della manutenzione. Titolo e posizione provengono dall'indice WUA nella collezione del batch. Durante il download sono disponibili la fase nativa (`INITIALIZING`, `DOWNLOADING`, `VERIFYING`) e i byte del batch; il totale preceduto da `~` è una stima WUA. I byte del singolo aggiornamento sono nella sezione espandibile **DIAGNOSTICS**.

- **WORKER ACTIVE** indica uno stato/heartbeat scritto negli ultimi **30 secondi** (`UpdatedUtc`); **WUA RESPONDING** richiede anche una risposta recente e riuscita di `GetProgress()`. Il piccolo indicatore è statico e riflette la disponibilità di dati recenti. Nelle fasi di attesa e a lavoro concluso resta l'ora dell'ultimo heartbeat, senza dichiarare il worker attivo.
- **PROGRESS CHANGED** indica una variazione osservata negli ultimi 30 secondi di indice, percentuali, fase o byte trasferiti. Dopo **120 secondi** senza variazioni compare `NO PROGRESS CHANGE // WINDOWS UPDATE STILL RESPONDING`, se le risposte continuano. Queste soglie servono solo alla visualizzazione e al log: non terminano operazioni e non modificano i timeout.
- **NO RECENT HEARTBEAT**, **NO RECENT WUA PROGRESS DATA** e **WUA PROGRESS READ FAILED** distinguono dati vecchi ed errori. Percentuali mancanti, fuori intervallo o obsolete diventano `--`. Ricerca, annullamento, blocco e attesa di riavvio mantengono i propri stati operativi; non viene dedotto un blocco da una percentuale ferma.

I tempi indicano durata dell'operazione, tempo dall'ultima variazione osservata e dall'ultima risposta WUA. Prima della prima variazione si mostra l'intervallo invariato dalla prima osservazione utile. Non sono ETA e non misurano lavoro interno non esposto da Windows. I timer continuano ad aggiornarsi anche mentre il lettore asincrono attende lo stato. **DIAGNOSTICS** mostra timestamp UTC, PID, identificativo del boot ed eventuale errore di lettura, usando solo lo snapshot già acquisito; non interroga WUA né i registri eventi. Al login il lettore controlla una volta il boot tramite CIM, fuori dal lock condiviso, per non mostrare dati del boot precedente come correnti.

Il log in memoria registra inizio/fine operazione, cambio aggiornamento/fase e variazioni di almeno 10 punti percentuali rispetto all'ultimo valore registrato (anche il raggiungimento del 100%). Un periodo invariato produce una sola riga dopo 120 secondi; una nuova variazione riabilita la segnalazione. Il campionamento resta quello esistente, circa ogni 3 secondi: può non osservare transizioni più brevi. Le informazioni temporanee vengono azzerate al cambio operazione, al completamento e al recupero dopo un nuovo boot. Un errore di `GetProgress()` mantiene il precedente percorso di errore e il marcatore dell'operazione incerta.

`IInstallationProgress` espone indice e percentuali, **non una fase interna di installazione, byte, velocità o tempo residuo**. `IDownloadProgress` espone anche fase e byte; percentuali e dimensioni del download sono stime. Una risposta API riuscita conferma la comunicazione, non il progresso effettivo o il successo dell'aggiornamento. Queste interfacce sono documentate da Microsoft per versioni client/server precedenti a quelle già supportate dallo script e non aggiungono requisiti di edizione o dipendenze.

## Stato e arresto

Il worker si copia in `C:\ProgramData\DaScript\WindowsUpdate\WindowsUpdate.ps1`. Da PowerShell amministrativa:

```powershell
$script = "$env:ProgramData\DaScript\WindowsUpdate\WindowsUpdate.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action Monitor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action Stop
```

Il file si chiama `WindowsUpdate.ps1`; task, mutex e memoria condivisa usano il prefisso **DaScript-WindowsUpdate**. Prima di passare a questa versione, concludere le esecuzioni precedenti usando il loro worker originale. L'avvio rifiuta task con nomi diversi che lanciano un worker/monitor dalla cartella `WindowsUpdate` e file `.ps1` con nomi diversi nella cartella runtime corrente. Non migra né rimuove automaticamente runtime precedenti e non va usato per riprendere una vecchia esecuzione tramite `-Action Worker`.

`Stop`, disponibile anche con il pulsante **Stop**, è **cooperativo**: richiede l'annullamento nativo di ricerca/download e attende la conclusione dell'installazione già in corso. Il worker è l'unico autore dello stato operativo; una richiesta non viene presentata come un arresto già completato.

Il countdown è gestito dallo script: durante l'attesa lo stop impedisce il riavvio. Il controllo finale e la richiesta di stop usano lo stesso lock; dopo che il riavvio è stato confermato a Windows non se ne promette l'annullamento. Uno stop arrivato dopo quel punto impedisce la ripresa degli aggiornamenti al boot successivo. Lo script non usa `shutdown /a`, quindi non annulla riavvii richiesti da altri processi.

Durante il lavoro lo stato operativo si trova in:

```text
C:\ProgramData\DaScript\WindowsUpdate\state.json
C:\ProgramData\DaScript\WindowsUpdate\state.json.bak
```

Questi file conservano avanzamento, risultati ed errori necessari a ripresa e riepilogo; non contengono la coda delle attività. Restano anche la copia del worker e i marcatori di controllo previsti dal ciclo operativo. La modifica riguarda il log dello script, non i registri nativi di Windows Update.

Gli stati conclusivi sono:

- `Completed`: nessun altro aggiornamento eleggibile, senza errori aperti o esclusioni.
- `CompletedWithExclusions`: nessun errore aperto, ma offerte escluse (per esempio driver esclusi dall'operatore) oppure upgrade richiesto non offerto. Le esclusioni non incrementano il conteggio degli errori.
- `CompletedWithErrors`: errori aperti o upgrade offerto e non completato, senza un'esclusione che lo spieghi.
- `Blocked` e `Stopped`: esecuzione bloccata oppure arrestata dall'operatore.

Le esclusioni descrivono l'ultima scansione riuscita, evitando di mantenere offerte precedenti non più presenti.

## Pulizia automatica

A esecuzione conclusa e senza operazioni o riavvii di esito incerto, vengono rimossi i task `DaScript-WindowsUpdate` e `DaScript-WindowsUpdate-Monitor`, la copia del worker, stato e backup, richieste di stop, marcatori e file temporanei della cartella `DaScript\WindowsUpdate`, compreso un eventuale `activity.log` lasciato da versioni precedenti. Anche la cartella viene rimossa; il contenitore `DaScript` viene eliminato solo se creato dall'esecuzione e rimasto vuoto. La pulizia non richiede di chiudere il monitor e funziona anche con `-NoMonitor`.

Lo script non elimina file estranei, directory reindirizzate, il sorgente dell'operatore, la cronologia aggiornamenti, la cache WUA o i registri eventi/audit di Windows. Il bootstrap elimina già il proprio download temporaneo. I mutex nativi usati per la sincronizzazione non lasciano file di lock.

Un'operazione WUA ancora attiva/incerta o un riavvio già confermato impediscono la pulizia dello stato di sicurezza. Errori di rimozione sono segnalati come **pulizia incompleta**, separatamente dall'esito degli aggiornamenti; non vengono presentati come successo. Dopo aver risolto il problema, `-Action Worker` dal sorgente locale può ritentare la pulizia di uno stato conclusivo e sicuro. Dopo una pulizia riuscita `Status` non trova più l'esecuzione e la copia in ProgramData non è più disponibile.

## Politica aggiornamenti

- Rispetta la sorgente configurata dal PC/server e non modifica **WSUS, GPO, MDM** o le policy di Windows Update.
- **Driver e aggiornamenti facoltativi sono inclusi di default**, compresi firmware/BIOS distribuiti come driver applicabili da WUA. `-ExcludeDrivers` e `-ExcludeOptional` consentono di escluderli; i precedenti `-IncludeDrivers`/`-IncludeOptional` restano accettati. Gli upgrade di versione richiedono `-IncludeFeatureUpgrades` o il consenso specifico per Windows 11; le beta restano escluse.
- `InstallationBehavior.CanRequestUserInput` indica solo una possibile interazione: non esclude l'aggiornamento selezionato da download e installazione. `Update may require interactive input` compare nel log come `INFO`. Restano attivi `ForceQuiet` e il divieto di prompt per i sorgenti, senza nuove finestre o conferme. Solo il risultato individuale WUA `Succeeded` (`ResultCode=2`) registra l'installazione come riuscita; gli altri esiti conservano `ResultCode` e `HRESULT`, senza interrompere la lettura degli esiti degli altri aggiornamenti nel batch.
- Un risultato di installazione `0x8024200A` (`WU_E_UH_CANREQUIREINPUT`) o `0x80240020` (`WU_E_NO_INTERACTIVE_USER`) viene diagnosticato come **Manual intervention required** nel log e negli errori aperti del riepilogo del monitor, senza essere contato come esclusione. `0x80242004` (`WU_E_UH_DOESNOTSUPPORTACTION`) segnala un'azione non supportata, possibile anche quando non è supportata l'installazione silenziosa forzata: richiede verifica dell'operatore, senza dedurre con certezza una richiesta di input. Tentativi, riavvii e gestione degli errori restano invariati.
- Non gestisce Microsoft Store, WinGet, applicazioni di terze parti o firmware fuori da WUA.
- Il successo WUA descrive il pacchetto installato; non è una certificazione universale dell'avvenuto flash del BIOS. Il firmware deve essere pubblicato dal produttore per quel dispositivo. Alimentazione e requisiti di applicazione del firmware restano vincoli del dispositivo.
- Limiti predefiniti: **8 riavvii**, **3 tentativi per aggiornamento**, **3 errori generali consecutivi**, **30 passaggi per worker** e **7 giorni** per esecuzione. Retry periodico ogni **15 minuti**; riavvio richiesto con **90 secondi** di preavviso.
- `-RebootDelaySeconds` configura il countdown (predefinito **90 secondi**). Se il riavvio confermato non avviene entro 15 minuti, un successivo controllo registra `Blocked`.
- Ricerca, download e installazione sono asincroni, con heartbeat e progresso. `-OperationTimeoutMinutes` imposta il limite **per operazione** (predefinito **180 minuti**). Alla scadenza si richiede l'annullamento cooperativo WUA. Dopo altri 5 minuti senza conclusione, l'esito diventa `Blocked` e il task worker viene rimosso; il processo resta in attesa dell'operazione nativa, senza uccidere servizi/installazioni, avviare altro lavoro o riavviare automaticamente. Il monitor mostra che l'operazione potrebbe essere ancora attiva.
- Mutex con accesso limitato a SYSTEM e amministratori impediscono worker, avvii e pulizia concorrenti. Se il processo termina lasciando un'operazione WUA di esito sconosciuto, viene impedito un nuovo avvio nello stesso boot; occorre verificare/ripristinare il sistema. Dopo un nuovo boot rilevato tramite `LastBootUpTime`, la ripresa registra operazione, PID, ora iniziale e identificativi dei due avvii, salva subito l'avvenuto recupero e ricontrolla gli aggiornamenti. Un normale riavvio richiesto dopo la conclusione dell'installazione non produce questo warning. Non si forza un riavvio per risolvere il blocco.
- `Completed` significa solo che WUA non segnala ulteriori **aggiornamenti eleggibili nella sorgente configurata**. Non costituisce una verifica di sicurezza o supporto del sistema.

## Rischi e test necessari

Alla fine del countdown il riavvio usa esplicitamente `/f`: chiude forzatamente le applicazioni, può perdere dati non salvati e interrompe servizi. Prima del test, salvare i dati, avere un backup, verificare BitLocker/pre-boot PIN, alimentazione, accesso di rete e, sui server, la finestra di manutenzione.

Controlli rapidi di riconoscimento piattaforma, consenso, filtri e ciclo operativo su dati sintetici e file temporanei, senza avviare aggiornamenti o riavvii (arresto al primo errore):

```powershell
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-BootIdentity.ps1
if ($LASTEXITCODE -ne 0) { throw 'Boot identity checks failed' }
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-BootstrapConsent.ps1
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap consent checks failed' }
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-BootstrapExit.ps1
if ($LASTEXITCODE -ne 0) { throw 'Bootstrap exit checks failed' }
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-UpdateSelection.ps1
if ($LASTEXITCODE -ne 0) { throw 'Selection checks failed' }
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-UpdateInstallation.ps1
if ($LASTEXITCODE -ne 0) { throw 'Installation checks failed' }
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-MemoryLog.ps1
if ($LASTEXITCODE -ne 0) { throw 'Memory log checks failed' }
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-UpdateLifecycle.ps1
if ($LASTEXITCODE -ne 0) { throw 'Lifecycle checks failed' }
powershell.exe -NoProfile -NonInteractive -File .\tests\Test-UwfDetection.ps1
if ($LASTEXITCODE -ne 0) { throw 'UWF checks failed' }
powershell.exe -NoProfile -NonInteractive -STA -File .\tests\Test-Monitor.ps1
if ($LASTEXITCODE -ne 0) { throw 'WPF checks failed' }
powershell.exe -NoProfile -NonInteractive -STA -File .\tests\Test-Preview.ps1
if ($LASTEXITCODE -ne 0) { throw 'Preview checks failed' }
```

`Test-BootIdentity.ps1` verifica letture CIM reali in sola lettura e casi sintetici con eventi assenti, stesso boot, boot successivo, errore CIM, valori mancanti/non validi e stati precedenti incompatibili. Non avvia il worker né riavvia Windows.

`Test-BootstrapConsent.ps1` isola il consenso senza scaricare né avviare il worker. Usa dati CIM e risposte sintetiche per client, server e controller di dominio, consenso esplicito, risposta negativa e lettura fallita. In una console verifica le risposte; con input reindirizzato verifica il blocco prima della domanda. L'output indica quale percorso è stato verificato.

Il controllo UWF include query CIM in sola lettura: verifica gli errori reali di classe/namespace assenti e distingue `NativeErrorCode` dal valore numerico di `StatusCode`. Errori di accesso o del provider restano bloccanti.

`Test-BootstrapExit.ps1` verifica l'uscita reale di processi PowerShell separati con contesto interattivo e worker sintetici: successo, `KeepConsole`, `NoMonitor`, input reindirizzato, host diverso ed errori di download, worker e pulizia. Non scarica codice né avvia aggiornamenti.

`Test-MemoryLog.ps1` verifica la memoria condivisa con un processo di lettura separato, la coda limitata, Unicode, il troncamento, la conservazione finché esiste un lettore e la perdita dello storico alla chiusura dell'ultimo accesso. Controlla inoltre che non venga creato un file di log. I test usano nomi `Local\` isolati; il collegamento fra sessione SYSTEM e desktop è progettato sulle API Microsoft.

`Test-UpdateInstallation.ps1` usa oggetti WUA sintetici per verificare il percorso selezione/download/`BeginInstall` con `CanRequestUserInput=true`, successo individuale, diagnostica dell'intervento manuale, batch con esiti misti e risoluzione degli errori dopo un retry riuscito. Non installa aggiornamenti reali.

`Test-UpdateLifecycle.ps1` copre anche percentuali separate, valori assenti/non validi, contatori byte oltre 32 bit, cambio aggiornamento, progresso invariato senza watchdog, errore `GetProgress()` e azzeramento dei dati a fine operazione/dopo reboot. `Test-Monitor.ps1` verifica heartbeat e risposta WUA indipendenti, dati obsoleti, diagnostica espandibile durante l'attesa del lettore e riconoscimento di snapshot appartenenti al boot precedente.

`Test-Preview.ps1` verifica i 18 scenari dell'anteprima, navigazione avanti/indietro, apertura e ritorno dal log, stop simulato e chiusura con eventi WPF reali. Controlla inoltre icona, titoli con dati recenti/obsoleti, apertura/chiusura di Activity e clock delle animazioni di sfondo, con arresto su esito, minimizzazione, fallback statico e chiusura. Verifica inoltre in rendering WPF la trasparenza esterna allo spettro, il corpo opaco, l’allineamento del contorno e la visibilità dei comandi alle dimensioni iniziali e a 640×480. Controlla il pannello unico aperto dal titolo, le sezioni Activity/Diagnostics, i motivi di errori ed esclusioni, lo Stop dal pannello e la chiusura insieme al monitor. Verifica che tutti gli esiti condividano la posizione di UPDATE tra le mani e che aprire i dettagli non ridimensioni lo spettro. Verifica inoltre decelerazione e ripartenza graduali e arresto del timer di fluttuazione in minimizzazione, fallback statico e chiusura. Verifica gli spazi cliccabili dei titoli e attiva i toggle delle sezioni tramite il loro evento nativo, controllando che la finestra resti visibile e non minimizzata. Carica solo le funzioni di presentazione, senza rendere disponibile il worker. Il test del ciclo operativo copre anche il rifiuto di task e worker con identità precedenti, senza modificarli.

`Test-Monitor.ps1` verifica XAML, controlli WPF, i sei esiti su stati sintetici, riavvio/ripresa, stop pendente/confermato, diagnostica, accesso al log, fallback statico, clock nativo di ingresso e alternanza dei colori finali, trasparenza nativa e alpha della vignettatura (centro e bordi), crescita oltre lo schermo, flash che copre la comparsa dell'app e assenza di zoom sugli esiti (anche se arriva un esito durante l'ingresso), ripristino del corpo opaco e dello spazio esterno trasparente, e lettura asincrona su file temporanei, senza elevazione, aggiornamenti, task reali, riavvii o audio. Aggiungere `-Preview` per aprire la UI con dati sintetici; anche il pulsante Stop agisce soltanto sui file temporanei del test. Sono stati verificati su Windows PowerShell 5.1 il rendering della finestra, il layout forzato dal test a 640×480, lo schermo intero sul monitor corrente e il ripristino della finestra al completamento reale degli storyboard, con Esc e dopo minimizzazione (anche da finestra inizialmente massimizzata), il rendering WPF degli esiti a 96/192 DPI e gli eventi di stop/chiusura con polling e riepilogo finale. Il rendering a DPI diversi non equivale a un collaudo del cambio monitor o di una sessione RDP.

Per vedere un esito senza aggiornamenti o riavvii reali:

```powershell
powershell.exe -NoProfile -STA -File .\tests\Test-Monitor.ps1 -Preview -PreviewOutcome Completed
```

`PreviewOutcome` accetta `Running`, `NoUpdates`, `Completed`, `Partial`, `Error`, `Reboot` e `Stopped`. La preview `Reboot` non programma alcun riavvio.

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

- [Win32_OperatingSystem: ProductType e LastBootUpTime](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-operatingsystem)
- [PowerShell: modalità NonInteractive](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1#-noninteractive)
- [PowerShell: exit e finally](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_language_keywords?view=powershell-5.1#exit)
- [Windows Terminal: comportamento alla chiusura del processo](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/profile-advanced#profile-termination-behavior)
- [Windows Update Agent API](https://learn.microsoft.com/en-us/windows/win32/wua_sdk/portal-client)
- [Ricerca, download e installazione con WUA](https://learn.microsoft.com/en-us/windows/win32/wua_sdk/searching--downloading--and-installing-updates)
- [Significato di CanRequestUserInput](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iinstallationbehavior-get_canrequestuserinput)
- [Installazione silenziosa con ForceQuiet](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdateinstaller2-get_forcequiet)
- [Codici di errore Windows Update](https://learn.microsoft.com/en-us/windows/deployment/update/windows-update-error-reference)
- [Esiti individuali OperationResultCode](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/ne-wuapi-operationresultcode)
- [Scheduled Tasks PowerShell](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/register-scheduledtask)
- [Aggiornamenti di dispositivi protetti da UWF](https://learn.microsoft.com/en-us/windows/configuration/unified-write-filter/uwf-apply-windows-updates)
- [Rilevamento Server Core](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/legacy/ee391629(v=vs.85))
- [Build Windows 11](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)
- [Build Windows Server](https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info)
- [Operazioni WUA asincrone](https://learn.microsoft.com/en-us/windows/win32/wua_sdk/guidelines-for-asynchronous-wua-operations)
- [IInstallationProgress: indice e percentuali](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nn-wuapi-iinstallationprogress)
- [IDownloadProgress: percentuali, fase e byte](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nn-wuapi-idownloadprogress)
- [Contatori byte WUA: tipo COM DECIMAL](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-idownloadprogress-get_totalbytesdownloaded)
- [Fasi native DownloadPhase](https://learn.microsoft.com/en-us/windows/win32/api/wuapi/ne-wuapi-downloadphase)
- [Firmware distribuito tramite Windows](https://learn.microsoft.com/en-us/windows-hardware/drivers/bringup/windows-uefi-firmware-update-platform)
- [Contesti di sicurezza delle attività pianificate](https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks)
- [Lettura dell'ultimo avvio tramite WMI](https://learn.microsoft.com/en-us/windows/win32/wmisdk/wmi-tasks--desktop-management)
- [Mutex nativi .NET](https://learn.microsoft.com/en-us/dotnet/api/system.threading.mutex?view=netframework-4.8.1)
- [Memoria condivisa non persistente .NET](https://learn.microsoft.com/en-us/dotnet/standard/io/memory-mapped-files)
- [CreateOrOpen e permessi .NET Framework](https://learn.microsoft.com/en-us/dotnet/api/system.io.memorymappedfiles.memorymappedfile.createoropen?view=netframework-4.8.1)
- [Oggetti kernel tra sessioni Windows](https://learn.microsoft.com/en-us/windows/win32/termserv/kernel-object-namespaces)
- [Unregister-ScheduledTask](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/unregister-scheduledtask)
- [WPF DispatcherTimer](https://learn.microsoft.com/en-us/dotnet/api/system.windows.threading.dispatchertimer?view=netframework-4.8)
- [Threading WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/threading-model)
- [XamlReader.Load](https://learn.microsoft.com/en-us/dotnet/api/system.windows.markup.xamlreader.load)
- [Geometria vettoriale WPF](https://learn.microsoft.com/en-us/dotnet/api/system.windows.media.geometry.parse?view=netframework-4.8)
- [Scaling DPI in WPF](https://learn.microsoft.com/en-us/windows/win32/hidpi/declaring-managed-apps-dpi-aware)
- [Rendering WPF in sessioni remote](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/whats-new/net80#hardware-acceleration)
- Riferimenti visivi: [Watch Dogs 2 / Graphic Direction](https://www.behance.net/gallery/45126777/Watch-Dogs-2-Graphic-Direction), [Nicolas Fortin / Street Art](https://nickfortin.com/watchdogs-2-street-art). Il monitor non incorpora asset, loghi o personaggi del gioco.

- [Storyboard WPF e controllo dei clock](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/graphics-multimedia/storyboards-overview)
- [Key frame e interpolazione spline](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/graphics-multimedia/key-frame-animations-overview)
- [RenderTransform e layout](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/graphics-multimedia/transforms-overview)
- [Rendering tier WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/graphics-rendering-tiers)

- [WindowChrome e massimizzazione senza bordo](https://learn.microsoft.com/en-us/dotnet/api/system.windows.shell.windowchrome)
- [Evento Completed delle animazioni WPF](https://learn.microsoft.com/en-us/dotnet/api/system.windows.media.animation.timeline.completed)

- [Trasparenza per pixel delle finestre WPF](https://learn.microsoft.com/en-us/dotnet/api/system.windows.window.allowstransparency)

- [Gradiente radiale WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/graphics-multimedia/how-to-paint-an-area-with-a-radial-gradient)
- [Accelerazione continua WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/graphics-multimedia/easing-functions)
- [Cache grafica nativa WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/graphics-multimedia/how-to-improve-rendering-performance-by-caching-an-element)

- [Icona WPF della finestra, taskbar e Alt+Tab](https://learn.microsoft.com/en-us/dotnet/api/system.windows.window.icon)
- [Finestre WPF non rettangolari con AllowsTransparency](https://learn.microsoft.com/en-us/dotnet/api/system.windows.window.allowstransparency)

- [Dimensionamento WPF al contenuto](https://learn.microsoft.com/en-us/dotnet/api/system.windows.window.sizetocontent)
- [Trascinamento nativo WPF](https://learn.microsoft.com/en-us/dotnet/api/system.windows.window.dragmove)

- [Finestre WPF associate al monitor: Owner](https://learn.microsoft.com/en-us/dotnet/api/system.windows.window.owner)
