# Checkpoint 1 — Süreç sahipliği ve temiz çıkış

**Tarih:** 27 Eylül 2026
**Durum:** Tamamlandı. §14 ortam eki F1–F7 ile doğrulandı; son review düzeltmeleri §16’da. Hızlı ayrışan rc daemonları için tam geliştirme izolasyonu kullanıcı kararıyla ayrı plana alındı. Ortam eki sonuçları §15’te, önceki kabul kanıtları ve destek sınırları §13’te. CP2 işleri §12.4’te.
**Dayanak:** [Ürün sözleşmesi](../LOOM-PRODUCT-CONTRACT.md) §6, §9 ve §11'deki 1. checkpoint.

## 1. Amaç

Şu soruya kanıtla cevap vermek: Loom, Claude Code ve Codex'i gerçek terminal deneyimiyle başlatıp normal Quit'ten sonra kendine ait hiçbir süreç bırakmadan ve Loom dışındaki oturumlara dokunmadan kapatabiliyor mu?

Codex'in iki çalışma yolundan hangisinin bu şartı sağladığı da bu checkpoint'te belirlenir:

- **Yol (a):** Loom'a ait `codex app-server` ve ona `--remote` ile bağlanan gerçek TUI.
- **Yol (b):** Paylaşılan daemon kullanımı kapatılmış doğrudan TUI.

## 2. Ön kararlar

- Çekirdek Swift ile bu repoda yazılır. Bu checkpoint'in kodu atılacak bir prototip değil, uygulamanın çekirdeğidir.
- Deneyler izole CLI profillerinde yapılır: ayrı `CLAUDE_CONFIG_DIR` ve `CODEX_HOME`. Kullanıcının gerçek `~/.claude` ve `~/.codex` dizinleri, çalışan oturumları ve ChatGPT.app süreçleri deneme malzemesi değildir; bunlar yalnızca okunarak etkilenmedikleri doğrulanır.
- Minimum macOS sürümü arayüz aşamasına kadar açık. Paket geçici olarak yalnızca geliştirme makinesini hedefler.

**Kapsam dışı:** durum ve devam (CP2), oturumlar arası teslim (CP3), silme (CP4), terminal motoru, arayüz ve GPU (CP5), katalog ve SQLite.

## 3. Ortam

- Swift 6.4, Command Line Tools (Xcode kurulu değil) → SwiftPM ve Swift Testing.
- Claude Code 2.1.280, codex-cli 0.157.1. Sürümler sabitlenmez; sonuçlar bu sürümlerle kaydedilir ve `loom-probe` ile yeni sürümlerde tekrarlanabilir.
- Deney kökü: `~/Library/Application Support/Loom-Dev/probe/`

| Dizin | Kullanım |
| --- | --- |
| `claude-config/` | `CLAUDE_CONFIG_DIR`; ayrı Keychain girdisi ve ayrı supervisor örneği |
| `codex-home/` | `CODEX_HOME`; ayrı giriş bilgisi ve daemon durumu |
| `workspace/` | Deney oturumlarının çalışma dizini (boş bir git reposu) |
| `runs/<run-id>/` | Her senaryonun JSON kaydı ve okunur özeti |

İzolasyonun sınırı: `/tmp/claude-<uid>/`, `/tmp/cc-socks/` ve macOS süreç tablosu paylaşılır. Bu yüzden dış süreç kontrolleri bu checkpoint'in parçasıdır.

## 4. Kullanıcıdan gereken hazırlık

Tek sefer, B ve C senaryolarından önce:

1. İzole Claude profilinde onboarding, `/login` ve `workspace/` için güven onayı; ardından `/exit`.
2. İzole Codex profilinde `codex login`.

Kesin komutlar dizinler oluşturulunca verilir. B ve C senaryoları kısa model turları harcar. Toplam 10–15 tek satırlık tur öngörülüyor; düşük maliyetli model ve düşük çaba ayarı kullanılır. Ağ veya hesap sorunu turu engellerse ilgili senaryo "doğrulanmadı" olarak kalır.

## 5. Bu checkpoint'te yazılacak yapı

Swift paketi `Loom`:

- **`LoomCore`** (library)
  - `LaunchEnvironment`: Temiz başlangıç ve launchd oturum ortamından macOS `/bin/zsh` login/etkileşimli ortamını çözer, kullanıcı rc export’larını korur ve sonucu çalışma boyunca önbelleğe alır. Üst oturum değişkenleri taşınmaz; `TERM`, `LOOM_RUN_ID` ve `LOOM_SESSION_ID` eklenir. Hata, yanıtsız giriş ve zaman aşımı açık başarısızlıktır.
  - `PTYProcess`: Süreci kendi Unix session'ında, controlling terminal'i PTY olacak şekilde başlatır; master fd, pencere boyutu ve çıkış izleme.
  - `ProcessTable`: `sysctl(KERN_PROC_ALL)` ile süreç listesi; PID ve başlangıç zamanı, ppid, pgid, sid; `KERN_PROCARGS2` ile argüman ve ortam işareti okuma.
  - `OwnershipLedger`: Loom’un session’ları, görülen torunları ve yalnızca doğrulanmış özel resource coalition kimliği; PID + başlangıç zamanı ve boot kimliğiyle kalıcı kurtarma.
  - `ShutdownCoordinator`: Çıkış sırası, süpürme ve sonuç raporu.
  - `ProviderLaunchProfile`: Claude ve Codex için komut, ortam ve ayar üretimi; bayrak ve özellik varlığı için yetenek sınamaları.
- **`loom-probe`** (executable): Senaryoları çalıştırır ve sonuçları `runs/` altına yazar. Sağlayıcı sürümü değişince aynı sınamaları tekrarlamak için kalıcıdır.
- **`loom-test-child`** (executable, yalnızca test): Kaçış davranışlarını taklit eden sentetik süreç.
- **`LoomCoreTests`**: Swift Testing.

## 6. Uygulanacak çıkış sözleşmesi

1. Yeni başlatmalar durdurulur.
2. Sahip olunan her session'a sırasıyla `SIGHUP` (terminal kapanması), kısa bekleme, `SIGTERM`, bekleme ve gerekirse `SIGKILL` gönderilir. Sinyal yalnızca ön plan grubuna değil, session'daki bütün süreçlere gider; iş kontrolü yapan kabuklar ayrı process group açar.
3. Süpürme üç kümeyi kapsar:
   - sid'i Loom session'larından biri olan süreçler (session lideri öldükten sonra da),
   - ledger'daki torunlar (PID ve başlangıç zamanı eşleşirse),
   - `LOOM_RUN_ID` işaretli süreçler.
4. İşaretsiz ve ledger'da olmayan hiçbir sürece sinyal gönderilmez. PID yeniden kullanımına karşı her sinyalden önce başlangıç zamanı karşılaştırılır.
5. Üç küme yeniden sorgulanır ve boş olduğu doğrulanır.
6. Kalan süreç varsa listelenir ve Quit başarı gibi tamamlanmaz. Zorla kapatma ayrı ve açık bir seçenektir.

Bekleme süreleri ve toplam kapanma süresi kaydedilir; bütçe sonraki ölçümlerle belirlenir.

## 7. Senaryolar

### A — Sentetik (model yok, `swift test` ile tekrarlanabilir)

| # | Senaryo | Beklenen |
| --- | --- | --- |
| A1 | PTY'de basit çocuk; Quit | Süreç kalmaz; controlling terminal'in PTY olduğu gösterilir. |
| A2 | `SIGHUP` ve `SIGTERM`'i yok sayan çocuk | `SIGKILL` ile kapanır; süre kaydedilir. |
| A3 | Yeni process group açan torun | Session süpürmesi yakalar. |
| A4 | `setsid` ve çift fork ile launchd'ye geçen torun (Apple dışı binary) | Ortam işareti yakalar. |
| A5 | Aynı kaçış, Apple platform binary'si (`/bin/sleep`) ile | İşaret görünmez. Ledger yakalayamazsa sınır açıkça raporlanır ve anlık görüntü stratejisi ayrıca karara bağlanır. |
| A6 | `loom-probe` bir Claude oturumunun içinden çalıştırılır | Çocuk ortamında `CLAUDECODE` ve `CLAUDE_CODE_*` yok, `LOOM_*` var. |
| A7 | Loom dışından başlatılmış işaretsiz süreç | Quit ve süpürmeden etkilenmez. |
| A8 | `loom-probe` `kill -9` ile öldürülür, sonra yeniden açılır | Çökme anında kalanlar kaydedilir; açılıştaki önceki `LOOM_RUN_ID` süpürmesi sonrası sıfır süreç kalır. |

### B — Codex (izole `CODEX_HOME`)

