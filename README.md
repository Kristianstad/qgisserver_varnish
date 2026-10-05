# QGIS Server + Varnish i en container

En avbild som bygger på `3liz/qgis-map-server` och lägger till Varnish Cache framför.
Varnish cachar kartbilder (GetMap), teckenförklaringar (GetLegendGraphic) och
GetCapabilities, så att QGIS Server slipper rita samma bild om och om igen.

```
webbläsare ──► Varnish (port 8080, cache) ──► QGIS Server (bara inuti containern)
```

Två program i en container är inte "typiskt Docker", men gör avbilden enkel att
använda: det finns bara en sak att starta. Om något av programmen slutar fungera
avslutas hela containern, så att Docker kan starta om den.

## Filer

| Fil | Vad den gör |
|---|---|
| `Dockerfile` | Bygger avbilden. Här står alla inställningar (`ENV`) med förklaringar. |
| `default.vcl.template` | Varnish-konfigurationen (mall). |
| `start.sh` | Startar QGIS Server och Varnish och håller koll på dem. |
| `LICENSE` | Licens (BSD 2-Clause) för filerna i det här repot. |
| `docker-compose.yml` | Färdigt exempel för att köra avbilden med Docker (fungerar inte med `wslc`, se avsnittet om Windows). |

## Kom igång

