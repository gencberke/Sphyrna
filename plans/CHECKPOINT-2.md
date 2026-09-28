# Checkpoint 2 — Durum ve devam

**Tarih:** 27 Eylül 2026  
**Durum:** Tamamlandı. Kalıcı oturum/run kataloğu, Claude hook durumu, Codex app-server + remote TUI durumu, güvenli idle/stale geçişleri ve aynı sağlayıcı sohbetinden resume uygulandı; §9 matrisi ve gerçek sağlayıcı zincirleri doğrulandı. Bu checkpoint'ten sonra ilk pencere gelir (sözleşme §3, checkpoint sırası).

**Dayanak:** [Ürün sözleşmesi](../LOOM-PRODUCT-CONTRACT.md) §4, §9 ve §11'deki 2. checkpoint; [CP1](CHECKPOINT-1.md) §12.4 ve kod review'ı.

## 1. Amaç

Loom, yönettiği her oturumu kalıcı olarak bilir ve oturumun ne yaptığını belirli bir kaynaktan gösterir. Boşta kalan oturumu güvenle kapatır (idle) ve aynı sohbetten devam ettirir. Uygulama kapanıp açıldığında sohbetler kaybolmaz.

Arayüz bu checkpoint'te yok; çekirdek, `loom-probe` ve testlerle çalışılır.

**Kapsam dışı:** terminal motoru ve pencere (sonraki parça), silme ve otomatik temizlik, oturumlar arası görev devri, side chat.

## 2. Önce: çekirdeğin yapısal hazırlığı

CP1 kodu dikkatli yazılmış ve iyi test edilmiş, doğruluk hatası yok. Ancak uzun süre açık kalacak ve birden çok oturum yönetecek bir uygulama için üç yapısal eksik var. CP2'nin geri kalanı bunlara dayandığı için ilk iş bunlardır.

| # | Sorun (CP1 kodu) | Beklenen |
| --- | --- | --- |
| S1 | Oturum kavramı yok: `ShutdownCoordinator` düz bir `PTYProcess` listesi tutuyor; yalnızca bütün süreçler kapatılabiliyor. Ledger oturum bazında değil. | `ManagedSession`: Loom oturum kimliği ↔ sağlayıcı sohbet kimliği ↔ o anki çalıştırma (PTY, lider kimliği, torunlar). Tek oturumu durdurma ve yokluğunu doğrulama API'si. Tam çıkış, bütün oturumların üzerinde aynı sözleşmeyi uygular. |
| S2 | Her şey `@MainActor` üzerinde ve senkron: ortam çözümlemesi 30 sn'ye, kapanış yaklaşık 1 sn'ye kadar ana iş parçacığını bekletiyor. PTY çıktısı ve süreç çıkışı yoklamayla izleniyor (probe'da 5 ms'lik döngü). | Süreç ve IO işleri ayrı bir actor'da, async API ile. PTY okuma ve süreç çıkışı olay tabanlı (`DispatchSource` read / process exit). Hiçbir yaşam döngüsü işlemi ana iş parçacığını bloklamaz. |
| S3 | Her `sample()` sistemdeki bütün süreçleri tarıyor: her süreç için 1 MiB'lık `KERN_PROCARGS2` ve coalition okuması yapıyor, ledger JSON'unu her seferinde yeniden yazıyor. `descendants` ve `sessionLeaders` hiç küçülmüyor. Ortam çözümlemesi sırasında bu tarama 20 ms'de bir yapılıyor. | Ölen kimlikler ayıklanır. Ledger yalnızca değişince yazılır. İşaret okuması yalnızca yeni PID'lerde yapılır; tam tarama çıkış ve kurtarmaya bırakılır. Periyodik örnekleme olaylara bağlanır ve düşük frekansla sınırlanır; frekans ölçülerek seçilir. |
| S4 | Adlandırma ve hata tipleri: `ShutdownCoordinator` artık launch, örnekleme, ortam ve kapanışı birlikte yapıyor. Hatalar çoğunlukla `LoomError.message(String)`. | Sorumluluğu anlatan bir ad (örneğin `ProcessSupervisor`). Arayüzün ayırt etmesi gereken durumlar için tipli hatalar: ortam zaman aşımı, desteklenmeyen shell, sağlayıcı geçmişi yok vb. |

Kabul:

- CP1 testleri ve A9a–A9f matrisi aynen geçer.
- Tek oturum durdurma, diğer oturumlara dokunmadan sıfır kalıntıyla doğrulanır.
- 10 boşta oturumda Loom'un kendi CPU kullanımı ve uyanma sayısı ölçülüp kaydedilir.
- Sentetik uzun çalışma (binlerce kısa ömürlü torun) sonrasında ledger boyutu yaşayan süreç sayısıyla sınırlı kalır.
- Ortam çözümlemesi ve kapanış sırasında ana iş parçacığı bloklanmaz.

## 3. Codex yolu (G1, karar verildi)

**Kullanıcı kararı:** Yol (a), yani Loom'a ait app-server + remote TUI. CP1 örnekleminde yol (b)'ye göre yaklaşık 110 MiB ek sabit bellek maliyeti var; oturum durumunun doğrudan görülmesi karşılığında kabul edildi (sözleşme §3).

Yol (a)'da durum akışı (`thread/status/changed`, onay ve girdi bekleme), arka plan terminalleri listesi ve onay çözülmesi doğrudan görülür. Bu checkpoint'te çözülecekler:

- **Eşleşme:** Aynı sunucuda aynı anda açılan TUI'lerde `thread/started` ↔ PTY eşleşmesi sağlanmalı. Ya başlatmalar sıraya alınır ya da ayırt edici bir alan bulunur.
- **İstemci:** Probe'daki senkron ve tipsiz RPC istemcisi ürün kodu değildir. Core'da tipli, async bir app-server istemcisi yazılır; bilinmeyen alan ve olaylara toleranslıdır.
- **Sunucu yaşam döngüsü:** Sunucu ilk Codex oturumunda başlar. Aktif Codex oturumu kalmayınca kapanır; tam çıkışta sahiplik sözleşmesine tabidir.
- **Koşul:** Yol (a) beklenen görünürlüğü sağlamazsa (T1–T3, I1) bu rapor edilir ve karar yeniden değerlendirilir. Yol (b) adayları (`notify`, OSC 9 bildirimleri) ancak o durumda incelenir.

## 4. Kimlik ve anlık durum

**Claude:** Kimlik başlangıçta `--session-id` ile atanır. Durum, `--settings` ile yalnızca o oturuma verilen hook'lardan gelir. Kullanıcının ayar dosyalarına yazılmaz.

| Olay | Kullanım |
| --- | --- |
| `SessionStart` (`source`: startup / resume / clear / compact / fork) | Sohbet kimliği ve kimlik değişimi |
| `UserPromptSubmit` | Çalışıyor; son kullanım zamanı |
| `Stop` | Tur bitti; `last_assistant_message` |
| `StopFailure` | Hata (API hatası türüyle) |
| `Notification` (`permission_prompt`, `idle_prompt`) / `PermissionRequest` | Onay veya girdi bekleniyor |
| `SessionEnd` | Oturum bitti (neden ile) |

- **Hook taşıma yolu (seçildi):** async `command` hook + küçük `loom-hook` yardımcısı → Loom'un Unix soketi. [Güncel Claude hook sözleşmesinde](https://code.claude.com/docs/en/hooks) kimliğin başlangıç kaynağı olan `SessionStart`, HTTP hook desteklemiyor; HTTP adayı aynı olay kümesini taşıyamadığı için elendi. İki farklı taşıma hattı kurulmadı.
  - `SessionStart`, `UserPromptSubmit`, `Stop`, `StopFailure`, `Notification` ve `PermissionRequest` async çalışır. Claude teardown'da async hook'u öldürebildiği için `SessionEnd`, 1 sn sınırla senkrondur.
  - Soket dizini `0700`, soket `0600`; app-run token'ı argümana ya da settings'e değil ortama verilir. Yardımcı yalnızca miras aldığı Loom oturum/run kimliğini ve en fazla 1 MiB hook JSON'unu iletir, stdout üretmez.
  - Gerçek Claude 2.1.280 ölçümünde debug'daki hook başlatma zamanı ile helper'ın gönderme zamanı arası 5,5–8 ms; helper → receiver teslimi 0,37–0,87 ms oldu (`9299D9DC-FDD8-41BA-B515-CBAE3433162B`).
- **Eşleşme:** Hook süreci Claude'un ortamını, dolayısıyla `LOOM_SESSION_ID`'yi taşır; olay ile oturum eşleşmesi kesindir.