| # | Senaryo | Beklenen / kaydedilecek |
| --- | --- | --- |
| B0 | Başlangıç durumu ve `codex login` sonrası durum | Daemon soketi, pid dosyası ve `app-server daemon version` çıktısı. İzole daemon çalışıyorsa durdurulur ve kaydedilir. |
| B1 | Düz `codex` PTY'de | Daemon kendiliğinden başlıyor mu? Soket, `app-server` süreci, ebeveyninin launchd olup olmadığı, `LOOM_RUN_ID` taşıyıp taşımadığı. |
| B2 | `codex --no-daemon` | Daemon başlamaz; süreç ağacı kaydedilir. |
| B3 | `--disable daemon_auto_start` (yalnızca özellik listesinde varsa) | B1 ile fark. |
| B4 | Yol (a): PTY altında `codex app-server --listen unix://<run>/codex.sock` ve `codex --remote unix://…` | TUI normal çalışır (prompt, çıktı, resize); daemon başlamaz. |
| B5 | Yol (a) kimlik: Loom `thread/start` ile thread açar, TUI `resume <id> --remote` ile açılır | Sohbet kimliği baştan bellidir. |
| B6 | Yol (a) onay: onay gerektiren komut isteyen bir tur | Onay TUI'de görünür. Loom istemcisine de istek gelip gelmediği ve biri cevaplayınca diğerine `serverRequest/resolved` gidip gitmediği kaydedilir. |
| B7 | Her iki yol: çalışan tur ve arka plan terminali açıkken Quit | Sıfır süreç. |
| B8 | Her iki yol: `kill -9` ile çökme | Yol (a)'da PTY altındaki app-server `SIGHUP` ile kapanıyor mu; kalanlar ve sonraki açılış süpürmesi. |
| B9 | Her iki yol: kaynak | Oturum başına süreç sayısı ve physical footprint; boşta, tek oturum ve üç oturum. |
| B10 | Dış etki | ChatGPT.app'in `codex app-server` süreci (PID + başlangıç zamanı) ve gerçek `~/.codex` daemon durumu değişmez. |

### C — Claude (izole `CLAUDE_CONFIG_DIR`)

Başlatma profili: `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`, `--session-id <uuid>` ve `--settings` ile `crossSessionInbound: "refuse"`. Mesaj engelinin tam doğrulaması CP3'tedir.

| # | Senaryo | Beklenen / kaydedilecek |
| --- | --- | --- |
| C1 | Profille açılış | Supervisor başlamaz (izole dizinde daemon durumu ve süreci yok); transkript verilen `--session-id` ile oluşur. |
| C2 | Arka planda uzun komut çalışırken `/exit` ve `SIGHUP` | Diyalog çıkıp çıkmadığı, arka plan işinin akıbeti ve süreç ağacındaki yeri (aynı session mı, kaçmış mı). |
| C3 | Çalışan tur sırasında Quit | Sıfır süreç. |
| C4 | `--mcp-config` ile verilen sentetik stdio MCP sunucusu | Quit sonrası kalmaz. |
| C5 | Kontrol: yalnızca izole profilde agent view açıkken C2 | İşin supervisor'a devredilip Loom dışına çıktığı gösterilir; kapatma kararının gerekçesi kanıtlanır. İzole supervisor sonra durdurulur. |
| C6 | `kill -9` ile çökme | `SIGHUP` ile kapanış, kalanlar ve sonraki açılış süpürmesi. |
| C7 | Dış etki | İzole profilde Loom dışından açılmış bir `claude` oturumu Quit'ten etkilenmez; gerçek profildeki oturumlar (`claude agents --json`, yalnızca okuma) değişmez. |

### D — Birleşik

| # | Senaryo | Beklenen |
| --- | --- | --- |
| D1 | Aynı anda iki Claude, seçilen yolla iki Codex ve bir sentetik kaçak; tek Quit | Sıfır süreç; toplam kapanma süresi kaydedilir. |

## 8. Kabul ölçütleri

- Normal Quit sonrası Loom session'larında, ledger'da ve `LOOM_RUN_ID` işaretiyle eşleşen süreç yoktur. İzole profillerde Loom'un başlattığı daemon veya supervisor yoktur.
- Dış süreçler (sentetik dış süreç, izole profildeki dış oturum, ChatGPT.app app-server, gerçek profil oturumları) PID ve başlangıç zamanıyla aynı kalır.
- Yönetilen çocuklarda üst oturum değişkeni yoktur.
- Seçilen Codex yolu şu şartların hepsini sağlar:
  - daemon'sız çalışır,
  - gerçek TUI deneyimini korur,
  - onayları kullanıcıya gösterir,
  - Quit sonrası sıfır süreç bırakır.

  İki yol da sağlıyorsa CP2 için kimlik ve durum olanakları ile kaynak maliyeti belirleyicidir.
- Çökme ve Force Quit sonucu ayrı raporlanır; normal Quit sonucuna genellenmez.
- Her madde **doğrulandı / başarısız / doğrulanmadı** olarak, komut ve çıktı kanıtıyla bu dosyanın sonuç bölümüne yazılır.

## 9. Uygulama sırası

1. Paket iskeleti, `LaunchEnvironment`, `ProcessTable` ve `PTYProcess`; A1 ve A6.
2. `OwnershipLedger` ve `ShutdownCoordinator`; A2–A5, A7 ve A8.
3. Kullanıcı hazırlığı (izole profillerde giriş).
4. B senaryoları → Codex yolu önerisi.
5. C senaryoları → Claude başlatma profili.
6. D1, sonuç raporu ve sözleşme güncelleme önerisi (§6 Codex yolu, §12 çıkış sınırı).

## 10. Bilinen riskler

- **PTY ve yeni session:** Swift'te `fork` sonrası yalnızca async-signal-safe çağrılar yapılabilir. `forkpty` + `exec` ile `posix_spawn` + `POSIX_SPAWN_SETSID` karşılaştırılacak; controlling terminal'in doğru kurulduğu A1 ile gösterilecek.
- **Torun takibi:** macOS'ta fork'ları olayla izleme olanağının (`NOTE_TRACK`) desteklenmediği biliniyor; doğrulanacak. Ledger anlık görüntüye dayanır ve kaçan Apple platform binary'leri gözden kaçabilir (A5).
- **Sürüm değişimi:** Codex ve Claude davranışı sürümle değişebilir; sonuçlar sürüme bağlı kaydedilir.
- **İzolasyon sınırı:** İzole profiller `/tmp` altındaki paylaşılan dizinleri ve süreç tablosunu ayırmaz.

## 11. Sonuçlar

### 27 Eylül 2026 — ilk uygulama

Bu alt bölüm ilk çalıştırmanın kaydıdır; güncel sağlayıcı sonuçları bir sonraki alt bölümdedir.

`Package.swift` ile `LoomCore`, `loom-probe`, `loom-test-child` ve Swift Testing hedefleri eklendi. PTY açılışı `openpty` + C içinde `fork`/`setsid`/`TIOCSCTTY`/`execve` kullanıyor; fork sonrası Swift çalışmıyor. Exec hatası pipe üzerinden üst sürece iletiliyor ve başarısız çocuk reap ediliyor. `posix_spawn` yolu ayrıca karşılaştırılmadı.

`LaunchEnvironment` izin listesi kullanıyor. `ProcessTable` süreç kimliğini PID + başlangıç zamanı ile tutuyor. `OwnershipLedger` session, gözlenen torun ve run işaretini birleştiriyor. `ShutdownCoordinator` yeni başlatmaları durdurup HUP → TERM → KILL uygular ve tekrar tarar. Her sinyalden önce kimlik okunur; macOS'ta kimlik kontrolü ile `kill` arasındaki yarış atomik olarak kapatılamaz.

Probe, run kimliğini başlatmadan önce diske yazar. `owner.json` bulunan tamamlanmamış eski run'lar sonraki başlangıçta temizlenir; hâlâ yaşayan sahibi olan run atlanır. Çökme sonrası temizlik, uygulama kapalıyken sıfır süreç garantisi değildir. `recover <ledger.json>` açık kurtarma komutudur. İlk geliştirme denemelerinden kalan `owner.json` olmayan kayıtlar otomatik sahiplenilmez.

Swift Testing için paket şimdilik macOS 14 derleme tabanını kullanıyor; yalnızca bu geliştirme makinesinde denendi. Bu, ürünün minimum macOS sürümü kararı değildir. Kurulu Swift 6.4/Command Line Tools ile macOS 27 hedefinde Testing makrosunun bulunamaması görüldü; macOS 14 tabanıyla varsayılan `swift test` çalıştı. SDK'nın eksik Frameworks arama dizinleri hakkında linker uyarıları var.

| Senaryo | Durum | Kanıt / sınır |
| --- | --- | --- |
| A1 | Doğrulandı | `controllingTerminalAndEnvironment`: ayrı sid, PTY, 31×97 boyut ve resize çağrısı; çıkışta kalıntı yok. Probe `inspect`: 0,028 sn. |
| A2 | Doğrulandı | `escalatesStubbornChild`: HUP/TERM yok sayılır, KILL gönderilir. Probe `stubborn`: 0,446 sn. |
| A3 | Doğrulandı | `sweepsOtherProcessGroup`: ayrı pgid, aynı sid; kapanışta kalıntı yok. Probe: 0,432 sn. |
| A4 | Doğrulandı | `findsReparentedMarkedProcess`: çift fork + ayrı session, run işaretiyle bulunur. Probe: 0,457 sn. |
| A5 | **Sıfır süreç ölçütü başarısız; sınır doğrulandı** | İlk gözlemden önce kaçan `/bin/sleep` işaretsiz ve ledger dışında kalır. `documentsUnobservedAppleEscapeBoundary` bu açığı bekleyerek doğrular. Probe `apple-escape`, sahiplik kümesi boş olmasına rağmen bağımsız fixture PID'sinden 1 canlı kalıntı saptadı ve FAIL döndü. Test temizliği yalnızca bilinen sentetik PID + başlangıç zamanıyla yapıldı. |
| A6 | Kısmen doğrulandı | Enjekte edilen `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CODEX_HOME` ve ek token çocuğa taşınmadı; Loom işaretleri taşındı. Gerçek Claude içinden başlatma henüz denenmedi. |
| A7 | Doğrulandı | `leavesExternalProcessUntouched`: bağımsız `/bin/sleep`, aynı PID + başlangıç zamanı ile yaşamaya devam etti. |
| A8 | Doğrulandı (sentetik) | `recoversRunAfterOwnerSIGKILL`: probe SIGKILL ile ölür; kaçmış işaretli süreç kalır; yeni probe `recover-stale` ile önceki run'ı temizler. Apple işaretsiz kaçışını kapsamaz. |
| B0–B10 | Doğrulanmadı | Yalnızca sürüm ve seçenek varlığı sınandı; giriş, model turu, TUI/onay, daemon, footprint ve dış Codex/ChatGPT etkisi deneyleri yapılmadı. |
| C1–C7 | Doğrulanmadı | Yalnızca sürüm ve seçenek varlığı sınandı. Agent View engelinin davranışı, supervisor, MCP ve dış Claude etkisi deneyleri yapılmadı. |
| D1 | Doğrulanmadı | Sağlayıcı deneyleri bekleniyor. |

