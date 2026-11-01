# AGENTS.md — DaScript

## Scopo
DaScript è una raccolta di script operativi per MSP, sysadmin e tecnici IT. Gli script sono dedicati a **Windows** e servono a semplificare, velocizzare e automatizzare operazioni di preparazione, manutenzione, assistenza e amministrazione di PC e server. Devono essere utilizzabili sul campo, non dimostrazioni teoriche.

## Regole obbligatorie
- **Non inventare** fatti, API, risultati di test, comportamenti di Windows, compatibilità o requisiti non verificati.
- **Non assumere** configurazioni, privilegi, disponibilità di moduli, connettività, interfaccia grafica, lingua del sistema o presenza di software.
- **Non dare nulla per scontato**: verifica i prerequisiti nel codice quando possibile; altrimenti indica esplicitamente vincoli e incertezze.
- Leggi integralmente i file pertinenti prima di modificarli. Se uno strumento tronca l'output, rileggi in parti; non interpretare i tagli di visualizzazione come contenuto del file.
- Preferisci la soluzione **più semplice che soddisfa concretamente i requisiti**. Evita overengineering, astrazioni preventive, framework, layer, dipendenze, configurazioni e servizi superflui.
- Mantieni implementazione, log, documentazione e test **proporzionati ai rischi e alla complessità**. Non introdurre CI, infrastruttura, Docker, mock estesi o nuove dipendenze senza motivazione concreta.
- Se un requisito è ambiguo, non inventare una decisione: esplicita il dubbio e procedi solo con una scelta conservativa e reversibile quando appropriato.
- Non dichiarare «funziona», «supportato» o «testato» senza prove. Distingui tra progettato per, verificato staticamente e collaudato realmente.

## Compatibilità Windows
- Considera fin dall'inizio **Windows 10, Windows 11 e Windows Server**. Non limitare gli script a una specifica edizione se non è un vincolo tecnico dimostrato.
- Considera edizioni e canali diversi, per esempio Pro, Enterprise, Education, **LTSC, IoT Enterprise**, e le edizioni **Standard/Datacenter** di Windows Server. Considera **Server Core** quando l'operazione non richiede una GUI.
- Individua a runtime le capacità realmente disponibili (versione di Windows/PowerShell, componenti, servizi, privilegi, policy); non dedurre tutte le funzionalità dal nome commerciale dell'edizione.
- Prediligi API e strumenti Windows nativi disponibili trasversalmente. Se una funzionalità non esiste su un sistema, gestisci il caso in modo esplicito e sicuro: fallback semplice, esclusione motivata oppure errore leggibile. Mai successo fittizio.
- Rispetta GPO, WSUS, MDM, i controlli di sicurezza e le impostazioni esistenti; non aggirarli per ottenere artificialmente un risultato.
- Distingui **compatibilità prevista** da **compatibilità verificata**. Riporta sempre le piattaforme effettivamente testate e quelle ancora da collaudare.
- Il termine «nessun aggiornamento disponibile» non equivale a «sistema aggiornato e sicuro»: possono esserci politiche, filtri o sistemi fuori supporto.

## Comportamento operativo
- Gli script devono essere facili da lanciare, preferibilmente da **Windows PowerShell 5.1**, senza installare moduli di terze parti se non indispensabili.
- Per operazioni unattended, gestisci chiaramente elevazione, errori, esiti parziali, riavvio, ripresa, log, timeout e arresto operatore quando pertinenti. Non introdurre prompt che blocchino l'esecuzione.
- Sii conservativo su azioni irreversibili o impattanti (riavvii dei server, cambi di policy, perdita di dati, cancellazioni). Richiedi autorizzazione esplicita per interventi ad alto impatto e non nascondere gli effetti.
- Non incorporare credenziali, segreti o indirizzi privati. Evita esecuzione non verificata di codice scaricato da Internet. I bootstrap pubblici devono riferirsi a revisioni verificate.
- Mantieni il codice leggibile e diretto; commenta **in inglese** soltanto le parti non ovvie. Evita commenti e messaggi riempitivi.

## Verifiche e consegna
- Verifica la sintassi e i percorsi essenziali, poi testa i flussi critici su Windows appropriati quando l'ambiente è disponibile. Per script che riavviano o modificano lo stato, usa inizialmente una VM/snapshot e includi almeno successo, errore, ripresa e stop.
- Non simulare test come se fossero esecuzioni reali. Se manca un ambiente Windows, scrivi chiaramente «non testato su Windows».
- Ogni script vive in una propria cartella sotto `windows/` con un README breve: scopo, prerequisiti, comando d'uso, opzioni, rischi, compatibilità e stato dei test.
- Mantieni le modifiche limitate allo scopo richiesto. Aggiorna la documentazione solo quando cambia il comportamento e segnala eventuali limitazioni rimaste.