> Kör du Windows utan Docker Desktop? Gå till [Köra på Windows med WSL](#köra-på-windows-med-wsl).

1. Lägg dina QGIS-projekt i en mapp, t.ex. `projekt/` (filen `projekt/mittprojekt.qgs`).
2. Bygg och starta:

```bash
docker compose up --build
```

Eller utan compose:

```bash
docker build -t qgis-varnish .
docker run -d --name kartor -p 8080:8080 -v "$PWD/projekt:/qgis-data" qgis-varnish
```

3. Testa i webbläsaren (byt ut `mittprojekt` mot ditt projektnamn):

- `http://localhost:8080/ping` – ska svara `{"status": "ok"}`
- `http://localhost:8080/ows/mittprojekt?SERVICE=WMS&REQUEST=GetCapabilities`
- Det "vanliga" formatet fungerar också: `http://localhost:8080/ows/?MAP=mittprojekt.qgs&SERVICE=WMS&REQUEST=GetCapabilities`

Det första anropet tar längre tid (QGIS laddar projektet). Upprepa samma anrop så ser
du att det går snabbare – då kommer svaret från cachen.

> Dina QGIS-projekt måste vara läsbara för användaren med id 9001 (den QGIS Server körs som).
> Kör inte containern med `--user`.

## Köra på Windows med WSL

Sedan WSL 2.9.3 kan Windows köra Linux-containrar direkt, utan Docker Desktop, med kommandot
`wslc`. Allt görs i **PowerShell**. (Har du redan Docker Desktop fungerar instruktionerna ovan som de står.)

### 1. Installera eller uppdatera WSL

Du behöver Windows 11 (eller Windows 10 version 2004 / build 19041 eller senare) och virtualisering
påslaget i datorns BIOS/UEFI (heter ofta *Intel VT-x*, *AMD-V* eller *SVM Mode*; är oftast redan på).

1. Öppna PowerShell **som administratör**: högerklicka på Start-knappen och välj *Terminal (administratör)*,
   eller sök på "PowerShell" och välj *Kör som administratör*.
2. Installera WSL. Containrar behöver ingen Linux-distribution, så den hoppas över:

   ```powershell
   wsl --install --no-distribution
   ```

   (Vill du även ha ett vanligt Linux-fönster, t.ex. Ubuntu, kör du i stället `wsl --install`.)
3. **Starta om datorn.**
4. Uppdatera WSL till senaste versionen (görs även om WSL redan var installerat sedan tidigare):

   ```powershell
   wsl --update
   ```
5. Kontrollera att allt fungerar:

   ```powershell
   wsl --version      # WSL-versionen ska vara 2.9.3 eller högre
   wslc version
   wslc run --rm hello-world
   ```

   Den sista raden hämtar en liten testavbild och ska skriva ut ett "Hello"-meddelande.

### 2. Bygg avbilden

Lägg filerna från det här paketet i en mapp, t.ex. `C:\kartor\qgis-varnish`, och kör:

```powershell
cd C:\kartor\qgis-varnish
wslc build -t qgis-varnish .
```

Första bygget tar några minuter eftersom basavbilden är stor. Kontrollera resultatet med `wslc image list`.
Om `wslc` säger att den inte hittar någon `Containerfile` (det är WSL:s namn för Dockerfile), ange filen själv:
`wslc build -f Dockerfile -t qgis-varnish .`

### 3. Starta containern

Lägg dina QGIS-projekt i en mapp, t.ex. `C:\kartor\projekt`, och starta:

```powershell
wslc run -d --rm --name kartor -p 8080:8080 -v "C:\kartor\projekt:/qgis-data" qgis-varnish
```

| Del | Betydelse |
|---|---|
| `-d` | Kör i bakgrunden. |
| `--rm` | Containern tas bort automatiskt när du stoppar den. |
| `--name kartor` | Namnet du använder i övriga kommandon. |
| `-p 8080:8080` | Gör port 8080 i containern nåbar på `http://localhost:8080`. Är porten upptagen, använd t.ex. `-p 8081:8080`. |
| `-v "C:\kartor\projekt:/qgis-data"` | Gör Windows-mappen synlig i containern. Windows-sökväg till vänster, `/qgis-data` till höger. |

Inställningar (se tabellen längre ner) läggs till med `-e`, t.ex. `-e QGSRV_SERVER_WORKERS=4 -e VARNISH_CACHE_SIZE=512m`.

Testa sedan i webbläsaren: `http://localhost:8080/ping` ska svara `{"status": "ok"}`.
(Vill du testa från PowerShell, skriv `curl.exe` och inte bara `curl`, annars körs ett annat kommando.)

> `docker-compose.yml` går inte att använda med `wslc`, eftersom Compose-stöd ännu saknas i WSL-containrar.
> Använd kommandona ovan, eller Docker Desktop om du vill använda compose.

### 4. Vardagskommandon

| Vad du vill göra | Docker | WSL (`wslc`) |
|---|---|---|
| Se körande containrar | `docker ps` | `wslc container list` |
| Läsa loggar | `docker logs kartor` | `wslc container logs kartor` |
| Köra ett kommando i containern | `docker exec kartor ...` | `wslc exec kartor ...` |
| Stoppa | `docker stop kartor` | `wslc container stop kartor` |
| Se resursanvändning | `docker stats` | `wslc stats` |
| Ta bort stoppade containrar / oanvända avbilder | `docker container prune` / `docker image prune` | `wslc container prune` / `wslc image prune` |

Alla kommandon längre ner i den här filen som börjar med `docker exec` körs alltså som `wslc exec`, t.ex.
för att rensa cachen:

```powershell
wslc exec kartor curl -X BAN -H "X-Ban-Project: mittprojekt" http://localhost:8080/
```

Ska du ändra något (nya inställningar eller en ny version av avbilden): stoppa containern och kör `wslc run ...` igen.

### Felsökning på Windows

- **`wsl --install` klagar på virtualisering:** slå på virtualisering i BIOS/UEFI (se ovan) och försök igen.
- **`wslc` hittas inte:** kör `wsl --update`, stäng PowerShell och öppna ett nytt fönster, och kontrollera att `wsl --version` visar 2.9.3 eller högre.
- **Containern stannar direkt eller projekten hittas inte:** läs `wslc container logs kartor`. Kontrollera att sökvägen efter `-v` stämmer och att projektmappen finns.
- Microsofts guide: <https://learn.microsoft.com/en-us/windows/wsl/tutorials/wsl-containers>

## Så fungerar cachen

- Bara `GET`/`HEAD` av `REQUEST=GetMap`, `GetLegendGraphic` och `GetCapabilities` cachas. Allt annat går rakt igenom.
- Ett svar cachas i `VARNISH_DEFAULT_TTL` sekunder (standard 60). Lägg till `&ttl=300` i
  webbadressen för att cacha 300 sekunder (högst 90000), eller `&ttl=0` för ingen cache alls.
- Parametern `time` tas bort före cachning (typisk "cache-busting"-parameter). Ändra med `VARNISH_STRIP_PARAMS`.
- Parametrarnas ordning spelar ingen roll: samma anrop i annan ordning delar cache.
- Snygga adresser: `/ows/<projekt>?...` skrivs om till `/ows/?map=<projekt>.qgs&...`
  (använd `VARNISH_PROJECT_EXTENSION=qgz` om dina projekt är `.qgz`).

### Rensa cachen

Cachen kan rensas per projekt eller per lager (kommandot körs inuti containern):

```bash
docker exec kartor curl -X BAN -H "X-Ban-Project: mittprojekt" http://localhost:8080/
docker exec kartor curl -X BAN -H "X-Ban-Layer: mittlager" http://localhost:8080/
```

Projektnamnet skrivs utan `.qgs`/`.qgz` (men med eventuell undermapp, t.ex. `mapp/mittprojekt`).
Namn med mellanslag eller å/ä/ö skrivs URL-kodade, t.ex. `Fastighetsgr%C3%A4nser%20norra`.
Rensning utifrån är avstängd som standard; se `VARNISH_BAN_HOST` nedan.

### Rensa cachen från en webbsida

Det finns också en enkel webbsida där man kan skriva in ett projekt eller ett lager och rensa dess cache.
Sidan är **avstängd** tills du anger användare och lösenord (minst 8 tecken):

```bash
docker run -d --name kartor -p 8080:8080 -v "$PWD/projekt:/qgis-data" \
    -e VARNISH_ADMIN_USER=admin -e VARNISH_ADMIN_PASSWORD='byt-till-ett-langt-losenord' qgis-varnish
```

Öppna sedan `http://localhost:8080/_admin` och logga in. (Används `VARNISH_URL_PREFIX` ligger sidan på `<prefix>/_admin`.)
Med `wslc` på Windows läggs samma `-e`-flaggor till i `wslc run`-kommandot.

Bra att veta:

- **Använd https om sidan nås över ett nätverk.** Lösenordet skickas annars i klartext. På den egna datorn
  (`localhost`) går det bra utan. Lägg en proxy med https framför containern, t.ex. Traefik eller nginx.
- **Välj ett långt lösenord.** Det finns ingen spärr mot att någon gissar.
- **Ingen IP-begränsning ingår.** I Docker Desktop ser containern inte klientens riktiga IP-adress (alla anrop
  ser ut att komma från samma adress), och det kan gälla WSL-containrar också. Vill du begränsa vem som når sidan, gör det i en
  proxy eller brandvägg framför containern. Ska bara den egna datorn nå den kan du i Docker publicera porten
  bara lokalt: `-p 127.0.0.1:8080:8080`.
- Sidan skyddar mot att en annan webbplats får din webbläsare att rensa cachen i smyg.
- Skriv namnen som vanligt (mellanslag och å/ä/ö fungerar). Namn med parenteser, citattecken, `!` eller `~`
  stöds inte här; rensa i så fall hela projektet. Ett lager rensas i alla projekt.
- Sidan kan inte visa vad som ligger i cachen, bara rensa det du skriver in.

## Inställningar

Sätts med `-e NAMN=värde` (docker run) eller under `environment:` (compose).

| Variabel | Standard | Betydelse |
|---|---|---|
| `VARNISH_CACHE_SIZE` | `256m` | Cachens storlek i RAM (t.ex. `1g`). Låt containern få mer minne än så. |
| `VARNISH_DEFAULT_TTL` | `60` | Sekunder ett svar cachas när anropet saknar `ttl`. |
| `VARNISH_BACKEND_TIMEOUT` | `120` | Hur länge Varnish väntar på QGIS Server. `QGSRV_SERVER_TIMEOUT` blir 1 sekund mindre. |
| `VARNISH_MAX_CONNECTIONS` | tomt | Max samtidiga anrop till QGIS Server. Tomt = `QGSRV_SERVER_WORKERS` × 6. |
| `VARNISH_MAX_RETRIES` / `VARNISH_MAX_RESTARTS` | `2` / `1` | Antal nya försök vid 503/504. |
| `VARNISH_CACHE_REQUESTS` | `GetMap\|GetLegendGraphic` | Vilka `REQUEST`-typer som cachas (t.ex. `GetMap\|GetLegendGraphic\|GetTile`). |
| `VARNISH_STRIP_PARAMS` | `time` | Parametrar som tas bort före cachning (`\|`-separerade, tomt = inga). |
| `VARNISH_URL_PREFIX` | tomt | Prefix för snygga adresser, t.ex. `/kartor`. |
| `VARNISH_PROJECT_EXTENSION` | `qgs` | Filändelse som läggs på projektnamnet i snygga adresser (`qgs` eller `qgz`). |
| `VARNISH_FORCE_HTTPS` | `no` | `yes` om en proxy framför hanterar https men inte skickar `X-Forwarded-Proto`. |
| `VARNISH_BAN_HOST` | tomt | Host-värde som får rensa cachen utifrån. Använd bara om Varnish inte är nåbar för obehöriga. |
| `VARNISH_ADMIN_USER` / `VARNISH_ADMIN_PASSWORD` | tomt | Slår på adminsidan `/_admin` för cache-rensning. Båda måste anges; lösenordet minst 8 tecken. |
| `VARNISH_PROBE_URL` | `/ping` | Adress för hälsokontroller mot QGIS Server. |
| `VARNISH_PORT` | `8080` | Porten Varnish lyssnar på. |
| `VARNISH_EXTRA_OPTS` | se Dockerfile | Avancerat: Varnish-parametrar (trådar, keepalive m.m.). |
| `QGSRV_SERVER_WORKERS` | `2` | Antal QGIS-processer. Sätt gärna lika med antalet CPU-kärnor. |

Övriga `QGSRV_...`-inställningar för QGIS Server (t.ex. `QGSRV_CACHE_SIZE`,
`QGSRV_LOGGING_LEVEL`) fungerar som i `3liz/qgis-map-server`.

Vill du ersätta hela Varnish-konfigurationen? Montera din egen fil som
`/etc/varnish/custom.vcl` – då används den i stället. Backend heter `qgis`.

## Felsökning

- **Loggar:** `docker logs kartor`
- **Cache-statistik:** `docker exec kartor varnishstat -1` (träffar/missar, skrivs ut en gång) och `docker exec kartor varnishlog` (varje anrop, avsluta med Ctrl+C)
- **Containern startar inte:** läs sista raderna i `docker logs`. Felaktiga inställningar och fel i VCL ger ett tydligt felmeddelande.
- **503 de första sekunderna efter start:** QGIS Server laddar fortfarande. Containern markeras som "healthy" när allt är igång (`docker ps`).
- **Projektet hittas inte:** kontrollera att mappen är monterad på `/qgis-data` och att filnamnet stämmer.

## Licens

Filerna i det här repot är utgivna under BSD 2-Clause-licensen, se [LICENSE](LICENSE).

Licensen gäller bara filerna i repot. Den byggda avbilden innehåller även bland annat QGIS, py-qgis-server,
Varnish och Ubuntu-paket, som har sina egna licenser. Licenstexterna för Ubuntu-paketen finns i avbilden under
`/usr/share/doc/<paketnamn>/copyright`.