**Önemli:** `ShutdownReport.succeeded`, taranabilen sahiplik kümelerinin boşluğunu bildirir. A5 yüzünden bu sonuç tüm olası torunların yokluğu olarak sunulamaz. Testteki bağımsız fixture PID'si ürünün sahiplik algoritmasına verilmez. Daha sık anlık görüntü alma kaçış penceresini küçültür; tek başına sıfır kaçış kanıtı değildir. `NOTE_TRACK`/olay tabanlı izleme karşılaştırması henüz yapılmadı. Çekirdek şu anda seri kullanılır; host'un çalışma sırasında `sample()` çağırması gerekir.

Ek testler: başarısız exec'in temizlenmesi, kapanış başladıktan sonra launch reddi, yanlış başlangıç zamanlı PID'ye sinyal verilmemesi, desteklenmeyen sağlayıcı seçeneklerinin reddi. `swift test`: 11 test / 2 suite geçti (3,642 sn). `swift build` başarılı. C katmanları `clang -Wall -Wextra -Werror` ile derlendi.

#### Tekrarlama ve kayıtlar

```sh
swift test
swift run loom-probe prepare
swift run loom-probe capabilities
swift run loom-probe synthetic inspect
swift run loom-probe synthetic stubborn
swift run loom-probe synthetic group
swift run loom-probe synthetic escape
swift run loom-probe synthetic apple-escape # bilinen sınır: exit 1 beklenir
```

Ham kayıt kökü: `~/Library/Application Support/Loom-Dev/probe/runs/`. Run başına `ledger.json`, `terminal.txt`, `shutdown.json`, `oracle-remaining.json`, `summary.txt`; kurtarmada `recovery.json`. Kayıtlara tam ortam veya kimlik bilgileri yazılmaz.

Bu çalıştırmanın kanıtları:

- Yetenekler: `capabilities-8F9D7AC0-4A1E-47AB-B4B2-1BACB2642C09` — codex-cli **0.157.1**, Claude Code **2.1.280**. Codex `--no-daemon`, `--remote`, app-server `--listen`, `daemon_auto_start`; Claude `--session-id`, `--settings` mevcut.
- A1: `AEFEABA1-6342-49F3-BE9B-6FD0D0559AD2`.
- A2: `F2D53296-CD75-4508-9EB7-D18E82955758`.
- A3: `495C1AE1-FB74-4C22-9929-1DF8B92F6203`.
- A4: `5A46E6A1-597E-42D0-90B1-8A80ED8DA604`.
- A5: `A814569B-D054-458A-92A0-E1F854CBF95B`.

#### İlk kullanıcı hazırlığı (tamamlandı)

B ve C için gerçek profilden kimlik bilgisi kopyalanmaz. Dizinler ve boş Git çalışma alanı hazırlandı. Aşağıdaki komutları kendi terminalinde çalıştır:

```sh
cd "$HOME/Library/Application Support/Loom-Dev/probe/workspace"
env -i HOME="$HOME" USER="$USER" SHELL=/bin/zsh TERM=xterm-256color \
  PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  CLAUDE_CONFIG_DIR="$HOME/Library/Application Support/Loom-Dev/probe/claude-config" \
  CLAUDE_CODE_DISABLE_AGENT_VIEW=1 \
  claude --settings '{"crossSessionInbound":"refuse"}'
```

Claude içinde onboarding, gerekiyorsa `/login` ve bu boş çalışma alanının güven onayını tamamla; ardından `/exit`.

```sh
env -i HOME="$HOME" USER="$USER" SHELL=/bin/zsh TERM=xterm-256color \
  PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  CODEX_HOME="$HOME/Library/Application Support/Loom-Dev/probe/codex-home" \
  codex login
```

Kullanıcı iki izole profilde girişi tamamladı. Codex çalışma alanı güveni ayrıca açık kullanıcı onayıyla verildi. Devamındaki sonuçlar aşağıdadır.

### 27 Eylül 2026 — gerçek sağlayıcı ve birleşik deneyler

**Ortam:** Aynı macOS/Swift geliştirme makinesi; codex-cli 0.157.1, Claude Code 2.1.280. Codex turları `gpt-6-luna`/low, Claude turları `haiku`/low ile yürütüldü. Model yanıtları ve arka plan işler gerçek TUI'lerden gönderildi; onay diyaloğu varsayılan olarak geçilmedi. B6'da zararsız test komutunun onayı TUI'den **reddedildi** ve diğer istemcide çözülme olayı gözlendi. Test dosyası oluşturulmadı.

**İzolasyon düzeltmesi:** Başlangıçtaki `codex-home/app-server-control/app-server-control.sock` yolu Darwin `SUN_LEN` sınırını aşıyordu. Kısa bir sembolik bağlantı yeterli olmadı; CLI gerçek yolu çözüyor. Yalnızca deneyin Codex dizini `~/.loom-dev/codex-home` konumuna taşındı, eski deney yolu buraya bağlandı. Giriş korunuyor; gerçek `~/.codex` değiştirilmedi. Yeni `prepare`, izole Codex profilini doğrudan bu kısa konumda oluşturur. Claude profili aynı yerde kaldı. Ayrı app-server soketleri `~/.loom-dev/<run-prefix>.sock` kullanır.

**Çekirdekte düzeltilen gerçek hata:** Claude ile ilk kapanışlarda doğrudan çocuk zombie olarak kalıyor ve `waitpid(WNOHANG)` henüz çıkış döndürmüyordu. PTY master'ı sinyal süpürmesinin sonuna kadar açık tutmak yerine kapanışın başında kapatınca aynı deneyler temiz tamamlandı. Başarısız kanıtlar `7CBC8145-7D0D-4BA0-937C-DDCF06A91E04`, `4B029F9A-589C-44E6-8230-50346D04AA04`, `358ED889-B793-41E0-A6CC-772F65DF9DEB`; düzeltilmiş ilk tekrar `8852E259-B1AE-40E1-816F-581B0D2F244D`. Kernel içindeki bekleme nedeni ayrıca kanıtlanmadı. `/usr/bin/yes` ile denenmiş sentetik test eski kodda da geçtiği için regresyon testi diye tutulmadı; kanıt gerçek Claude tekrarlarıdır.

#### Güncel senaryo sonuçları

Aşağıdaki run kimlikleri `~/Library/Application Support/Loom-Dev/probe/runs/` altındadır. `shutdown.json` sahiplik kümesindeki kalıntıları; `samples.json` PID/başlangıç zamanı, ppid/pgid/sid, executable, run işaretinin görünürlüğü ve physical footprint'i içerir. `external-before.json` ve `missing-external.json` dış süreçlerin tam kimlik karşılaştırmasıdır.

