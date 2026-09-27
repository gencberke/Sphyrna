# Checkpoint 1 — Süreç sahipliği ve temiz çıkış

**Tarih:** 27 Eylül 2026  
**Durum:** Plan onay bekliyor; uygulanmadı.  
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
  - `LaunchEnvironment`: Yönetilen sürecin ortamını izin listesiyle kurar ve PATH'i login shell'den çözer. `CLAUDECODE`, `CLAUDE_CODE_*`, `CODEX_*` gibi üst oturum değişkenlerini taşımaz. `LOOM_RUN_ID` ve `LOOM_SESSION_ID` işaretlerini ekler.
  - `PTYProcess`: Süreci kendi Unix session'ında, controlling terminal'i PTY olacak şekilde başlatır; master fd, pencere boyutu ve çıkış izleme.
  - `ProcessTable`: `sysctl(KERN_PROC_ALL)` ile süreç listesi; PID ve başlangıç zamanı, ppid, pgid, sid; `KERN_PROCARGS2` ile argüman ve ortam işareti okuma.
  - `OwnershipLedger`: Loom'un sahip olduğu session'lar ve görülen torunlar (PID + başlangıç zamanı).
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

Henüz yok.
