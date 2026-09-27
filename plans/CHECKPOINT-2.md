# Checkpoint 2 — Durum ve devam

**Tarih:** 27 Eylül 2026  
**Durum:** Uygulama sürüyor. S1'in oturum/çalıştırma modeli, olay tabanlı PTY omurgası ve SQLite katalog temeli doğrulandı. S1–S4 ölçümleri, sağlayıcı entegrasyonları, idle/stale ve resume uygulanmadı. Bu checkpoint'ten sonra ilk pencere gelir (sözleşme §3, checkpoint sırası).

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

- **Hook taşıma yolu:** İki aday ölçümle seçilir. Seçim ölçütleri: olay başına maliyet, Claude'u yavaşlatmama, yalnızca Loom oturumlarının yazabilmesi.
  - async `command` hook + küçük bir `loom-hook` yardımcısı → Loom'un Unix soketi.
  - `http` hook → `127.0.0.1` + oturum token'ı.
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
- **Doğrulandı:** PTY okuma ve lider çıkışı `DispatchSource` ile olay tabanlıdır. Tek okuyucu ve tek `waitpid` sahibi vardır; fd yalnız cancel handler'da kapanır. Terminal IO için run-scoped `TerminalEndpoint` supervisor actor'ını atlar. Çıktı görünürlükten bağımsız olarak sink'e itilir; varsayılan 4 MiB scrollback eski byte'ları atarak sınırlı kalır. 8 MiB'lık okunmayan burst CLI'ı durdurmadan bütünüyle işlendi.
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