| Senaryo | Durum | Gözlem ve kanıt |
| --- | --- | --- |
| A6 gerçek Claude üst oturumu | Doğrulandı | Claude'un Bash aracı içinden `loom-probe synthetic inspect` çalıştı. `2F79AAA9-B5B6-46E4-9C97-9A571449E6C4/terminal.txt` çocuğunda `CLAUDECODE`/`CLAUDE_CODE_*`/`CODEX_*` yok, Loom işaretleri var. Komut onayı yalnızca bu açık deney için bir kez verildi. |
| B0 | Doğrulandı | Giriş mevcut. Uzun yol hatası düzeltildikten sonra izole daemon kontrol soketi bulunmadı; başlangıçta durdurulacak daemon yoktu. `provider-baseline/` başlangıç/son durum kayıtlarını içerir. |
| B1 | Doğrulandı | Düz TUI izole profiline daemon paketini kurup iki ek Codex süreci başlattı: toplam 3. Örneklemde iki ek sürecin ebeveyni TUI idi, launchd değildi; hepsi run işareti taşıdı ve ayrı session'lar açtı. `DA2D6784-1B6A-4D0E-AF1F-C470C4799C88`; güven sonrası tekrar `728AA06C-F0FB-4456-AA6E-0A99238941B9`: 0 kalıntı, 0,046 sn. |
| B2 | Doğrulandı | `--no-daemon`: tek Codex süreci, gerçek `CODEX_OK` yanıtı; model turu, arka plan terminali ve resize çalıştı. `228B1119-F3D5-438F-A04F-8356D360BB89`. |
| B3 | Doğrulandı | Özellik listesinde `daemon_auto_start` var; `--disable daemon_auto_start` ile güven sonrası da tek süreç ve daemon yok. `17A7E796-3FCE-42AA-97AA-747C78B861A7`: 0 kalıntı, 0,028 sn. Var olan paylaşılan daemon'a bağlanıp bağlanmadığı bu deneyin kanıtı değildir. |
| B4 | Doğrulandı | Ayrı PTY app-server + Unix WebSocket remote TUI: gerçek `REMOTE_OK`, resize ve daemon'sız iki süreç. `32F1416E-0A2C-448B-A6B7-994682421AAC`. |
| B5 | **Başarısız** | `thread/start` id döndürdü; hiç tur almadan `resume <id> --remote` ile açılınca `no rollout found` hatası verdi. `F902F193-4614-4B06-BCFD-FD8905A29BCF`. TUI'nin kendisinin oluşturduğu thread'in kimliği ise ilk prompttan önce ayrı RPC bağlantısına `thread/started` ile geldi. İlk turdan sonra `thread/resume` ile aynı thread'e abone olmak başarılıydı. |
| B6 | Doğrulandı | Remote TUI'de `/usr/bin/touch ~/.loom-dev/approval-probe` için sandbox onayı gösterildi; ayrı istemci `item/commandExecution/requestApproval` (id 0) aldı. TUI'den Esc ile ret sonrası `serverRequest/resolved` (requestId 0) geldi. `32F…/tui-terminal.txt` ve `rpc-rpc.jsonl`. Doğrudan yolun onay diyaloğu ayrıca sınanmadı. |
| B7 | Doğrulandı | Her iki yolda `/bin/sleep 90` arka plan terminali açıkken yeni tur başlatılıp Quit edildi. Doğrudan yol 3 süreç → 0, 0,030 sn (`228B…`); remote yol 4 → 0, 0,429 sn (`32F…`). Remote yolun `background-terminals.json` kaydı gerçek terminal kimliğini içerir. |
| B8 | Doğrulandı (boşta) | Probe SIGKILL: direct `27E8FF33-A106-4DBF-908D-1FA1FEEE1BC2`, remote `1B004F9F-38F4-4A9C-8E51-1405D4B224FE`. Sonraki kontrolde ve `recovery-before.json` içinde 0 süreç; recovery başarılı. Remote app-server da terminal kapanınca sonlandı. Dolu Codex arka plan işiyle çökme bu çalıştırmada sınanmadı. |
| B9 | Doğrulandı (ilk örneklem) | Aşağıdaki kaynak tablosu; `87135F89-A1D5-4DFF-8F87-34670D5FE298` ve `DC950905-7A06-40EE-A932-23C14702D10D`. CPU, uzun süreli boşta davranış ve istatistiksel tekrar yapılmadı. |
| B10 | Doğrulandı | Her deneyde dış Codex/ChatGPT süreçlerinin PID + başlangıç zamanı karşılaştırıldı. Gerçek daemon'ın kontrol soketi başlangıçta da sonda da yoktu. Birleşik deneyde 39 dış süreç kimliği korundu, `missing-external.json` boş. |
| C1 | Doğrulandı | Agent View kapalı açılışta tek Claude, supervisor yok; kısa model turu sonrasında verilen UUID ile transkript oluştu: `aed2066a-d0a3-4a5a-a91f-1c5c1a5d256c`. Run `DE2EFA29-2002-4152-8751-8F15C812CA3A`. `crossSessionInbound` davranışının tam sınaması CP3'e aittir. |
| C2 | Doğrulandı | Arka plan `sleep 60`, ayrı session'daki `/bin/zsh` ve `/bin/sleep` olarak ledger'a girdi; Apple süreçlerinde ortam işareti görünmedi. `/exit`, “Exit and stop tasks” / “Stay” diyaloğu gösterdi; ilk seçenek sonrası 0 süreç (`DE2E…`). SIGHUP/terminal kapanması yolu ayrıca C3'te 0 kalıntıyla bitti. |
| C3 | Doğrulandı | Arka plan `sleep 120` ve yeni aktif tur sırasında Quit: 4 süreç → 0, 0,548 sn. `56FF99BD-748E-48AB-BD96-33C84F78AF3E`. |
| C4 | Doğrulandı | `--mcp-config` ile `loom-test-child mcp` ayrı süreç olarak canlı görüldü; Claude + MCP 2 → 0, 0,594 sn. `709C96E3-4000-4AD8-ADA9-E3E37D58A62F`. Fixture yalnızca initialize/ping/boş tools listesi sunar; 29 sn üst sınırı vardır ve test bu süre dolmadan kapattı. |
| C5 | Doğrulandı | Agent View açıkken `/exit` ek “Move to background and exit” seçeneğini sundu. Bu seçenek sonrasında launchd ebeveynli supervisor, yeni Claude süreçleri ve kaçmış shell/sleep ile 7 süreç kaldı; `claude agents --json` background session gösterdi. Loom Quit 7 → 0, 0,847 sn. `993C5349-8CC9-4A0B-A89B-F06B76B41F74`. Yalnızca izole supervisor kullanıldı. |
| C6 | Doğrulandı (bu örneklem) | `sleep 120` arka plandayken probe SIGKILL. Sonraki `ps` ve yeniden açılış taramasında kalıntı yok; `431E1B07-635B-44E3-96AC-2BDC50E32D6F`. Gözlemler çökme anından sonraki kontrollerdir, anlık sıfır kaynak garantisi değildir. |
| C7 | Doğrulandı | Aynı izole profilde Loom işareti olmadan ayrı terminalde açılan Claude (PID 89178, başlangıç 1790533254.775386), D1 Quit sonrası aynı kimlikle canlıydı. Sonrasında kendi terminalinde Ctrl-D ile kapatıldı. Gerçek `claude agents --json` çıktısı başlangıç/son arasında birebir aynıydı. |
| D1 | Doğrulandı | İki Claude, iki remote TUI, ortak sunucu, sentetik ebeveyn + kaçmış torun: 7 → 0, 0,847 sn. `A7934EDD-F0E0-4F93-8FA5-99290A4CB8CA`. Bu birleşik test başlangıçta/boşta oturumlarla yapıldı; aktif tur + arka plan yükleri B7/C3'te ayrı sınandı. |

#### Kaynak örneklemi

Değerler `proc_pid_rusage` physical footprint toplamıdır; RSS değildir. Paylaşılan sayfaların toplamda çift sayılabilmesi ve ölçümler arasındaki zaman/bellek baskısı nedeniyle bunlar ürün bütçesi veya tekrarlı benchmark sonucu değildir. Probe'un kendisi toplama dahil değil.

| Koşul | Doğrudan `--no-daemon` | Tek app-server + remote TUI'ler |
| --- | --- | --- |
| 0 sağlayıcı oturumu | 0 süreç / 0 MiB | 0 süreç / 0 MiB |
| 1 yeni boşta oturum | 1 süreç / 148,8 MiB | 2 süreç / 203,2 MiB |
| 3 yeni boşta oturum | 3 süreç / 279,6 MiB | 4 süreç / 385,2 MiB |
| 3 oturum Quit | 0 süreç / 0,030 sn | 0 süreç / 0,165 sn |

#### Sonuç ve açık kararlar

- **CP2 için öneri: yol (a), Loom'a ait app-server + remote TUI.** Kaynak örnekleminde daha pahalı; buna karşılık gerçek TUI yanında thread kimliği/durumu ve onay çözülmesi bağımsız istemciden görülebildi. Öneri, B5'in başarılı olduğu anlamına gelmez: ilk kimlik için TUI'nin oluşturduğu `thread/started` olayını kullanmak gerekir; boş `thread/start` → `resume` akışı kullanılamaz. CP2'de aynı sohbetten güvenilir devam ayrıca kanıtlanmalı. Doğrudan `--no-daemon` kaynak açısından güçlü alternatif olarak kalır; nihai ürün kararı verilmedi.
- **Claude profili:** Agent View kapalı, oturuma ait UUID ve `crossSessionInbound: refuse`. Gerçek deneylerde bu profil supervisor devrini önledi ve temiz kapanışı sağladı. Testlerde Chrome entegrasyonu `--no-chrome` ile kapalı tutuldu; bu tüm ürün oturumları için yeni bir özellik kararı değildir.
- **A5 hâlâ açık ve checkpoint kabulünü engelliyor.** Anlık görüntüden önce kaçan, işareti okunmayan Apple binary'si genel garanti dışında kalabiliyor. Daha sık polling olasılığı azaltır, garanti sağlamaz. Yerel SDK `sys/event.h` satır 357 `NOTE_TRACK`, `NOTE_TRACKERR`, `NOTE_CHILD` desteğinin macOS 10.5'ten beri olmadığını; 253–255 `NOTE_FORK` olayının çocuk PID'sini vermediğini söylüyor. Daha güçlü sahiplik mekanizması araştırılmalı veya garanti kapsamı açık bir ürün kararıyla belirlenmeli; burada sessizce daraltılmadı.
- **Çökme sonucu ayrı:** Ölçülen sağlayıcı örneklemleri kalıntısızdı; sentetik A8 ise kalıntı bırakıp sonraki açılışta temizlenebildiğini gösteriyor. “Uygulama kapalıyken hiç iş kalmaz” sonucu çıkarılmaz.