**Codex:** Yol (a) olayları; eşleşme ve istemci §3'te.

**Kurallar:**

- Yaşam döngüsü, ajanın anlık durumu, süreç durumu ve ekrandaki seçim ayrı alanlardır (sözleşme §4.2).
- Eski bir çalıştırmadan gelen olay, yeni çalıştırmanın durumunu değiştirmez; olaylar çalıştırma kimliğiyle eşlenir.
- Bilinmeyen bir olaydan "bitti", "onaylandı" ya da "kapandı" sonucu çıkarılmaz; durum "bilinmiyor" olur.

**Yeni sohbet komutları (G2, karar verildi):** Claude `/clear` ya da Codex `/new` sonrası yeni sohbet ayrı bir kayıt olur; eski kayıt korunur (sözleşme §3). Yeni kayıt aynı çalıştırmaya (PTY) bağlıdır; eski kayıt o andan itibaren çalışmayan bir geçmiş sohbet olur.

## 5. Katalog

- SQLite: sistemdeki `libsqlite3`, ek bağımlılık yok. WAL modu ve şema sürümü.
- En az şu tablolar:
  - `sessions`: Loom kimliği, sağlayıcı, sağlayıcı sohbet kimliği, çalışma dizini, başlık, oluşturma ve son kullanım zamanı, yaşam döngüsü, sabitleme.
  - `runs`: çalıştırma kimliği, oturum, lider süreç kimliği, başlangıç, bitiş ve nedeni.
  - Kimlik değişimleri (G2'ye göre).
- Sohbet içeriği saklanmaz.
- Bozuk katalogun üzerine yazılmaz.
- Geliştirme verisi ayrı dizinde tutulur.
- Katalog yazımı ile kapanış yarışmaz: kapanış ve silme sırasında bekleyen yazımlar tamamlanır.

## 6. Yaşam döngüsü ve idle

- **Durumlar:** `active` / `idle` / `stale` (sözleşme §4.1). `last_used_at`, son kullanıcı promptu ya da bilinçli görüntülemedir. Görüntüleme için arayüz gelene kadar test kancası kullanılır.
- **Idle geçişi** (sözleşme §4.3): Varsayılan 1 saat; testte saniyeler. Sessizlik koşulları:
  - tur yok,
  - onay veya girdi beklenmiyor,
  - teslim bekleyen iş yok,
  - "yerleşik yardımcılar" dışında torun yok. Oturum başında başlayan MCP sunucuları gibi süreçler yerleşik sayılır; sonradan başlayan shell ya da komut oturumu meşgul yapar. Bu süreç tabanlı kontrol sağlayıcıdan bağımsızdır.

  Koşul sağlanmazsa geçiş ertelenir ve neden kaydedilir.
- **Kapatma:** Kontrollü kapanış yapılır; torunlar dahil yokluk doğrulanır ve ancak ondan sonra `idle` yazılır.
- **Garanti sınırı:** Coalition tek oturumu ayırt edemez. Oturumdan kaçmış işaretsiz bir süreç idle'da yakalanmayabilir; tam çıkışta yakalanır. Idle garanti metni buna göre yazılır.
- **Codex yol (a):** TUI kapanır. Sunucudaki thread en fazla 30 dk bellekte kalır (kabul edildi). Aktif Codex oturumu kalmayınca sunucu kapanır.
- **Stale:** 15 gün sonra yalnızca sınıflandırılır; temizlik ve silme sonraki parçadadır.

## 7. Devam (resume)

- **Komutlar:** Claude: `--resume <id>`, aynı başlatma profili (agent view kapalı, `--settings`) ve aynı çalışma dizini. Codex: `resume <id>` (yol b) ya da `resume <id> --remote` (yol a).
- **Başarısız devam:** Sessizce yeni sohbet açılmaz (sözleşme §4.3). Sağlayıcı geçmişi yoksa (örneğin Claude'un 30 günlük temizliğinden sonra) durum "sağlayıcı geçmişi bulunamadı" olur.
- **Aynı sohbetin iki kez açılması:** Loom içinde engellenir. Sohbetin Loom dışında açık olduğu tespit edilebiliyorsa (Claude `claude agents --json`, Codex yazıcı kilidi) uyarı verilir; tespit yöntemi doğrulanacak.
- **Çalışma dizini bağımlılığı:** Resume'un çalışma dizinine bağlı olup olmadığı doğrulanacak.

## 8. Quit süresi ve bütünlük

CP1'de Claude ve remote Codex TUI, 0,4 sn'lik `SIGHUP` süresinde kapanmadı ve `SIGTERM` gerekti.

- Her sağlayıcının `SIGHUP` sonrası kendiliğinden kapanma süresi, boşta ve çalışırken ölçülür.
- Sağlayıcı süreçlerine tanınan süre buna göre ayarlanır; toplam Quit süresi kaydedilir.

## 9. Senaryolar ve kabul

| # | Senaryo | Beklenen |
| --- | --- | --- |
| S1–S4 | §2 | §2'deki kabul maddeleri. |
| G1 | Yol (a) görünürlüğü | Durum, onay ve arka plan terminali olayları gerçek TUI yanında doğru geliyor. Eksik varsa rapor edilir ve karar yeniden değerlendirilir. |
| I1 | Claude ve Codex yeni oturumu | Sağlayıcı kimliği katalogda; Loom oturumuyla kesin eşleşme. Codex'te eşzamanlı iki başlatmada da doğru eşleşme. |
| I2 | `/clear` / `/new` | Yeni sohbet ayrı kayıt; eski sohbet kaybolmaz ve aynı sohbetten devam ettirilebilir. |
| T1 | Prompt → çalışıyor → tur bitti | Durum geçişleri doğru kaynaktan; son yanıt alınabiliyor. |
| T2 | Onay isteyen komut | "Onay bekleniyor"; kullanıcı yanıtlayınca çalışıyor ya da bitti. |
| T3 | API hatası / çökme / bilinmeyen olay | Hata ya da "bilinmiyor"; yanlış başarı yok. |
| T4 | Eski çalıştırmadan gecikmiş olay | Yeni çalıştırmanın durumu değişmez. |
| L1 | Boşta oturum, süre doldu | Kontrollü kapanış, yokluk doğrulaması, `idle`; diğer oturumlar etkilenmez. |
| L2 | Arka plan komutu veya bekleyen onay varken süre doldu | Idle ertelenir; neden kaydedilir. |
| L3 | Kapanış sırasında yeni prompt | Prompt kaybolmaz; ikinci süreç başlamaz. |
| L4 | Stale sınıflandırması | 15 gün (test saati) sonra `stale`; görüntüleme durumu değiştirmez (sözleşme §3). |
| R1 | Idle → yeni prompt | Aynı sohbetten devam; kimlik ve çalışma dizini korunur. |
| R2 | Loom kapanıp açılır | Katalog yerinde; seçilen sohbet aynı sohbetten açılır; otomatik süreç başlatılmaz. |
| R3 | Sağlayıcı geçmişi yok | "Sağlayıcı geçmişi bulunamadı"; yeni sohbet açılmaz. |
| Q1 | Aktif tur sırasında Quit → yeniden açılış → resume | Son tamamlanmış tur kayıtta; sohbet açılıyor. Her iki sağlayıcı. |

Her sonuç **doğrulandı / başarısız / doğrulanmadı** olarak, komut ve kanıtla bu dosyaya yazılır. Deneyler izole profillerde yapılır.

## 10. Uygulama sırası

1. S1–S4 ve CP1 regresyonu.
2. Katalog.
3. Claude kimlik ve durum (hook taşıma yolu ölçümüyle).
4. Codex yol (a): tipli async app-server istemcisi, sunucu yaşam döngüsü, eşzamanlı başlatma eşleşmesi, kimlik ve durum.
5. Idle, stale sınıflandırması, resume.
6. Quit süresi ölçümü ve Q1.
7. Sonuç raporu ve sözleşme güncellemesi (§4, §6).

## 11. Kullanıcıdan gerekenler

- G1 ve G2 kararları verildi (sözleşme §3). Yol (a) beklenen görünürlüğü sağlamazsa yeniden karar gerekir.
- **Model turları:** Tahmini 20–30 kısa tur, izole profillerde ve düşük maliyet ayarlarıyla.

## 12. Riskler

- `--settings` ile verilen hook'ların interaktif oturumda çalışması belgelenmiş ama Loom akışında sınanmadı.
- Codex app-server protokolü "experimental" etiketli; alan ve olaylar kurulu sürümün ürettiği şemayla sınanmalı, bilinmeyenlere toleranslı olunmalı.
- Resume'un çalışma dizinine bağımlılığı ve sağlayıcıların kendi saklama politikaları.
- Süreç tabanlı sessizlik kontrolü, yerleşik yardımcıları yanlış sınıflandırabilir. Sınıflandırma kuralı testle sabitlenmeli.

## 13. Uygulama durumu

27 Eylül 2026, S1–S4 yapısal dilimi ve katalog temeli:

- **Doğrulandı:** `ManagedSession` içindeki Loom sohbet kimliği, sağlayıcı sohbet kimliği ve çalışma dizini; bunlardan ayrı `ManagedRun` kimliği eklendi. Uygulama sahiplik `runID`'si ile oturum çalıştırma kimliği ayrıdır.
- **Doğrulandı:** Actor tabanlı `ProcessSupervisor`, iki eşzamanlı sentetik oturumdan birini lideri ve yeniden ebeveynlenmiş torunuyla kapatırken diğerini çalışır bıraktı. Tek oturum seçimi coalition kullanmıyor; coalition tam çıkış/kurtarma katmanında kalıyor.
- **Doğrulandı:** `LOOM_MANAGED_RUN_ID`, süreç ortamından okunarak yeniden ebeveynlenmiş çalıştırmaları ayırıyor; çıplak PID ile okunan işaret ikinci anlık görüntüyle kimlik açısından doğrulanıyor. İşaret okuması actor içinde yeni süreç kimliği başına bir kez yapılıyor.
- **Doğrulandı:** Ölen ledger kimlikleri, Unix session'da seçili bir torun kalmadıktan sonra ayıklanıyor; `ProcessSupervisor` ledger'ı yalnız değiştiğinde yazıyor.
- **Doğrulandı:** Ortam zaman aşımı ve desteklenmeyen shell tipli hatalara dönüştürüldü; sağlayıcı geçmişi yokluğu için tipli hata tanımlandı.
- **Doğrulandı:** PTY okuma ve lider çıkışı `DispatchSource` ile olay tabanlıdır. Tek okuyucu ve tek `waitpid` sahibi vardır; fd yalnız cancel handler'da kapanır. Terminal IO için run-scoped `TerminalEndpoint` supervisor actor'ını atlar. Çıktı görünürlükten bağımsız olarak sink'e itilir; varsayılan scrollback yazıldıkça büyür ve 4 MiB üst sınırında eski byte'ları atar. Harici terminal sink'i geçmişi üstlenince ikinci byte scrollback oluşturulmaz. 8 MiB'lık okunmayan burst CLI'ı durdurmadan bütünüyle işlendi.
- **Doğrulandı:** Sistem `libsqlite3`'ü kullanan sürümlü katalog; WAL, uygulama kimliği, foreign-key ve açılış bütünlük kontrolüyle oluşturuluyor. Sohbet içeriği tutulmuyor. Bozuk dosya reddedilip byte düzeyinde değiştirilmeden bırakıldı.
- **Doğrulandı:** Oturum, sağlayıcı kimliği değişimi ve run başlangıç/bitişi kataloglanıyor. Quit, bekleyen katalog yazılarıyla yarışmıyor. Yeniden açılışta sohbet ve bitmiş run korunuyor, eski `currentRun` geri yüklenmiyor ve otomatik süreç başlamıyor.
- **Kontrol:** `swift build` geçti. Swift 6.4 komut satırı araçlarının `TestingMacros` eklentisini otomatik yüklememesi nedeniyle test komutuna eklenti yolu açıkça verildi; bu komutla 53 test geçti:
  `swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`
- **Doğrulandı:** Yavaş shell ortam çözümlemesi supervisor actor'ı dışında çalışıyor. `.zshrc` 0,4 sn beklerken terminal write/resize/read ve supervisor sorgusu 0,2 sn sınırının altında tamamlandı.
- **Doğrulanmadı:** 10 boşta oturumda CPU/uyanma ölçümü, binlerce torun uzun çalışma deneyi ve A9a–A9f gerçek sağlayıcı matrisi. Bunlar S1–S4'ün kalan kabulüdür. Katalogdaki lifecycle/last-used geçişleri provider olayları ve idle motoruyla birlikte uygulanacak.

## 14. Review: yapısal dilim (27 Eylül 2026)

Review'da `swift test` hem düz hem de eklenti yolu verilerek çalıştırıldı: 46/46 geçti. Oturum ile çalıştırmanın ayrılması, tek oturum durdurma, olay tabanlı PTY, katalog ve ledger'ın küçülmesi doğru yönde. Aşağıdakiler, Claude hook'ları ve Codex istemcisi bu yapının üzerine kurulmadan önce düzeltilmeli (1–3) ya da bu dilim içinde kapatılmalı (4–7).

1. **Quit oturum sayısıyla doğrusal uzuyor.** `ProcessSupervisor.shutdown` oturumları sırayla durduruyor (`ProcessSupervisor.swift:211`); her biri HUP/TERM/KILL bekleme sürelerinin tamamını bekleyebilir. §8'deki gerçekçi sağlayıcı bekleme süreleriyle 10 oturumda Quit onlarca saniyeye çıkabilir. Beklenen: bütün çalıştırmalara sinyaller aynı anda gider, bekleme ortak yapılır; her oturumun raporu yine ayrı tutulur. Kabul: 10 inatçı sentetik oturumda Quit süresi ≈ tek oturumun süresi.
2. **Terminal IO, yaşam döngüsü işleriyle aynı actor'dan geçiyor.** `write`, `readAvailable` ve `resize` supervisor actor'ı üzerinden çalışıyor (`ProcessSupervisor.swift:157-168`). Aynı actor, 30 sn'ye kadar süren senkron ortam çözümlemesini (`:76-84`) ve tam süreç taramalarını da yürütüyor; bu sırada tuş vuruşları ve çıktı bekler. Beklenen: çalıştırma açıldıktan sonra IO, actor'a uğramadan terminal nesnesinin kendi kuyruğundan yapılır; supervisor yalnızca yaşam döngüsünü yönetir. Ortam çözümlemesi supervisor actor'ını bloklamaz. Kabul: ortam çözümlemesi ya da tarama sürerken bir oturuma yazma ve okuma gecikmesi ölçülür ve bloklanmadığı gösterilir.
3. **Okunmayan oturum takılır.** Çıktı çekme modeliyle tamponlanıyor. 4 MiB dolunca okuma askıya alınıyor (`EventDrivenPTYProcess.swift:193-197`), CLI yazamaz ve bekler. CP1 kuralına göre yaşayan her oturumun çıktısı, gizli olsa da, sürekli işlenmelidir. Beklenen: çıktı her oturumun tüketicisine (ileride terminal motoru) itilir. Görünürlüğe bağlı geri basınç uygulanmaz; bellek, tüketicinin sınırlı scrollback'iyle sınırlanır. Bu, pencere parçasının terminal motoru arayüzünün temelidir.
4. **CLI kendiliğinden kapanınca oturum takılı kalıyor.** Kullanıcı `/exit` yazarsa `currentRun` `.exited` olarak kalıyor. Yeni `launch` reddediliyor (`:97`) ve CLI'ın arkada bıraktığı torunlar, biri `stop` çağırana kadar temizlenmiyor. Idle/resume diliminde kural tanımlanmalı: lider çıkınca kalan torunlar aynı sözleşmeyle kapatılır ya da görünür olarak raporlanır; ardından oturum yeniden açılabilir.
5. **İki yönetici ve üç kopya döngü.** `ShutdownCoordinator` (probe ve CP1 testleri) ile `ProcessSupervisor` yan yana duruyor. HUP/TERM/KILL + yeniden tarama döngüsü üç yerde kopya. Tek bir sonlandırma rutini kullanılmalı; probe supervisor'a taşınmalı ve eski koordinatör kaldırılmalı.
6. **S3 kısmen tamamlandı.** Ledger ölen kimlikleri ayıklıyor ve yalnızca değişince yazılıyor. Yeni PID başına tek işaret okuması ise yalnızca çalıştırma işareti (`LOOM_MANAGED_RUN_ID`) için geçerli. Uygulama geneli `OwnershipLedger.observe` her çağrıda bütün süreçlerde run işaretini ve coalition'ı yeniden okuyor. Ortam çözümlemesi sırasında 20 ms'de bir tam tarama devam ediyor (`LaunchEnvironment.swift:299`). §13'teki ilgili "doğrulandı" maddesi bu kapsamla okunmalı.
7. **Quit başında sınırsız bekleme.** `shutdown`, `reservedSessions` boşalana kadar 1 ms aralıklarla bekliyor (`:200`). Takılan bir katalog yazımı Quit'i süresiz bekletir. Süre sınırı ve raporlama eklenmeli.

## 15. Review uygulama sonucu (28 Eylül 2026)

§14'teki yedi bulgu bu yapısal dilimde kapatıldı:

1. **Çözüldü — ortak Quit penceresi.** `shutdown`, aktif run'ları önce tek snapshot ile sınıflandırıyor; HUP/TERM/KILL eskalasyonunu bütün uygulama sahiplik kümesine bir kez uyguluyor ve run tamamlamalarını paralel yapıyor. 10 inatçı sentetik oturum testi `graceSeconds: 0.05` ile toplam shutdown süresini 0,75 sn altında ve on ayrı başarılı `SessionStopReport` ile şart koşuyor.
2. **Çözüldü — IO actor'dan ayrıldı.** Launch sonucu run-scoped `TerminalEndpoint` döndürüyor; read/write/resize supervisor actor'ına girmez. Bloklayan ortam çözümlemesi `Task.detached` içindeki iptal edilebilir `EnvironmentResolutionJob`'a taşındı. Yavaş ortam çözümlemesi sırasında IO ve actor sorgusu testi geçti.
3. **Çözüldü — görünürlükten bağımsız push.** Event reader her chunk'ı terminal kuyruğunda sink'e iter. Varsayılan `TerminalScrollback` 4 MiB sabit ring buffer'dır; dolunca PTY okumayı askıya almak yerine en eski byte'ları değiştirir. Hiç `readAvailable` çağrılmadan üretilen 8 MiB çıktı bütünüyle tüketildi ve run doğal biçimde kapandı.
4. **Çözüldü — doğal çıkış kapanışı.** Lider çıkış olayı aynı session-scoped sonlandırma sözleşmesini otomatik başlatır, kaçmış torunları temizler, katalog bitiş nedenini `processExited` yazar ve `currentRun`'ı kaldırır. Kaçmış inatçı torun bırakan lider çıkışı sonrasında aynı oturumun yeniden launch edilebildiği doğrulandı.
5. **Çözüldü — tek yönetici ve tek eskalasyon rutini.** `ShutdownCoordinator` kaldırıldı. Probe, yalnızca senkron CLI köprüsü olan `ProbeSupervisor` üzerinden çekirdekteki `ProcessSupervisor`'ı kullanıyor; CP1 yaşam döngüsü ve recovery testleri de supervisor'a taşındı. Session stop ile app-wide sweep aynı `terminate` rutinini kullanıyor.
6. **Çözüldü — uygulama-geneli metadata cache.** `OwnershipLedger`, run işareti ve coalition sonucunu yaşayan `ProcessIdentity` başına bir kez okuyor. Cache ölen kimlikte/PID reuse'da ayıklanıyor, JSON'a yazılmıyor ve kimlik doğrulama snapshot'ı zorunluluğunu kaldırmıyor. Tekrar okuma, PID reuse, recovery ve doğrulama başarısızlığı testleri geçti.
7. **Çözüldü — bounded pending operasyonlar.** Quit, reservation ve ortam işlerini varsayılan 2,1 sn sınırla bekliyor; süre aşımını raporluyor ve ortam işlerini iptal ediyor. Run, katalog await'inden önce supervisor'a yayımlandığı için timeout halinde OS süreci yine temizleniyor. Katalog finish yazıları ayrı izlenip aynı sınırla bekleniyor. `BEGIN IMMEDIATE` ile kilitlenmiş SQLite launch testinde shutdown 1 sn sınırının altında döndü, süreç kalmadı ve kilit açıldıktan sonra geç run yayınlanmadı.

## 16. İkinci review (28 Eylül 2026)

§15'teki yedi düzeltme kodda doğrulandı. `swift test` 53/53 geçti. `ShutdownCoordinator` tamamen kaldırılmış; tek eskalasyon rutini (`ProcessSupervisor.terminate`) kullanılıyor. Yeni bulgular engelleyici değil, CP2'nin kalan işleriyle birlikte kapatılmalı:

1. **Boşta oturum başına 4 MiB bellek.** `TerminalScrollback`, açılışta `capacity` kadar sıfırlanmış dizi ayırıyor (`TerminalEndpoint.swift:22`). Review ölçümünde 10 boş tampon, çıktı olmadan +40 MiB physical footprint ekledi. Terminal motoru sink olarak bağlandığında bu tampon ikinci bir kopya olur. Beklenen: tampon yazıldıkça büyür (üst sınır aynı kalır); bir sink geçmişi kendisi tutuyorsa byte scrollback tutulmaz ya da küçük tutulur. Kabul: boşta 10 oturumda tampon kaynaklı artış ihmal edilebilir.
2. **CP1 gerçek Claude kapanış düzeltmesi yeniden doğrulanmalı.** CP1'de gerçek Claude'un doğrudan çocuğu, PTY master'ı açık ve okunmazken zombie durumunda reap edilemiyordu. Düzeltme, sinyallerden önce master'ı kapatmaktı. Yeni `stop` ve `shutdown`, sinyalleri master açıkken gönderiyor ve terminali `finish` içinde sonradan kapatıyor. Push okuma sürekli çalıştığı için eski koşul muhtemelen oluşmuyor, ama bu gerçek Claude ile sınanmadı. Gerçek sağlayıcı matrisinde C3 (aktif tur + arka plan işi + Quit) ve D1 (birleşik Quit) yeni supervisor ile tekrarlanmalı.
3. **Bilgi (ürün davranışı):** Lider kendiliğinden çıkınca (`/exit`), run'ın hâlâ yaşayan torunları 0,2 sn eskalasyonla kapatılıyor. Örneğin Claude'un başlattığı bir dev server, Claude'dan çıkınca kapanır. Bu, sözleşmedeki "Loom'a ait iş arkada kalmaz" kuralıyla tutarlıdır. Arayüzde görünür olmalı.

## 17. İkinci review uygulama sonucu ve Claude hook başlangıcı (28 Eylül 2026)

İkinci review bulguları kapatıldı ve uygulama sırasındaki 3. adıma geçildi:

1. **Çözüldü — boş scrollback artık bellek ayırmıyor.** `TerminalScrollback` ilk byte gelene kadar 0 byte backing storage kullanıyor, sonrasında kapasiteye kadar geometrik büyüyor. On sessiz oturum testi her endpoint için 0 allocation şart koşuyor. Terminal motoru gibi harici sink verildiğinde `scrollback == nil`; aynı çıktı iki geçmişte tutulmuyor. Yeni ve eski byte sırasının ring büyümesinde korunduğu ayrıca test edildi.
2. **Doğrulandı — C3 gerçek Claude kapanışı.** Haiku/low gerçek TUI, arka plan `sleep 120` ve aktif turla 4 sahipli süreçten 0'a 0,561 sn'de kapandı. PTY master sinyaller sırasında açık, push reader etkinken zombie/reap regresyonu oluşmadı. Run `DBE03716-F79E-42D6-92A3-C7CD6EFE63F1`; `remaining`, `errors`, `outsideOwnership` ve `missing-external` boş.
3. **Doğrulandı — D1 birleşik kapanış.** İki Claude, iki remote Codex, ortak app-server ve sentetik kaçakla 7 sahipli süreçten 0'a 0,835 sn'de kapandı. Run `64595959-7BF6-4B7B-BCBE-D108EB524DA9`; dış süreç kimliği kaybı yok.
4. **Ürün davranışı görünürlüğü:** CP2 arayüz içermiyor. Çekirdek doğal lider çıkışını `processExited`, ayrı `SessionStopReport` ve temizlenmiş run olarak zaten koruyor; ilk pencere bu nedeni ve torunların beraber kapatıldığını görünür kılacak. Bu davranış sessizce "başarıyla tamamlandı" durumuna çevrilmeyecek.
5. **Claude taşıması uygulandı ve gerçek sağlayıcıyla doğrulandı.** `loom-hook`, owner-only Unix soketine app-run token'ı, `LOOM_SESSION_ID`, `LOOM_MANAGED_RUN_ID` ve ham event'i gönderiyor. Receiver token/protokol/boyut kontrolünden sonra event'i teslim ediyor. Gerçek akışta `SessionStart(startup) → UserPromptSubmit → Stop → SessionEnd(other)` aynı provider session ve managed run kimliğiyle geldi; run `9299D9DC-FDD8-41BA-B515-CBAE3433162B`.
6. **Tipli durum reducer'ı uygulandı.** Çalışıyor, onay bekliyor, girdi bekliyor, tur tamamlandı, hata, session sonu ve bilinmiyor birbirinden ayrıldı. `Stop` içindeki arka plan görevleri ve session cron sayısı ayrı tutuluyor. Eski managed run veya yanlış Loom session event'i aktif durumu değiştirmiyor; bilinmeyen event başarı sayılmıyor.
7. **Sıradaki dilim:** `SessionStart(clear/resume/fork)` için run içindeki aktif Loom sohbet eşlemesini ve G2'deki ayrı kayıt kuralını kataloğa bağlamak; ardından `last_used_at` yazımı ve T1–T4'ün kalan gerçek senaryoları. Mevcut katalog kimliğini yerinde değiştirmek G2'yi ihlal edeceği için bu geçiş ayrı ve atomik uygulanacak.
8. **Kontrol:** Eklenti yolu verilen `swift test` ile 60/60 test geçti. Gerçek tekrar komutları `loom-probe experiment plans/experiments/claude-hooks.json`, `claude-active-quit.json` ve `combined.json`; üçü de önceden hazırlanmış izole provider profili altında çalıştırıldı. `git diff --check` temiz.

## 18. Tamamlanan CP2 mimarisi (28 Eylül 2026)

- **Kalıcı kimlik ve geçmiş:** Bir Loom oturumu, sağlayıcı sohbeti ve OS run'ı ayrı kimliklerdir. `run_sessions` bağlantıları bir PTY'nin `/clear`, `/new` veya resume ile hangi kalıcı sohbet kayıtlarına bağlı olduğunu tarihçesiyle korur. Geçiş tek SQLite transaction'ıdır; eski sohbet silinmez ve idle geçmiş olur.
- **Claude:** Oturuma özel `--settings`, owner-only Unix soketi ve `loom-hook` yardımcısı kullanılır. Hook zarfı hem Loom session hem managed run kimliğini taşır. `SessionStart(clear/fork/resume)` aktif sohbet eşlemesini değiştirir; prompt, stop, hata, onay/girdi ve arka plan iş bilgileri tipli reducer'a gider. Eski run olayı reddedilir.
- **Codex:** İlk Codex lease'inde tek Loom app-server'ı başlar, son lease bırakıldığında aynı sahiplik sözleşmesiyle kapanır. Core istemci async ve tiplidir; Unix WebSocket upgrade, masking, fragment, ping/close ve 16 MiB sınırı uygulanır. Bilinmeyen alan/olaylar protokolü düşürmez. Yeni TUI başlatmaları `thread/started` olayında ayırt edici run alanı olmadığı için sıraya alınır. `/new`, yalnızca aynı cwd'de tek olası çalışan TUI varsa eşlenir; belirsizlikte katalog tahminle değiştirilmez.
- **Codex olay sınırı:** Başka istemcinin başlattığı remote TUI turunda `thread/status/changed` yayınlanıyor; kurulu 0.157.1 sürümü her yeni tur/item/final-answer olayını ikinci app-server istemcisine yayınlamıyor. Koordinatör idle durumunda `thread/read` ve `thread/backgroundTerminals/list` ile kesin durumu hydrate eder. Onay server-request'i ve arka plan terminal listesi gerçek TUI ile ayrıca görüldü. Böylece ekran ayrıştırması yapılmadan G1 görünürlüğü korunuyor.
- **Yaşam döngüsü:** Idle değerlendirmesi son kullanımı, tipli ajan durumunu, bekleyen sağlayıcı işini, UI'ın önce kaydettiği prompt teslimini ve başlangıç baseline'ından sonra oluşan torunları birlikte kontrol eder. Kontrollü stop ve sıfır kalıntıdan sonra run nedeni `idle` ve session yaşam döngüsü `idle` yazılır. Stop sırasında prompt gelirse aynı durable session aktif kalır, prompt kimliği saklanır ve ikinci süreç açılmaz.
- **Resume:** Claude yalnız `--resume <id>`, Codex yalnız `resume <id> --remote ...` kullanır; hiçbir hata yolu yeni sohbete düşmez. Resume aynı Loom kaydını, çalışma dizinini ve provider kimliğini korur. Katalog lifecycle yazısı başarısız olursa yeni PTY kapatılır. Aynı provider sohbetinin Loom içinde iki canlı kopyası engellenir.
- **Stale:** Yalnız idle kayıt 15 günlük eşiği geçince stale olur. Görüntüleme stale kaydı canlandırmaz; açık `reactivate` gerekir ve tek başına süreç başlatmaz.

## 19. Kabul matrisi sonucu

| # | Sonuç | Kanıt |
| --- | --- | --- |
| S1–S4 | **Doğrulandı** | CP1 regresyonları ve 81 test geçti. 10 sessiz oturumda 2,034 sn pencerede CPU %0,00028, package idle wakeup 0, terminal scrollback allocation 0 byte, footprint artışı 589.824 byte; run `37B28524-05B3-4E48-8C21-A74A22D45348`. 5.000 kısa ömürlü torunda durable ledger her adımda en çok yaşayan kimlikleri tuttu ve final JSON 1 KiB altında kaldı. MainActor dışı ortam çözümleme/IO ve ortak Quit penceresi testleri geçti. A9a–A9f sahiplik matrisi CP1'deki sonucu koruyor. |
| G1 | **Doğrulandı** | Gerçek remote TUI'de `working`, `waitingOnApproval`, approval request ve `/bin/sleep 90` background terminali görüldü; run `32F1416E-0A2C-448B-A6B7-994682421AAC`. Product client resume/hydration son yanıtı `CODEX_CORE_OK` ve background count 0 olarak okudu; run `BD7B880F-06AA-4CD3-BF74-E541BED2D5B6`. Yayın sınırı ve hydration kuralı §18'de açıklandı. |
| I1 | **Doğrulandı** | Claude hook kimliği run/session zarfıyla kesin. Codex yeni başlatmaları serialized matcher ile eşliyor; iki rezervasyon testi geçti. Gerçek `/new` run'ında aynı cwd'de iki farklı `thread/started` kimliği görüldü: `69F5B840-023E-4715-8B45-A66EB7D2EC23`. |
| I2 | **Doğrulandı** | Claude `/clear`, `F453…` kimliğini `131C…` kimliğine aynı run'da taşıdı; `EF080943-74A7-432F-A2CB-5D3AB271014B`. Codex `/new` gerçek kimlik değişimi yukarıdaki run'da görüldü. Her iki provider için eski/yeni katalog kayıtları ve run link geçmişi birim testlerinde doğrulandı. |
| T1 | **Doğrulandı** | Claude `SessionStart → UserPromptSubmit → Stop` ve son yanıt varlığı gerçek hook ile; `9299D9DC-FDD8-41BA-B515-CBAE3433162B`. Codex remote status + `thread/read` ile `CODEX_CORE_OK`; `BD7B…`. |
| T2 | **Doğrulandı** | Claude `PermissionRequest(Bash)` ve çalıştırılmamış komut: `44F14A0F-7FDA-4871-93EA-DB3EAF199129`. Codex `waitingOnApproval` + `item/commandExecution/requestApproval` + decline sonrası durum: `32F1416E…`. Loom kullanıcı yerine karar vermedi. |
| T3 | **Doğrulandı** | Beklenmeyen provider exit başarıya değil `unknown` durumuna arşivleniyor; error/thread-closed ve bilinmeyen olay fixture'ları reducer testlerinde. Gerçek crash/cleanup CP1 sağlayıcı deneyleriyle, süreç tarafı ayrıca doğrulandı. |
| T4 | **Doğrulandı** | Run sequence barrier ve Claude managed-run kontrolü; eski run olayı yeni launch'ı değiştirmedi. |
| L1 | **Doğrulandı** | Sessiz oturum controlled stop sonrası `idle` end reason aldı; ikinci canlı oturum etkilenmedi ve aynı sohbet yeniden açıldı. |
| L2 | **Doğrulandı** | Approval, provider background işi ve baseline sonrası oluşan torun ayrı blocker olarak kaydedildi; süreç kapanmadı. |
| L3 | **Doğrulandı** | Stop sırasında kaydedilen prompt ID korundu, lifecycle active kaldı, OS run sıfıra indi ve ikinci süreç açılmadı. |
| L4 | **Doğrulandı** | Test saatiyle idle → stale; görüntüleme stale bıraktı, yalnız açık reactivation active yaptı. |
| R1 | **Doğrulandı** | Claude aynı `8AAC4338-24FA-4781-AE5E-A5D0D6751BA0` kimliğiyle resume: `B019C521-CD20-42F4-A8C7-B23632C967AE`. Codex aynı `01a0e414-6e51-7d43-a3b3-e9e5ea72d53e` thread'iyle remote resume: `C68D387E-EDD2-4D72-A2EC-E16909570E6D`; product core tekrarında `BD7B…`. |
| R2 | **Doğrulandı** | SQLite reopen testi aynı session/provider kimliği, çalışma dizini ve bitmiş run'ı yükledi; `currentRun == nil`, otomatik süreç yok. |
| R3 | **Doğrulandı** | Claude eksik UUID: `No conversation found`, run `A2F9DA0A-31CB-4AC1-8EEE-0DCB7E10CB56`; Codex eksik UUID: `No saved session found`, run `E7014FA7-ED45-4363-BA66-85C0F0388F92`. İkisi de yeni sohbet açmadan bitti; gerçek metinler tipli `providerHistoryUnavailable` eşlemesine alındı. |
| Q1 | **Doğrulandı** | Claude aynı sohbeti aktif approval sırasında kapattı (`6402AA53-057E-46E0-B3F0-99891E9BC4B9`), yeniden açtı (`B2AAB03E-1BB9-457D-A088-16C6A2CF5138`) ve önceki tamamlanmış yanıtı `CLAUDE_RESUME_OK` olarak geri çağırdı. Codex aktif `/bin/sleep 90` turu `32F1416E…` ile kapandı; aynı rollout/thread daha sonra `C68D…` ve product core `BD7B…` ile açıldı, önceki kayıtlar korunurken yeni tur tamamlandı. Her çıkışta kalıntı 0. |

## 20. Quit ölçümü ve sağlayıcı davranışı

Deneylerde kullanılan ortak grace penceresi 0,4 sn'dir. Sonuç, sabit bir sağlayıcı varsayımından ziyade gözlenen eskalasyonu kaydeder:

| Sağlayıcı/koşul | HUP sonucu | Toplam controlled Quit |
| --- | --- | --- |
| Claude, tamamlanmış tur sonrası | 0,4 sn içinde kapanmadı; bir süreç TERM istedi | 0,815 sn (`B019C521…`) |
| Claude, aktif approval | 0,4 sn içinde kapanmadı; bir süreç TERM istedi | 0,783 sn (`6402AA53…`) |
| Codex remote, tamamlanmış tur + app-server | yalnız HUP yeterli | 0,032 sn (`C68D387E…`) |
| Codex remote, aktif turn/background terminal + app-server | TUI tarafında TERM gerekti | 0,429 sn (`32F1416E…`) |
| Birleşik iki Claude + iki Codex + server + sentetik | ortak HUP/TERM/KILL saati, seri bekleme yok | 0,835 sn (`64595959-7BF6-4B7B-BCBE-D108EB524DA9`) |

Bu nedenle ürün tek bir “nazik sinyal yeter” iddiası kullanmıyor. Sağlayıcılar ortak bounded HUP → TERM → KILL sözleşmesine giriyor; başarı ancak süreç yokluğu doğrulanınca yazılıyor.

## 21. Son kontrol ve açık sınırlar

- `swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`: **81/81 test, 9 suite geçti** (9,306 sn).
- `git diff --check` temizdir. Gerçek deneylerin tümünde `remaining`, `errors` ve `outsideOwnership` boş kaldı.
- Dışarıda açılmış aynı provider sohbetini güvenilir biçimde saptayan ortak, belgelenmiş bir kilit API'si yok. Loom kendi kataloğu içindeki çift canlı sohbeti kesin engelliyor; başka uygulamadaki olası kopyayı tespit etmiş gibi davranmıyor. Bu garanti sınırı sessiz fallback üretmiyor.
- Codex app-server protokolü sürüme bağlıdır. İstemci bilinmeyen alanlara toleranslıdır; gerekli RPC/olay yoksa görünür entegrasyon hatası vermeli, terminal ekranından durum tahmin etmemelidir.
- CP2 tamamlandı. Sonraki uygulama dilimi sözleşmedeki sıraya göre terminal motoru ve ilk penceredir; silme/retention ile oturumlar arası koordinasyon bu checkpoint'in kapsamı değildir.

## 22. Tamamlanma review'ı (28 Eylül 2026)

Review'da `swift test` 81/81 geçti. §19'daki kanıtlar run kimlikleriyle tutarlı. §16'daki iki not kapanmış: scrollback artık tembel ayrılıyor; gerçek Claude, master kapatılmadan yapılan yeni kapanışta Q1 dahil kalıntısız bitiyor. Gerçek run terminal kayıtlarında Claude `hook error` bildirimi yok. Pencere dilimine geçmeden önce aşağıdaki dört açık kapatılmalı; 3–4 pencere diliminin tasarım girdisidir.

1. **Codex tek oturum durdurma, sunucudaki işi büyük olasılıkla durdurmuyor.** Yol (a)'da tur ve komutlar paylaşılan app-server'da çalışır; TUI yalnızca bir istemcidir. `stop` / `stopForIdle` yalnızca TUI süreç ağacını kapatıyor; `turn/interrupt`, `thread/backgroundTerminals/terminate` ya da `thread/unsubscribe` çağrılmıyor (`ProcessSupervisor.swift:619-644`; kaynakta hiçbir çağrı yok). Başka bir Codex oturumu sunucuyu açık tutuyorsa, durdurulan oturumun aktif turu ve başlattığı komutlar (örneğin bir dev server) sunucu altında sürebilir. Stop raporu buna rağmen başarılı döner. Quit'te sunucu kapandığı için sorun yok; idle yolu da arka plan terminali varsa bloklanıyor.
   - **Önce doğrulama:** İki Codex oturumu açılır; birinde uzun bir tur başlatılır (örneğin `sleep 60 && touch <marker>`). Bu oturum, diğeri açıkken durdurulur. Ardından `thread/read`, arka plan terminalleri ve marker ile turun sürüp sürmediğine bakılır.
   - **Doğrulanırsa beklenen:** Oturum durdurma sırası şöyle olur: aktif tur varsa `turn/interrupt` → `thread/backgroundTerminals/terminate` → `thread/read` ile aktif tur ve arka plan terminali kalmadığının doğrulanması → TUI kapanışı → abonelikten çıkma. Doğrulanamazsa stop başarılı sayılmaz.
2. **Belirsiz Codex `/new`, idle motorunun çalışan oturumu kapatmasına yol açabilir.** Aynı çalışma dizininde iki Codex TUI varken `/new` gelirse `thread/started` `.ambiguous` olur ve yalnızca iç bir `recordedIssues` metnine yazılır (`CodexSessionCoordinator.swift:174-178`). Etkilenen oturum eski thread'e bağlı kalır; eski thread `turnComplete` göründüğü için idle blocker üretmez (`SessionLifecycleController.swift:135-146`). Yol (a)'da komutlar TUI'nin değil sunucunun çocuğu olduğundan süreç baseline'ı da işi göremez. Yeni thread'de kullanıcı girdisi olmadan süren uzun bir tur, idle süresi dolunca kesilebilir. Beklenen:
   - Belirsizliğe düşen aday oturumlar "kimlik belirsiz" olarak işaretlenir. Bu durum idle blocker'dır ve arayüzde görünür.
   - Belirsizlik çözülmeden bu oturumlar otomatik idle'a alınmaz.
   - Kabul testi aynı senaryoyu sentetik olay dizisiyle kurar.
3. **Sağlayıcı mantığı süreç yöneticisinin içinde.** `ProcessSupervisor` 1.090 satır ve Claude hook'larını (`receiveClaudeHook`, `applyClaudeIdentity`), Codex eşleşmesini ve olaylarını (`bindCodexThread`, `transitionCodexConversation`, `receiveCodexEvent`, `resolveCodexRequest`, `refreshCodexThread`) ve sağlayıcı durumlarını barındırıyor. Sözleşme sağlayıcı entegrasyonlarını ayrı sorumluluk sayıyor (§1, §9); her yeni sağlayıcı bu sınıfı büyütür. Pencere katmanı bu API'lere bağlanmadan önce sağlayıcı adaptörü sınırı çizilmeli: supervisor süreç/run'ı yönetir, adaptörler sağlayıcı olaylarını tipli oturum olaylarına çevirir.
4. **Arayüz için itme tabanlı durum akışı yok.** Durum `claudeStatus` / `codexStatus` / `providerWorkState` ile çekiliyor; `evaluateIdle` host tarafından çağrılmalı. Pencere dilimi için tek, tipli bir oturum olayları akışı (durum, yaşam döngüsü, kimlik, run başlangıç/bitiş) ve bir sonraki idle zamanına kurulan tek bir zamanlayıcı gerekiyor; sidebar yoklama yapmamalı.

**Bilgi:** Hook token'ı ortam değişkeninde olduğu için Claude'un çalıştırdığı komutlar da onu görebilir; aynı kullanıcı kodu sahte durum olayı gönderebilir. Aynı kullanıcı kodu zaten süreçleri de kapatabildiğinden risk düşük; sahte olaylar yalnızca kendi run kimliğiyle eşlenebildiği sürece kabul edilebilir. Soket yolları çağıran tarafça veriliyor; ürün host'u kısa ve özel bir dizin seçmelidir (Darwin `sun_path` sınırı).

### 22.1. Uygulama sırası ve kabul (kullanıcı kararı: dört madde de kapatılmadan pencere dilimine geçilmez)

0. **Başlangıç:** Mevcut çalışma ağacı ayrı bir commit olarak kaydedilir; bu dilimin değişiklikleri review'a kadar commit edilmez.
1. **Madde 1 — Codex oturum durdurma:**
   - Önce §22.1'deki doğrulama deneyi izole profilde yapılır; sonuç kayda geçer.
   - Tur ya da komut sunucuda sürüyorsa düzeltme uygulanır: `turn/interrupt` → `thread/backgroundTerminals/terminate` → `thread/read` ile doğrulama → TUI kapanışı → `thread/unsubscribe`.
   - Doğrulanamayan durdurma başarı olarak raporlanmaz.
   - Aynı sözleşme `stopForIdle` ve lider çıkışı için de geçerlidir.
   - Kabul: iki Codex oturumlu gerçek deneyde durdurulan oturumun marker'ı oluşmaz, aktif turu ve arka plan terminali kalmaz, diğer oturum etkilenmez.
2. **Madde 2 — belirsiz Codex `/new`:**
   - Aday oturumlar kalıcı olmayan bir "kimlik belirsiz" durumuna alınır.
   - Bu durum idle blocker'dır, oturum durum API'sinde görünür, `recordedIssues` metnine gömülmez.
   - Kabul: sentetik olay dizisiyle aynı cwd'de iki TUI + `/new` + süre dolumu senaryosunda iki oturum da idle'a alınmaz ve blocker nedeni okunabilir.
3. **Madde 3 — sağlayıcı adaptörü sınırı:**
   - `ProcessSupervisor` yalnızca oturum/run/süreç sahipliğini ve IO uç noktalarını yönetir.
   - Claude hook ve Codex app-server mantığı sağlayıcı adaptörlerine taşınır. Adaptörler sağlayıcı olaylarını tipli ortak oturum olaylarına çevirir ve supervisor'a yalnızca sağlayıcıdan bağımsız API ile konuşur.
   - Yeni bir sağlayıcı eklemek supervisor'ı değiştirmeyi gerektirmemelidir.
   - Kabul: davranış değişmez; mevcut testler geçer; supervisor kaynağında Claude'a ya da Codex'e özel tip veya çağrı kalmaz.
4. **Madde 4 — oturum olay akışı ve idle zamanlayıcısı:**
   - Tek, tipli bir oturum olayları akışı sağlanır: durum, yaşam döngüsü, kimlik ve kimlik belirsizliği, run başlangıç/bitiş, blocker değişimi.
   - Tüketici yoksa ya da yavaşsa sınırlı kalır; en son durumu kaybetmeden birleştirir.
   - Idle ve stale değerlendirmesi, bir sonraki vade zamanına kurulan tek bir zamanlayıcıyla yapılır. Oturum başına timer ve periyodik yoklama olmaz.
   - Kabul: 10 boşta oturumda uyanma sayısı yeniden ölçülür ve CP2'deki değerden kötüleşmez; olay akışı durum değişikliklerini sırayla ve kayıpsız son durumla verir.
5. **Kapanış:**
   - `swift build`, bütün testler, `git diff --check`.
   - Gerçek sağlayıcı duman testi: Claude ve Codex için Q1 (aktif iş + Quit + yeniden açılış + resume) yeni yapıyla tekrarlanır.
   - Sonuçlar bu dosyada yeni bir §23'e doğrulandı / başarısız / doğrulanmadı olarak, run kimlikleriyle yazılır.

### 22.2. Pencere dilimi için toplanan girdiler

Sonraki dilimin (terminal motoru ve ilk pencere) planı yazılırken kullanılacak, bu checkpoint'te biriken maddeler:

- **Olay akışı ve zamanlayıcı:** §22 madde 4: tek tipli oturum olay akışı ve tek idle zamanlayıcısı. Sidebar yoklama yapmaz.
- **Terminal motoru:** Terminal motoru seçilir; `TerminalOutputSink` bu motorun girişidir. Motor geçmişi kendisi tutuyorsa byte scrollback ikinci kopya olmamalıdır (§16 madde 1).
- **Renk bildirimi:** `COLORTERM`, motor destekliyorsa ayarlanır (CP1 §12.4).
- **GPU deneyi:** Sözleşme §10'daki cam/opak × boşta/çıktı deneyi, görünür ve örtülü pencere koşullarında yapılır. Xcode/Instruments yok; yöntem buna göre seçilir.
- **Soketler:** Hook ve app-server soketleri kısa, sahibine özel bir dizinde durur (Darwin `sun_path` sınırı; §22 bilgi notu).
- **Quit sırası:** Hook alıcısı, oturumlardan sonra kapanır. Aksi halde Claude `SessionEnd` hook'u "hook error" bildirimi üretir.
- **Görünür davranış:** CLI'dan `/exit` ile çıkınca, CLI'ın başlattığı işlerin de kapatıldığı arayüzde görünür olmalı (§16 madde 3).
- **Dağıtım:** Geliştirme ve günlük kullanım ayrı bundle kimliği ve veri dizini kullanır; sabit yerel imza (sözleşme §9 dersleri). Coalition katmanı yalnızca uygulama LaunchServices ile açıldığında etkindir.
- **Kullanıcı kararları:**
  - minimum macOS sürümü,
  - v1 özellik kapsamı (`design/DESIGN.md` §4 envanterinden seçim),
  - pencere kapatma düğmesinin davranışı (sözleşme §6).

## 23. CP2 review açıklarının kapanışı (28 Eylül 2026)

Başlangıç çalışma ağacı `a801f21` commit'iyle ayrı kaydedildi. Aşağıdaki dilim commit edilmedi. Deneyler yalnız Loom-Dev probe profili veya `/tmp/loom-cp2-review` altındaki yeni profille yapıldı; gerçek kullanıcı profili ve oturumları kullanılmadı.

| Kabul | Sonuç | Kanıt |
| --- | --- | --- |
| 1 — önceki davranışın doğrulanması | **Doğrulandı (açık vardı)** | İki TUI ve paylaşılan sunuculu `F4479222-0801-4AF4-8A46-9F751CC6709C` run'ında A TUI'si kapandıktan 18 saniye sonra `thread/read` A turunu hâlâ `active/waitingOnApproval` gösterdi; B açık kaldı. Komut onay beklediği için bu ilk run marker davranışını **doğrulamadı**. |
| 1 — düzeltilmiş tek oturum stop | **Doğrulandı** | Ürün `ProcessSupervisor.stop` yoluyla iki oturumlu son run `546CA00D-8157-4CC3-B23A-0664B3996B6E`: A'nın `sleep 12; touch` komutu süreç tablosunda canlı görüldü; stop başarılı, A turu idle, arka plan terminali 0, 14 saniye sonra marker yok; B'nin run'ı ve thread'i çalışıyor, paylaşılan sunucu açık. İlk başarılı uygulama run'ı `C45CF3DA-4793-4821-ADB6-79E8B86EC3DB`. Stop hazırlığı doğrulanmazsa TUI'yi açık bırakıp başarısız raporlayan regresyon testi geçti. Aynı stop fonksiyonu açık stop, `stopForIdle` ve lider çıkışında kullanılıyor. |
| 2 — aynı cwd'de iki TUI + `/new` | **Doğrulandı** | `ambiguousNewThreadBlocksBothSameDirectorySessions` sentetik olay testi, run kimlikleri `22222222-2222-4222-8222-000000000001` ve `22222222-2222-4222-8222-000000000002`: iki adayın tipli kimlik durumu `ambiguous`, olay akışı görünümü aynı, ikisi de süre dolumunda `.ambiguousIdentity` blocker ile çalışır kaldı. Belirsizlik `recordedIssues` metnine eklenmiyor. |
| 3 — sağlayıcı adaptörü sınırı | **Doğrulandı** | Claude hook ve Codex app-server durum/kimlik indirgemesi `ClaudeSessionAdapter` ile `CodexSessionAdapter` içinde. `ProcessSupervisor.swift` kaynağında Claude/Codex tipi veya çağrısı yok; genel konuşma, iş durumu ve stop-hook API'leri var. Davranış regresyonları 87/87 geçti; gerçek adaptör yolları Claude Q1 `3C524E3B-4FD9-4457-9405-8802BEA3EA73` ve Codex Q1 `4F02421A-8677-4EE2-86D2-4909DAC2FEFF` ile çalıştı. |
| 4 — tipli olay akışı ve tek timer | **Doğrulandı** | `SessionEventHub` durum, yaşam döngüsü, kimlik/belirsizlik, run başlangıç/bitiş ve blocker değişimlerini sıralı revision ile yayımlıyor. Tüketici başına son bir frame tutuluyor; frame tüm oturumların son durumunu içeriyor. Hızlı/yavaş tüketici testleri ve otomatik idle→stale testi geçti. On boşta oturum ölçümü `0C79A53D-346D-4CDC-B312-350051D5F035`: 2,057 sn, package idle wakeup **0** (CP2 referansı **0**), idle timer fire **0**, scrollback allocation **0**; CPU %0,000325. |
| Kapanış — Claude Q1 | **Doğrulandı** | İzole Loom-Dev probe run'ı `3C524E3B-4FD9-4457-9405-8802BEA3EA73`: tamamlanmış `CLAUDE_Q1_3C524E3B` turu, aktif approval sırasında başarılı Quit (run `BCCFC121-F1E7-4C79-B0EA-949DB037EDCA`), yeniden açılış ve aynı sohbetten önceki token'ın geri çağrılması (run `24E40C01-8956-4E8C-B472-35B35785F490`), ikinci temiz Quit. |
| Kapanış — Codex Q1 | **Doğrulandı** | Tamamlanmış `CODEX_CORE_OK` turu `2E561F90-FACE-453D-80FD-8D8D83BE62DE`; aynı thread'in aktif `sleep 12` komutu sırasında temiz Quit `4F02421A-8677-4EE2-86D2-4909DAC2FEFF` (OS run `C4B2807D-8013-4F5A-A078-78B094471253`, uyuyan süreç kalıntısı 0); aynı thread'in yeniden açılıp önceki token'ı geri çağırması `00078EEA-4479-4329-9302-859185A57530`. Thread `01a0e7aa-bc52-7c81-9123-58e572ca7420`. |
| Kapanış — derleme ve test | **Doğrulandı** | `swift build` başarılı; tüm 87 test 10 suite içinde geçti; `git diff --check` temiz. Bu makinedeki Command Line Tools `swift test` çağrısında `TestingMacros` kütüphanesini otomatik bulamadı ve derleme **başarısız** oldu. Aynı tüm testler `-Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib` ile geçti. |

İlk kopya Claude profilindeki kimlik bilgisi `auth status` açısından geçerli olmadığından `E9BD4F04-FD53-4096-9E27-FBD6A3ABB019` run'ı **doğrulanmadı** (`authentication_failed`); yukarıdaki başarılı Claude Q1, önceden ayrılmış Loom-Dev probe profilinde yeni bir sohbetle tekrarlandı. Codex'in boş geçmişli B thread'inde `thread/read(includeTurns: true)` `list_turns is not supported yet` döndürdü; istemci yalnız bu durumda `includeTurns: false` ile durum okuyor. Son iki oturumlu kabul run'ı bu düzeltmeyle geçti.

## 24. Review: §23 kapanışı (28 Eylül 2026)

§22'nin dört maddesi kodda doğrulandı:

- **Madde 1:** Codex durdurma sırası `interrupt` → arka plan terminallerini kapatma → doğrulama → TUI kapanışı → abonelikten çıkma (`CodexAppServer.swift:326-367`). `/new` sonrası durdurma kancası yeni thread'e yeniden bağlanıyor. Ajanın ön deneyi (`F4479222…`) açığın gerçek olduğunu gösterdi.
- **Madde 2:** Belirsizlik tipli kimlik durumuna dönüşüyor ve idle blocker oluyor.
- **Madde 3:** `ProcessSupervisor.swift` içinde Claude ya da Codex referansı kalmadı (942 satır).
- **Madde 4:** `SessionEventHub` tüketici başına son kareyi tutuyor. Idle zamanlayıcısı tek; yeniden kurulurken eskisi iptal ediliyor; bloklanan oturum, durum değişikliğinde yeniden değerlendiriliyor.

CP2 kapanmadan önce aşağıdaki üç madde kapatılmalı.

1. **Test paketi kararsız ve bir test kilitleniyor (engelleyici).** Review'da tam paket 10 kez çalıştırıldı: 7 geçti, 2 başarısız oldu, 1 kilitlendi.
   - **Kilitlenme:** `ProcessLifecycleTests.leavesExternalProcessUntouched`, 8,5 dakika boyunca `defer` içindeki `external.waitUntilExit()` çağrısında bekledi (`ProcessLifecycleTests.swift:110`; `sample` yığını bu satırı gösterdi). Async ve `@MainActor` bir testte Foundation `Process`'i bloklayarak beklemek güvenli değil. `LoomCore` `Process` kullanmıyor; sorun yalnızca testte.
   - **Başarısızlıklar:** Tam paket çalışırken iki test ara ara başarısız oldu. Tek başlarına, 4 çekirdek CPU yükü altında 4 kez çalıştırıldıklarında sorun çıkmadı. Başarısız olanlar:
     - `tenSilentSessionsDoNotPreallocateScrollbackCapacity`: `shutdown(graceSeconds: 0.05).succeeded` false döndü.
     - `shutdownStopsTenStubbornSessionsWithinOneSharedSignalWindow`: 4 sorun.
   - **Olası neden:** Son `SIGKILL` penceresi sonunda öldürülmüş ama henüz reap edilmemiş süreçler `remaining` sayılıyor; paralel çalışan suite'lerin yükü bunu tetikliyor. Aynı durum üründe de, süreçler zaten ölürken Quit'in başarısız raporlanmasına yol açabilir.
   - **Beklenen:**
     - Test süreçleri async bekleme ya da `kill` + `waitpid` ile ve zaman sınırıyla kapatılır.
     - `SIGKILL` sonrasında, öldürülen süreçlerin kaybolması için sınırlı bir reap beklemesi eklenir (en fazla 1–2 sn). Rapor, zaten öldürülmüş olanları canlı süreçlerden ayırır.
     - Testler 0,05 sn gibi dar sürelerle başarı iddia etmez.
     - Süreç başlatan testlerin her birinde zaman sınırı bulunur.
   - **Kabul:** Tam paket, eklentili komutla arka arkaya 10 kez yeşil geçer; hiçbir çalıştırma zaman sınırına takılmaz.
2. **Belirsiz `/new` sonrası durdurma yeni thread'i durdurmuyor.** `markAmbiguous` yalnızca kimlik durumunu işaretliyor (`ProviderSessionAdapters.swift:102-108`). Durdurma kancaları eski thread'e bağlı kalıyor (`CodexSessionCoordinator.swift:201-209`). Belirsiz oturum durdurulduğunda yeni thread sunucuda çalışmayı sürdürebilir ve stop yine de başarılı döner. Beklenen:
   - Aday run'lar için belirsiz thread kimlikleri saklanır.
   - Durdurmada bu thread'lerden biri aktifse stop başarılı sayılmaz. Rapor, yeni sohbetin başka bir oturuma ait olabileceğini ve hâlâ çalıştığını söyler.
   - Kabul: sentetik olay dizisi + aktif belirsiz thread durumunda stop raporu başarısız ya da doğrulanmadı olarak döner.
3. **`systemError` ya da `notLoaded` durumundaki Codex thread'i durdurulamıyor.** `stopThreadWork` yalnızca `active` ve `idle` durumlarını kabul ediyor, doğrulama da `idle` bekliyor (`CodexAppServer.swift:327-366`). Hata durumuna düşmüş bir thread'in oturumu Quit dışında hiç kapatılamaz. Beklenen:
   - Bu durumlarda aktif tur yoktur; arka plan terminalleri kapatılır, terminal sayısı 0 doğrulanır ve durdurma sürer.
   - Kabul: sentetik `systemError` ve `notLoaded` durumlarıyla stop başarılı olur ve TUI kapanır.

**Not:** Review'da düz `swift test` de bir kez derlendi ve çalıştı. Makro eklentisinin bulunamaması ortama bağlı ve ara ara görülüyor. Belgelenmiş eklentili komut kullanılmaya devam edilmeli (agents/README.md).