#### Tekrarlama ve son kontroller

```sh
swift build
swift test
swift run loom-probe experiment plans/experiments/codex-baseline.json
swift run loom-probe experiment plans/experiments/codex-direct-resources.json
swift run loom-probe experiment plans/experiments/codex-remote-resources.json
swift run loom-probe experiment plans/experiments/claude-start.json
swift run loom-probe experiment plans/experiments/combined.json
```

`plans/experiments/` kalıcı senaryo girdileridir. `*-live.json`, `claude-agent-view.json`, `claude-crash.json` ve MCP deneyi `control` aşamasında etkileşim bekleyebilir. Bu aşamada run dizinindeki `control.jsonl` dosyasına tek satırlık eylemler eklenir; örnek `{"op":"snapshot","label":"manual-check"}` veya `{"op":"quit"}`. Girdi için `write` ile metni ve Enter'ı ayrı adımlarda gönder; CLI'ın yapıştırma/onay/güven ekranını çıktıdan doğrula. Sonuçtaki **CLEAN yalnızca süreç temizliğidir**, model yanıtı veya tüm kabul koşullarının doğrulandığı anlamına gelmez. `script.json` ve `control.jsonl` gerçek yürütülen adımları saklar; eski thread kimliklerini başka run'larda körlemesine tekrar kullanma.

Normal sonlanma `completed` dosyasını yazar. Crash komutu kasıtlı exit 137/SIGKILL üretir; sonraki `recover-stale` öncesi/sonrası süreçler `recovery-before.json` ve `recovery.json` ile kaydedilir. Daemon/supervisor canlı kalıntısı son kontrolde yoktu. Gerçek profillerden credential/config kopyalanmadı ve gerçek oturumlara sinyal gönderilmedi.

Son `swift build` başarılı; son `swift test` **11/11** geçti (3,856 sn); `git diff --check` temiz. Swift 6.4 Command Line Tools incremental build bazen `TestingMacros` plug-in bulunamadı hatası verdi; kaynak değişmeden `swift build` + `swift test` tekrarı geçti. Bu sorun yalnızca macOS 27 deployment hedefiyle sınırlı değil; toolchain nedeni ayrıca çözülmedi. Yeni transport helper'ı standalone Swift typecheck ve sentetik Unix WebSocket handshake/fragmentation/ping/close/büyük yazma/timeout sınamalarından da geçti. Üretim terminal renderer'ı, uzun süreli kaynak testi ve UI hâlâ kapsam dışı.

Protokol dayanağı: [OpenAI App Server belgesi](https://learn.chatgpt.com/docs/app-server); alan isimleri ve enum değerleri için bu makinedeki `codex app-server generate-json-schema --experimental` çıktısı kullanıldı. Özellikle `sandbox` değeri kurulu şemada `workspace-write`; sürüme göre belge örneği yerine üretilmiş şema doğrulandı.

## 12. Kapanış işleri

**Tarih:** 27 Eylül 2026, sonuçların review'ından sonra.

Kullanıcı iki kararı onayladı ([sözleşme](../LOOM-PRODUCT-CONTRACT.md) §3):

- Belgelenmemiş resource coalition bilgisi, yetenek sınaması ve geri dönüş yoluyla **ek sahiplik güvencesi** olarak kullanılır.
- Yönetilen CLI'lar **kullanıcının terminal ortamını** alır; yalnızca Loom'un üst oturumundan sızabilecek değişkenler dışarıda kalır.

Sorun çıkarsa düzeltilerek ilerlenir. CP1, aşağıdaki kabul koşulu sağlanınca kapanır.

### 12.1. Coalition katmanı (A5'in kapatılması)

Review'daki tek örneklem: `setsid` ve çift fork ile launchd'ye geçen `/bin/sleep`, başlatanın coalition kimliğini korudu; Finder farklı coalition'daydı. Bilgi `proc_pidinfo` ile okunuyor, ama tür (`PROC_PIDCOALITIONINFO`) public SDK'da yok.

Kurallar:

- Katman yalnızca Loom kendi coalition'ına sahipse çalışır. Açılışta coalition'da Loom'dan başka süreç varsa (örneğin terminalden `swift run`) katman kendini kapatır ve bunu raporlar.
- Coalition taraması yalnızca aynı kullanıcıya ait süreçlere sinyal gönderir. Mevcut PID + başlangıç zamanı kontrolü aynen kalır.
- Coalition kimliği ledger'a yazılır; çökme sonrası kurtarma bu kimliği de kullanır.
- Yetenek sınaması başarısız olursa mevcut üç yönteme dönülür. Çıkış raporu garanti kapsamının daraldığını açıkça söyler.

Bu deneyler için `loom-probe`'u saran küçük bir geliştirme `.app` paketi gerekir; `open` ile LaunchServices üzerinden açılır. Mevcut birim testleri terminalden çalıştığı için geri dönüş yolunu sınamaya devam eder.

| # | Senaryo | Beklenen |
| --- | --- | --- |
| A9a | Probe `.app` olarak açılır | Coalition'da yalnızca probe vardır; katman etkin olarak raporlanır. |
| A9b | Aynı probe terminalden çalıştırılır | Paylaşılan coalition algılanır; katman kapanır ve rapor bunu söyler. |
| A9c | A5 kaçışı, ilk gözlemden önce; `.app` ile | Kaçan `/bin/sleep` coalition taramasıyla bulunur; Quit sonrası sıfır süreç. |
| A9d | İlgisiz süreçler | Loom dışındaki hiçbir süreç sinyal almaz; PID + başlangıç zamanıyla aynı kalır. |
| A9e | `.app` probe `kill -9` ile çöker, sonra yeniden açılır | Eski coalition kimliğiyle kalıntı bulunur; sonraki açılışta sıfır süreç. |
| A9f | Yetenek sınaması başarısız sayılır (test için zorlanmış) | Geri dönüş yolu çalışır; rapor garanti kapsamının daraldığını bildirir. |

### 12.2. Terminal ortamı

Yeni `LaunchEnvironment`:

1. Temiz bir başlangıç ortamı kurulur: `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, dil değişkenleri, en küçük `PATH` ve launchd'nin oturuma verdiği değişkenler (örneğin `SSH_AUTH_SOCK`). Loom'un kendi üst sürecinden gelen başka hiçbir şey taşınmaz.
2. Bu ortamla kullanıcının shell'i login ve etkileşimli olarak açılır (`.zprofile` ve `.zshrc` okunur). stdin kapalıdır, zaman aşımı vardır, çıktı ayırıcılarla okunur.
3. Oluşan ortama `TERM` ve Loom işaretleri eklenir.
4. Shell hata verir, takılır ya da soru sorarsa Loom açık hata gösterir. Eksik bir ortamla sessizce devam etmez.
5. Sonuç Loom çalıştığı sürece önbellekte tutulur. Her başlatmada yeniden hesaplanmaz.

| # | Senaryo | Beklenen |
| --- | --- | --- |
| E1 | Fark testi: Loom ortamı ile Terminal.app'te açılan shell ortamı | Farklar yalnızca terminal uygulamasına özgü değişkenler (`TERM_PROGRAM`, `TERM_SESSION_ID`, `SHLVL`, `PWD`, `OLDPWD`, `_`) ve `LOOM_*`'dır. Fark listesi kaydedilir. |
| E2 | Loom bir Claude oturumunun içinden başlatılır | `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` ve `CLAUDE_CODE_MESSAGING_*` çocukta yoktur. Kullanıcının rc dosyasında kendi tanımladığı bir değişken korunur (sentetik `ZDOTDIR` ile). |
| E3 | rc dosyası takılır, soru sorar ya da hata verir (sentetik `ZDOTDIR`) | Zaman aşımı içinde açık hata; kısmi ortamla başlatma yok. |
| E4 | Yönetilen süreçten SSH ajanına ve PATH'e erişim | Sentetik çocukta `ssh-add -l` ajana bağlanabilir (anahtar olup olmaması önemli değil); `PATH` terminaldekiyle aynıdır. |

### 12.3. Küçük düzeltmeler

- **K1:** `recover-stale`, kurtardığı run'a `completed` değil `recovered` yazar. Normal biten run ile kurtarılan run ayrışır.
- **K2:** Probe kökü değiştirilebilir olur (örneğin ortam değişkeniyle). Testler geçici bir kök kullanır. Kurtarılamayan eski bir run diğer komutları durdurmaz; raporlanır.
- **K3:** Başka kullanıcı kimliğiyle çalışan torunlar (örneğin `sudo`) sinyal gönderilmeden raporda "sahiplik dışı kalan" olarak listelenir; `succeeded` bunları gizlemez.

### 12.4. CP2'ye aktarılanlar

- **Kapanış süresi:** Claude (C3, D1) ve remote Codex TUI (B7), 0,4 saniyelik `SIGHUP` süresinde kapanmadı ve `SIGTERM` gerekti. CP2'de sağlayıcıların kendiliğinden kapanma süresi ölçülür; Quit sonrası aynı sohbetten devam ve son turun kayıtta olduğu doğrulanır.
- **Codex kimlik eşleştirmesi:** Aynı sunucuda aynı anda açılan TUI'lerde `thread/started` olayının hangi PTY oturumuna ait olduğu belirlenmeli: ya başlatmalar sıraya alınır ya da ayırt edici bir alan kullanılır.
- **Codex yol seçimi:** Kaynak örnekleminden çıkarım: yol (a) ≈ yol (b) + yaklaşık 110 MiB sabit sunucu maliyeti; remote TUI oturum başına yol (b) kadar bellek kullanıyor. Gözlemlenebilirlik bu maliyetle birlikte değerlendirilir.
- **Örnekleme maliyeti:** Her `sample()` çağrısı, kullanıcının bütün süreçlerinde ortam işaretini okuyor. Kaba ölçüm: 434 süreçte tam tarama birkaç milisaniye. Uygulamada yalnızca yeni ve sınıflandırılmamış süreçler taranır; tam tarama çıkış ve kurtarmaya bırakılır. Coalition katmanı etkinse periyodik tarama ihtiyacı yeniden değerlendirilir.
- **PTY kuralı:** Yaşayan her oturumun PTY çıktısı, oturum gizli olsa da, süreç reap edilene kadar sürekli okunur. Okunmayan PTY dolunca CLI'ın yazması bloklanır.
- **Coalition sınırı (§13 review'ı):** Coalition bütün uygulamayı kapsar, tek oturumu değil. Tek bir oturumu idle'a alırken o oturumdan kaçmış işaretsiz bir süreç coalition ile o oturuma bağlanamaz; tam çıkışta yakalanır. Idle geçişinin garanti kapsamı buna göre yazılmalı.
- **Renk bildirimi (CP5):** Terminal.app `COLORTERM` bildiriyor, Loom bildirmiyor. Claude ve Codex Loom'da daha az renkle çizebilir. Terminal motoru seçildiğinde, motor destekliyorsa ayarlanmalı.

### 12.5. CP1 kabul koşulu

- A9a–A9f doğrulandı. Coalition bu makinede çalışmıyorsa A9f'nin geri dönüş raporu ve garanti kapsamının açık daraltılması kabul yerine geçer.
- E1–E4 doğrulandı.
- K1–K3 tamamlandı.
- Mevcut 11 test ve yeni testler geçiyor.
- Sonuçlar bu dosyada doğrulandı / başarısız / doğrulanmadı olarak kayıtlı.

## 13. Review kapanışının uygulanması ve doğrulama

**Tarih:** 27 Eylül 2026. **Kabul:** §12.5 koşulları bu makinede sağlandı; CP1 tamamlandı.

### 13.1. Sahiplik ve kurtarma

Coalition bilgisi, Apple XNU’nun yayımlanan özel ABI tanımına göre okunuyor; yanıt boyutu, ayrılmış alanlar ve sıfır olmayan kimlik çalışma anında sınanıyor. Açılışta başka bir coalition üyesi veya kimliği doğrulanamayan canlı süreç varsa katman etkinleşmiyor. Ledger, coalition kimliğiyle birlikte `kern.bootsessionuuid` saklıyor; farklı/eksik boot kimliğinde eski coalition kullanılamıyor. Sonraki tarama belirsizliği de başarı olarak gizlenmiyor.

Metadata sorgusundan sonra PID + başlangıç zamanı yeniden doğrulanıyor. Bu, sorgu sırasında PID’si yeniden kullanılan bir sürecin ilgisiz çocuklarını sahiplenmeyi önlüyor. Sinyal anındaki kimlik kontrolüne UID kontrolü de eklendi. Farklı UID’li gözlenen torunlar `outsideOwnership` alanına giriyor ve `succeeded` sonucunu başarısız yapıyor.

| İş | Durum | Kanıt |
| --- | --- | --- |
| A9a | Doğrulandı | LaunchServices `.app` başlatması özel coalition ile etkin; 0 kalıntı. |
| A9b | Doğrulandı | Terminal/host coalition’ı paylaşıldığı için katman kapalı; `Narrowed ownership` ve kaçabilecek süreç sınırı açık raporlanıyor. |
| A9c | Doğrulandı | İlk torun gözleminden önce çift fork + `setsid` ile kaçmış, PPID 1 olan ve okunabilir run işareti bulunmayan `/bin/sleep` coalition ile bulundu; 0 kalıntı. |
| A9d | Doğrulandı | Ayrı `/bin/sleep` kontrolünün PID + başlangıç zamanı tüm deneyler boyunca aynı; hiçbir sinyal raporunda yok. Deney sonunda yalnızca kendi fixture’ı kapatıldı. |
| A9e | Doğrulandı | Probe SIGKILL sonrası yeniden `.app` başlatması eski coalition’dan kaçmış Apple sürecini bulup kapattı; 0 kalıntı ve `recovered` kaydı. |
| A9f | Doğrulandı | Zorlanmış yetenek hatasında üç eski yöntem çalıştı; daralmış garanti açık raporlandı. |
| K1 | Doğrulandı | Kurtarmada `recovered`, normal kapanışta `completed`; kurtarılan kayıt tekrar denenmiyor. |
| K2 | Doğrulandı | `LOOM_PROBE_ROOT` ile geçici kök; bozuk eski kayıt `recovery-error.txt` ve stderr’de raporlanıp yeni komutu engellemiyor. Testler kalıcı kullanıcı deney kökünü kullanmıyor. |
| K3 | Doğrulandı | Sentetik farklı UID torunu sinyal seçiminde yok, raporda var; başarı koşulu onu gizlemiyor. C seviyesinde yabancı UID için sinyal 0 denemesi reddedildi. Gerçek `sudo` oturumu açılmadı. |

Kalıcı, değerlerden arındırılmış özet: [coalition-review-results.json](experiments/coalition-review-results.json). Tam yerel kanıt `~/Library/Application Support/Loom-Dev/probe/evidence/coalition/20260927-221800-36c6d3ce/` altında; taşıma bütünlüğü SHA-256 manifestiyle doğrulandı (§15). Bağımsız son süreç taramasında 12 deney kimliğinin hiçbirisi kalmadı. İlk A9b tekrarlarında probe son taramadan sonra PTY çıktısını okumadan süre penceresinden çıkıyordu; son okuma eklendi ve sabitlenmiş aynı app/CLI binary’siyle matrisin tamamı geçti.

Tekrar: `plans/experiments/build-probe-app.sh`, ardından `python3 plans/experiments/verify-coalition.py`.

### 13.2. Terminal ortamı

Bu bölüm ilk kabulün tarihsel kaydıdır; doğal shell başlangıcı ve önbellek davranışı §14–§15 ile güncellendi. Son düzeltmeler §16’da.

Başlangıç, dar izin listesinden ve `launchctl` kullanıcı oturumu değişkenlerinden kuruluyor; kullanıcının shell dosyalarındaki export’lar daha sonra bütünüyle korunuyor. NUL ile ayrılan ortam rastgele çerçeve işaretleri içinde okunuyor. stdin EOF, süre ve çıktı sınırı, hata bildirimi ve başarısız başlangıcın süreç grubu temizliği var. Başarı veya hata uygulama ömrü boyunca önbellekte tutuluyor.

Zsh otomatik başlangıç sırasında `-e` ve hata trap’lerini bastırabildiği için kullanıcı başlangıç dosyaları doğal sırayla kontrollü olarak source ediliyor. Hata veren komut ile dosya sonundaki meşru false koşulu ayrı ele alınıyor. Bu checkpoint’te destek **macOS `/bin/zsh`** ile sınırlı; bash/Homebrew zsh sessiz geri dönüş yerine açık hata verir. Bilerek hatayı yutan veya trap’i değiştiren rc kodunu güvenilir biçimde teşhis etme iddiası yok; otomatik okunan sistem `/etc/zshenv` trap kapsamı dışında.

Gerçek Terminal fark testi, üst Codex sürecinin `C.UTF-8` değerlerini taşıyan `LANG`/`LC_*` sızıntısını yakaladı. Artık dil ortamı üst süreçten alınmıyor: macOS locale’i için kurulu UTF-8 karşılığı seçiliyor; tam karşılık yoksa OS’nin doğal dizin sırasındaki aynı dile ait ilk kurulu locale kökü kullanılıyor. Bu makinedeki `en_TR` için `en_NZ.UTF-8`, Terminal örneğiyle eşleşti. Bu, Loom’un ölçümle doğrulanan seçim politikasıdır; Terminal’in belgelenmiş iç algoritması olduğu iddia edilmiyor. Launchd’nin açık locale değerleri ve rc export’ları hâlâ öncelikli.

| İş | Durum | Kanıt |
| --- | --- | --- |
| E1 | Doğrulandı | Kullanıcının sağladığı gerçek Terminal.app örneğinde PATH, locale ve kullanıcı export’ları aynı. Kalan 10 fark yalnızca Loom işaretleri, Terminal kimliği/renk bildirimi ve uygulama başlatıcısının XPC/log metadata’sı; her farkın gerekçesi JSON raporunda. |
| E2 | Doğrulandı | Gerçek Claude `SessionStart` hook’unda üst süreçte `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` ve `CLAUDE_CODE_MESSAGING_*` vardı; yeni çocukta hiçbiri yoktu, sentetik `.zshrc` export’u korundu. Run `D2E83B3E-E185-4A63-A40C-42B51149337A`, 0 kalıntı. Ek birim testi eski `CODEX_HOME`/ilgisiz token sızıntısını, `.zprofile` ve çok satırlı değerleri kapsıyor. |
| E3 | Doğrulandı | `.zshrc` içinde hata, yanıtsız `read`, `return 1` ve takılan alt süreç açık hata veriyor; kısmi ortam dönmüyor. Zaman aşımı alt süreci de kapatıyor. Son false koşulu geçerli ortamı bozmuyor. |
| E4 | Doğrulandı | Gerçek çözülen ortamla çocuk `ssh-add -l` çıkış 1: ajan erişilebilir, anahtar yok. PATH, Terminal.app örneğiyle birebir aynı. |

E2, [Claude’un belgelenmiş `--init-only` davranışı](https://code.claude.com/docs/en/hooks#setup) ile yeni model turu açmadan çalıştırıldı. Oturuma özel hook yalnızca [EnvironmentParentProbe.swift](experiments/EnvironmentParentProbe.swift) harness’ini çağırdı; kullanıcı ayar dosyaları değiştirilmedi. Harness aynı `LaunchEnvironment.swift` kaynağıyla derlenip gerçek üst ortamı ve sentetik `ZDOTDIR` kullanır. Bu ilk E2 çalışması tarihsel kayıttır. Aynı deneyin kalıcı konumda tekrarlanan kanıtı: [Claude hook raporu](</Users/gencberke/Library/Application Support/Loom-Dev/probe/evidence/environment-addendum/20260927-223727/claude-hook-report.json>) (run `AA0A1364-53DF-4DCA-BF62-49A4AEE0BBAD`, §15). Raporda yalnızca değişken adları ve kontroller bulunur.

Kalıcı, değerlerden arındırılmış özet [environment-review-results.json](experiments/environment-review-results.json), fark listesi [terminal-environment-diff.json](experiments/terminal-environment-diff.json). Tam ortam değerlerini içeren geçici karşılaştırma dosyaları doğrulama sonrası kaldırıldı; raporlarda yalnızca değişken adları, fark gerekçeleri ve kontroller var. E1’i tekrarlamak için repo kökünde:

```sh
.build/debug/loom-probe environment .build/environment-evidence
# Gerçek Terminal.app penceresinde, repo kökünde:
(umask 077; /usr/bin/env -0 > .build/environment-evidence/terminal-environment.nul)
python3 plans/experiments/compare-terminal-environment.py .build/environment-evidence --output plans/experiments/terminal-environment-diff.json
```

### 13.3. Kontroller ve kapanış

- `swift build` ve **27 Swift Testing testi** geçti: önceki 11 test + 16 yeni test. PID yeniden kullanımı, başka boot’tan ledger, sonradan coalition sorgu hatası, yabancı UID, bozuk kurtarma kaydı, rc hataları, locale sızıntısı ve ortam önbelleği kapsanıyor.
- Command Line Tools’ta daha önce de görülen `TestingMacros` plugin keşfi hatası iki ara çalıştırmada tekrarlandı; son normal build/test çalıştırması geçti. Paket dosyasına makineye özel derleyici yolu eklenmedi.
- C shim strict clang derlemesi ve yardımcı çalışma anı deneyleri geçti; `git diff --check` temiz.
- Locale düzeltmesinden sonraki aynı binary’lerle A9 matrisi ve gerçek Claude E2 deneyi yeniden geçti. E1/E4 PATH ve ajan kontrolleri de tamamlandı; §12.5’te açık kabul maddesi kalmadı.
- §12.4’teki CP2 işleri bir sonraki checkpoint’te ele alınacak.

## 14. Ortam eki: Terminal gibi davran

**Tarih:** 27 Eylül 2026, §13'ün review'ından sonra. **Durum:** Uygulandı ve doğrulandı; sonuçlar §15’te.

### 14.1. Neden

§13'teki çözümleme, shell başlangıcında görülen her hatayı ya da stderr satırını "ortam yok" sayıyor. Başarısızlık da uygulama ömrü boyunca önbellekte kalıyor. Review'da Loom'un zsh çağrısının birebir kopyası sentetik bir `ZDOTDIR` ile denendi:

| `.zshrc` içeriği | Loom yöntemi | Düz `zsh -l -i -c` (Terminal'e yakın) |
| --- | --- | --- |
| `export FOO=1` | Ortam döner | Ortam döner |
| `stty -ixon` + export | Çıkış 1, "Shell startup error"; oturum açılmaz | Ortam döner |
| stderr'e tek satır uyarı + export | Shell başarılı ama `stderr.isEmpty` kontrolü yüzünden reddedilir | Ortam döner |

`stty` Terminal'de çalışır; Loom'da ise çözümleme sırasında stdin bir terminal olmadığı için hata verir.

Ayrıca launchd oturum değişkenleri `launchctl print` çıktısı ayrıştırılarak okunuyor. `man launchctl`: "This output is NOT API in any sense at all. Do NOT rely on the structure or information emitted for ANY reason." Biçim değişirse ya da dil ayarına uyan kurulu bir locale bulunamazsa da bütün oturum başlatmaları duruyor.

Bu katılığın kaynağı §12.2'deki "hata verir … açık hata gösterir" ifadesiydi. Kastedilen, ortamın hiç alınamadığı durumdu.

Kullanıcı kararı ([sözleşme](../LOOM-PRODUCT-CONTRACT.md) §3): **Terminal gibi davranılır.** Hatalar ve uyarılar oturumu durdurmaz, görünür uyarı olur. Hata yalnızca ortam hiç alınamazsa verilir.

### 14.2. Beklenen davranış

1. **Doğal başlangıç:** Kullanıcının shell'i kendi doğal login + etkileşimli başlangıcıyla çalışır. rc dosyaları elle source edilmez, hata tuzağı kurulmaz. stdin `/dev/null`, 30 saniye zaman aşımı, çıktı sınırı, çerçeveli `env -0` okuma ve başarısız başlangıcın süreç grubu temizliği aynen kalır.
2. **Başarı ölçütü:** Çerçeveli ortam eksiksiz okunur ve `PATH` boş değildir. rc içindeki başarısız komutlar ve stderr çıktısı başarısızlık sayılmaz. stderr (boyut sınırlı) ve varsa durum bilgisi **uyarı** olarak sonuçla birlikte döner; arayüz bunları gösterebilir.
3. **Hata yalnızca şu durumlarda verilir:** zaman aşımı, çerçevesiz ya da eksik çıktı (örneğin rc içinde `exit`), çıktı sınırı aşımı, boş `PATH`, shell'in başlatılamaması.
4. **launchd değişkenleri:** `launchctl print` ayrıştırması kaldırılır.
   - Loom LaunchServices kimliğiyle açıldıysa ve bilinen terminal/ajan oturumu işaretleri yoksa, kendi süreç ortamı launchd oturum ortamı olarak kullanılır. Gerçek deneyde `open` çağrısının ajan ortamını taşıyabildiği görüldü; yalnızca `.app` kimliği temiz ortam kanıtı sayılmaz. Bu ortam, uygulama başlatıcısına ait anahtarlar (`__CFBundleIdentifier`, `XPC_SERVICE_NAME`, `XPC_FLAGS` vb.) çıkarılarak kullanılır.
   - Loom bir terminal ya da ajan içinden açıldıysa (geliştirme), üst ortam kirli olabilir. Bu durumda yalnızca bilinen oturum değişkenleri (örneğin `SSH_AUTH_SOCK`) `launchctl getenv <ad>` ile tek tek alınır.
   - Eksik `LANG`, `LC_ALL`, `LC_CTYPE` normaldir ve uyarı üretmez. Eksik `SSH_AUTH_SOCK` veya sorgulama hatası uyarıdır; oturum açılmasını engellemez.
5. **Locale:** Dil ayarına uyan kurulu bir UTF-8 locale yoksa, kuruluysa `en_US.UTF-8` kullanılır ve uyarı verilir. O da yoksa `LANG` ayarlanmaz ve uyarı verilir. Hiçbir durumda oturum başlatmayı durdurmaz. launchd ve rc değerleri önceliğini korur.
6. **Önbellek:** Başarılı sonuç uyarılarıyla birlikte önbellekte tutulur. Başarısızlık önbelleğe kalıcı yazılmaz; açık bir "yeniden dene" ile uygulama yeniden başlatılmadan tekrar çözümlenir.
7. **Kapsam:** Kapsam macOS `/bin/zsh` olarak kalır. Diğer shell'ler açık hata vermeye devam eder; bu bilinen bir sınırdır.

### 14.3. Kabul senaryoları (sentetik `ZDOTDIR`, gerçek rc dosyalarına dokunulmaz)

| # | Senaryo | Beklenen |
| --- | --- | --- |
| F1 | `.zshrc`: `stty -ixon`, `false`, stderr'e uyarı, ardından `export FOO=1` | Ortam döner, `FOO` var; gözlenebilir stderr/durum bilgisi uyarı listesinde. Kullanıcı açıklaması: başarılı `export` öncesindeki sessiz `false` doğal shell tarafından raporlanmıyorsa uyarı uydurulmaz. |
| F2 | `.zshrc`: `exit 1`; ayrı senaryoda sonsuz bekleme | Açık hata; kısmi ortam yok; başlatılan alt süreçler temizlenir. |
| F3 | `.zshrc`: `read` (stdin EOF) ve ardından export | Takılmaz; ortam döner. |
| F4 | `launchctl print` kullanılmıyor. `.app` olarak açılan probe'da `SSH_AUTH_SOCK` çocukta var, başlatıcı anahtarları yok. Terminalden açılan probe'da üst oturum değişkenleri yine taşınmıyor (E2 tekrarı). | Hepsi doğrulanır. |
| F5 | Locale eşleşmesi yok (test enjeksiyonu) | Fallback ve uyarı; hata yok. |
| F6 | Başarısız çözümleme → rc düzeltilir → "yeniden dene" | Ortam alınır; uygulama yeniden başlatılmaz. |
| F7 | E1 fark testi tekrarı | Farklar §13.2'dekiyle aynı; `PATH` eşit. |

Mevcut `startupErrorsNeverReturnPartialEnvironment` testi yeni davranışa göre ayrılır: hata ve uyarılar ortam döndürür, `exit` ve zaman aşımı hata verir.

### 14.4. Küçük işler

- A9'un tam kanıtı `.build/review-evidence/` altında; derleme temizliğinde silinir. Tam kanıt probe köküne taşınır ve bu dosyadaki bağlantılar güncellenir.

### 14.5. CP1 kapanış koşulu

F1–F7 doğrulandı; bütün testler geçiyor; sonuçlar bu dosyada doğrulandı / başarısız / doğrulanmadı olarak kayıtlı.


## 15. Ortam eki doğrulaması

**Tarih:** 27 Eylül 2026. **Sonuç:** F1–F7 doğrulandı; CP1 yeniden kapandı.

Doğal `/bin/zsh +m -l -i -c` başlangıcı korunuyor. Eksiksiz çerçeve ve boş olmayan `PATH` başarı sayılıyor; stderr ve gözlenen durum bilgisi sınırlı uyarılarla dönüyor. Kullanıcının onayıyla, başarılı export öncesindeki sessiz `false` için uyarı üretilmiyor. Başarılı sonuç ve uyarılar önbelleğe alınıyor; başarısız çözümleme yeniden denenebiliyor. Başarısız shell başlangıcında süreç grubu temizlenene kadar `waitid(WNOWAIT)` PID'yi rezerve tutuyor; PID yeniden kullanımından kaynaklanan yanlış grup sinyali önleniyor.

| Kabul | Sonuç ve kanıt |
| --- | --- |
| F1 | **Doğrulandı.** `stty`, stderr ve başarısız komut sonrası export ortamı döndürüyor; uyarılar sınırlı. Çerçeveden sonraki `.zlogout` hatası da geçerli ortamı iptal etmiyor. |
| F2 | **Doğrulandı.** rc `exit`, sonsuz bekleme, boş PATH ve aşırı çıktı hata veriyor; exit/timeout alt süreçleri temizleniyor. |
| F3 | **Doğrulandı.** stdin EOF alan `read` sonrası export döndü. |
| F4 | **Doğrulandı.** `launchctl print` kaldırıldı. Temiz LaunchServices, ajan ortamını devralan `.app` ve doğrudan geliştirme başlangıcı ayrı ayrı sınandı: SSH soketi çocukta, başlatıcı anahtarları yok. Gerçek Claude `--init-only` SessionStart deneyinde üç üst oturum kategorisi mevcutken çocukta Claude anahtarı kalmadı; rc özel değişkeni korundu. Run `AA0A1364-53DF-4DCA-BF62-49A4AEE0BBAD` temiz kapandı. |
| F5 | **Doğrulandı.** Eşleşme yoksa kurulu `en_US.UTF-8` ve uyarı; o da yoksa bootstrap LANG ayarlamıyor ve uyarı veriyor. Bu makinenin `/etc/zprofile` dosyası sonradan `C.UTF-8` ayarlayabildiğinden test başlangıçtaki unset durumunu `.zshenv` üzerinden ölçüyor. |
| F6 | **Doğrulandı.** Aynı süreçte başarısız rc düzeltildi, tekrar çözümleme başarılı oldu; başarılı uyarılar önbellekte korundu. |
| F7 | **Doğrulandı.** Kullanıcının yeni Terminal.app örneğiyle üç başlangıç türünde PATH eşit, beklenmeyen fark yok. Geliştirme yolundaki fark kümesi §13.2 ile aynı 10 anahtar. |

`LaunchEnvironment.origin` uygulama kimliği, parent PID ve bilinen terminal/ajan işaretlerini birlikte değerlendiriyor. Kirli geliştirme başlangıcı dar bootstrap ve bilinen `launchctl getenv` sorgularını kullanıyor. Bu makinede LANG/LC_ALL/LC_CTYPE launchd değerleri bulunmadığı için üç görünür uyarı var; temiz LaunchServices deneyinde uyarı yok. `COMMAND_MODE` ve `__CF_USER_TEXT_ENCODING` de başlatıcı metadatası olarak çıkarılıyor. Sistem `/bin/zsh` dışındaki shell'ler kapsam dışında kalıyor.

**Kontroller:** `plans/experiments/build-probe-app.sh` başarılı; `swift test` 4 suite / **33 test geçti**. Son app ve CLI binary’leriyle `verify-coalition.py` A9a–A9f geçti. Bağımsız son taramada 12 sahip olunan süreç kimliğinden hiçbiri kalmadı; dış kontrol süreci sinyal raporlarına girmedi. Terminalden başlatmanın dar süreç sahipliği garantisi değişmedi.

**Kanıtlar:** [ortam eki sonuçları](experiments/environment-addendum-results.json), [Terminal farkı](experiments/environment-addendum-terminal-diff.json), [temiz uygulama farkı](experiments/environment-addendum-clean-app-diff.json), [ajan içinden açılan uygulama farkı](experiments/environment-addendum-app-diff.json). Tam yerel ortam eki kanıtı `~/Library/Application Support/Loom-Dev/probe/evidence/environment-addendum/20260927-223727/`; son A9 kanıtı `~/Library/Application Support/Loom-Dev/probe/evidence/coalition/20260927-224229-693fdf3f/` altında.

Önceki altı A9 çalışmasının **301 dosyası / 440478 baytı** kalıcı probe köküne kopyalandı; her dosyanın SHA-256 ve boyutu kaynakla eşleşti. `evidence/coalition/migration-sha256-manifest.json` eski gömülü yolların karşılıklarını kaydediyor. Yeni harness çalışmaları doğrudan kalıcı köke yazıyor. Karşılaştırma sonrası geçici tam Terminal ve Loom ortam dışa aktarımları silindi; raporlarda değerler yerine yalnızca anahtar adları ve karşılaştırma sonuçları tutuldu.


## 16. Review takibi

Kullanıcının dört maddelik takibinde süre, uyarı ve bağlantı düzeltmeleri tamamlandı. Arka plan süreçleri için küçük sahiplik düzeltmesi uygulandı; hızlı ayrışan daemonların tam izolasyonu kullanıcı kararıyla [ayrı plana](DEVELOPMENT-STARTUP-ISOLATION.md) alındı.

- Ortam çözümlemesinin varsayılan sınırı **30 saniye**. 5,2 saniye süren sentetik rc artık başarıyla ortam döndürüyor; enjekte edilen kısa süreli timeout testi de temizliği doğrulamaya devam ediyor.
- Eksik `LANG`, `LC_ALL`, `LC_CTYPE` sessiz. Eksik SSH ajanı ve gerçek sorgulama hataları uyarı olarak korunuyor. Geliştirme yolundaki gerçek ortam deneyinde uyarı sayısı **0**, SSH ajanı erişilebilir ve önbellek sonucu aynı.
- Çözücü shell, rc çalışmadan önce run işareti alıyor ve sahiplik kaydına giriyor. Shell PID’si `WNOWAIT` ile rezerveyken süreç grubu üyeleri kimlikleriyle kaydediliyor; mevcut torun/işaret takibi de sürüyor. Başarılı ortam hemen yardımcıları öldürmüyor; çıkışta mevcut coordinator temizliyor. Önbellek run kimliğine bağlı ve shutdown sırasında kaldırılıyor. Provider deneyinde kurtarma sahibi rc öncesinde kalıcı kaydediliyor.
- Coalition olmadan, `.zshrc` içinden disown edilen `/bin/sleep` için regresyon testi eklendi: çözümlemeden sonra hayatta ve sahiplik kaydında; shutdown sonrasında kimliği yok. Bu test grup kaydı olmadan başarısız oldu, düzeltmeyle geçti.
- Gerçek `/usr/bin/ssh-agent` deneyi daha dar sınırı doğruladı: çok hızlı daemonlaşan ve işareti okunamayan süreç gözlemden kaçabiliyor. Bu durumda tam temizlik sağlanmış sayılmıyor. Testin kendi başlattığı ajan kimlik doğrulamalı test temizliğiyle kapatıldı. Ayrı izolasyon planı bu senaryoyu, dış kontrol ajanını ve çökme sonrası kurtarmayı kabul koşulu yapıyor.
- §13.2 tarihsel kayıt olarak işaretlendi; eski `.build` kanıt yolu kalıcı konumdaki gerçek Claude tekrarının bağlantısıyla değiştirildi.

**Kontroller:** 4 suite / **36 test geçti**. Standart `swift test` bu makinede `TestingMacros` keşif hatasına takıldı; native derleme sistemi de `Testing` modülünü bulamadı. Kurulu plugin yolu yalnızca komuta verilerek aynı testler çalıştırıldı: `swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`. Paket yapılandırmasına makineye özel yol eklenmedi. Uygulama derlemesi ve A9a–A9f matrisi başarılı; ayrıntılar [review takip kanıtında](experiments/review-followup-results.json).
