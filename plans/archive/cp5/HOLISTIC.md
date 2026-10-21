# CP5 bütüncül strict review — bulgular ve düzeltme planı (2 Ekim 2026)

Kullanıcı, uzun ve parçalı geçen fazın bütünlüğünü doğrulamak için strict review ve ardından optimizer istedi. Review salt okunur yapıldı ve üç ayrık alana bölündü:
- **SR1:** sahiplik ve run kapsamları;
- **SR2:** sağlayıcı runtime'ı;
- **SR3:** terminal, arayüz, uygulama ve betikler.

Reviewer'lar bulguları izole kopyalarda probe testleriyle yeniden üretti; kaynaklar ajan raporlarındadır. Planner-reviewer belirleyici kaynakları ayrıca okudu (SR3-P1-1 başlık yolu, sözleşme §5). Optimizer bu bulgular kapandıktan sonra çalışır.

## Bulgular

**P0/P1 (kapanış engeli):**

| ID | Bulgu | Düzeltme yönü | Sahip |
| --- | --- | --- | --- |
| SR1-F1 (P0) | Kapsam modunda soy kapanışı, işaretler ve oturum seçimi coalition ile kesiştirilmiyor. Run'ın debugger'ı dış bir süreci PT_ATTACH ile ebeveynlenince Stop o süreci öldürdü (yeniden üretildi). | Kapsam modunda sinyal kümesi = Loom kapsamlarının launchd dışı üyeleri. Run seçimi bu kümeyle kesiştirilir. F11'i de kapatır. | R1 |
| SR1-F2 | Host exit durumu 1,5 sn'den geç gelirse `finish` kalıcı hata verir; Stop ve Quit hiç başarılamaz (yeniden üretildi). | Geç reap'te hata temizlenir. Kapsam modunda EXITED çerçevesi veya bağlantı kaybı beklenir. | R1 |
| SR1-F3 (güvenlik) | Run host, aynı kullanıcıdaki herhangi bir dinleyicinin SPAWN isteğini çalıştırıyor. TCC izni verildikten sonra karıştırılmış vekil (confused deputy) olur. | Host, bağlandığı tarafı audit token ile doğrular: kapsayan Loom uygulamasının designated requirement'ını sağlamalı. | R1 |
| SR1-F4 / SR3-P2-6 | Kayıtlı kapsamlar sonraki açılışta doğrulanmıyor (A6'nın ikinci yarısı yok). Run dizinleri sınırsız büyüyor (104 dizin). | Açılışta aynı boot'ta sahibi ölmüş ledger'ların kapsamları durdurulur ve doğrulanır, sonuç raporlanır. Eski dizinler budanır. | R1 API, R3 bağlantı |
| SR2-P1-1 | Codex `/new` sonrası eski kartı resume etmek, taşınan konuşmanın sunucusunu öldürüyor (yeniden üretildi). | Sunucu kimliği run kaydında tutulur. Canlı run'ın referans verdiği sunucu değiştirilmez. | R2 |
| SR2-P1-2 | Geç işlenen bitiş temizliği, aynı anahtardaki yeni sunucuyu durduruyor (yeniden üretildi). | Run başına sunucu kimliği; her kayıt bir kez sahiplenilir. | R2 |
| SR2-P1-3 | Konuşmanın kendi sunucusu ölünce o konuşma Quit dışında durdurulamıyor ve resume edilemiyor (yeniden üretildi). | Sunucu yoksa sağlayıcı temizliği yerine kapsamın boş olduğunun doğrulanması yetkili sayılır (Quit kuralıyla aynı). | R2 (+R1 API) |
| SR2-P1-4 | Codex otomatik idle, kapsamdaki çatallanmış işi görmüyor; sunucu teardown'u kullanıcının arka plan işini öldürüyor (yeniden üretildi). | Idle engel kontrolü bütün kapsamı içerir. Idle, teardown bitmeden yayınlanmaz. | R2 (+R1 API) |
| SR3-P1-1 | Claude'un ◐/◑/✳ durum simgesi başlığa kaydediliyor. Çalışırken ~1 sn'de bir SQLite yazımı ve kart yenilemesi oluyor (kaynakta doğrulandı). | Bilinen sağlayıcı durum simgeleri ayıklanır. Değişmeyen başlık yazılmaz (`title IS NOT ?`). Regresyon testi gerçek diziyle yazılır. | R2 (SessionCatalog) |
| SR3-P1-2 | Kaynak araçları run host süreçlerini saymıyor. | Kaynak havuzu ve ölçüm betikleri kapsam hostlarını ve üyelerini sayar. Okunamayan host ölçümü geçersiz kılar. | R3 |
| SR3-P1-3 | A kabulü Quit sonrası kalan fixture'ı göremiyor (`pgrep -P app`). Bildirim senaryosu ölü env değişkeni kullanıyor. | Lider kimliği veya kapsam üzerinden kontrol; `LOOM_FORCE_SCOPE_FAILURE`. | R3 |

**P2:**

| ID | Bulgu | Sahip |
| --- | --- | --- |
| SR1-F5 | `release` çatallanmış iş kalmışken EXIT gönderiyor; çağıranlar kill/release hatalarını yok sayıyor. | R1 |
| SR1-F6 | Paylaşılan kapsamda henüz bitmemiş launch'lar son run tespitinde sayılmıyor; serbest bırakma sürerken launch kabul ediliyor. | R1 |
| SR1-F7 | SPAWN cevabının süre sınırı yok. | R1 |
| SR1-F8 | Kuyruktaki gönderim, kapanmış ve yeniden kullanılmış descriptor'a yazabilir. | R1 |
| SR1-F9 | Üyelik taraması ESRCH dışındaki hatalarda süreci atlıyor; header sözleşmesine aykırı ve hatada açık kalıyor. | R1 |
| SR1-F10 | Host kaybında `reap` çıplak PID kullanıyor. | R1 |
| SR1-F12 | El sıkışmada `LOCAL_PEERPID` yerine `LOCAL_PEERTOKEN` kullanılmalı; reddedilen hello'nun descriptor'ları sızıyor. | R1 |
| SR1-F13 | `runTool` CLOEXEC_DEFAULT kullanmıyor. | R1 |
| SR1-F14 | Kapsamsız supervisor'da uygulama coalition tohumu hâlâ canlı; `useRunScopes` tekrarı; yanlış yorumlar; A1 testi tersine çevrilmedi. | R1 |
| SR1-F15 | Eksik testler: el sıkışma zaman aşımı veya taze olmayan kapsam, paylaşılan kapsam serbest bırakma hatası ve tekrarı, run ortasında host kaybı, geç exit. | R1 |
| SR2-P2-5 | Ham sağlayıcı hata metni kartta görünüyor. | R2 |
| SR2-P2-6/7 | Teardown hatası yanlış karta yayınlanıyor; başarısız başlatmadaki temizlik hatası görünmüyor. | R2 |
| SR2-P2-8 | Stop, Quit veya `/exit` ile biten konuşmalar hiç stale olmuyor (§5: stale kullanılmama süresine bağlıdır). | R2 |
| SR2-P2-9 | Ortak sunucudan kalan ölü kod: lease, acquire/release, çok-TUI yönlendirme, `codexLeases`, ortak tanılama. | R2 |
| SR2-P2-10 | İç oturum olay durumları hiç budanmıyor; kopuk Codex soketleri kalıyor. | R2 |
| SR3-P2-1 | B/C kabulünde artık hiçbir şeyi sınamayan kontroller; `hostsLeft` kontrol değil. | R3 |
| SR3-P2-2 | Başlangıç bitmeden gelen kanıt `quit` komutu uygulamayı kilitliyor. | R3 |
| SR3-P2-3 | Paket ve betik varsayılan yolları ~/Documents içinde (TCC). | R3 |
| SR3-P2-4 | `--fixture`, `--metal` ve sentetik terminal menüsü `--evidence` olmadan erişilebilir. | R3 |
| SR3-P2-5 | Quit ilerleme metni görünmeyen subtitle'a yazılıyor. | R3 |
| SR3-P2-7 | Katalog yenilemesi, okuma sırasında gelen güncellemeyi kaybedebilir. | R3 |
| SR3-P2-8 | Tekrarlanan tanılama sözlüğü; ortam uyarısı bildirimi eziyor; UI suite'lerinde kapsamlı test yok. | R3 |

**Doğrulanmadı (gerçek CLI ile sınanacak):**
- SR2-S1: aynı klasördeki etkileşimsiz thread'ler tek adaylı belirsiz eşleşmeye düşebilir.
- SR2-S2: Codex TUI içinde `/resume` ile thread değişimi `thread/started` üretmeyebilir.
- SR2-S3: Claude hook teslim hatası görünmüyor.

## Kararlar (planner-reviewer)

- **F1:** Kapsam modunda Loom yalnız kendi kapsamlarının launchd dışı üyelerine sinyal gönderir. İşaretler ve soy bilgisi yalnız run'lar arası ayrım için kullanılır, sahiplik genişletmez.
- **F3:** Host, bağlandığı tarafın kapsayan uygulamanın designated requirement'ını sağladığını doğrulamadan HELLO göndermez. Ad-hoc imzada bu cdhash eşliği, sabit imzada sertifika ve kimlik demektir.
- **F4:** Açılışta otomatik kurtarma yapılır. Hiçbir sohbet otomatik başlatılmaz; kalıntı varsa görünür olur.
- **SR3-P2-4:** Geliştirme ve fixture yolları `--evidence` arkasına alınır.
- **SR2-P2-8:** Stale, konuşmanın nasıl bittiğinden bağımsızdır (§5).

## Sahiplik

Dilimler ayrık dosyalarla yürür. Birleşik suite, paket ve native/gerçek kabul planner-reviewer'dadır.
- **R1:** CLoomPOSIX, loom-run-host, RunScope, ProcessSupervisor, OwnershipLedger, CoalitionCapability, EventDrivenPTYProcess, LaunchEnvironment, ProcessTable, loom-probe ve ilgili testler.
- **R2:** SessionRuntime, Codex*, ProviderSessionAdapters, SessionLifecycleController, SessionCatalog, SessionEventHub, ClaudeHook (görünürlük) ve ilgili testler.
- **R3:** LoomTerminal, LoomCatalogUI, loom-app, scripts ve UI/terminal testleri.

## Düzeltme sonuçları (2 Ekim 2026)

**R1 (planner):**
- F1: Kapsam modunda run seçimi coalition'ın çatallanmış üyeleriyle kesiştiriliyor. Uygulama geneli örnekleme yalnız kapsam üyeleri. F11 bununla kapandı.
- F2: Geç host exit'i sonraki denemede run'ı bitiriyor; kapsamlı run'larda reap penceresi 10 sn.
- F4: `PreviousRunRecovery` açılışta sahibi ölmüş run dizinlerinin kapsamlarını durdurup doğruluyor, temizleri budayıp kalıntıyı bildiriyor. Uygulamaya bağlandı.
- F5: `release`, çatallanmış iş varken EXIT göndermiyor. Tek seferlik yardımcıdaki temizlik hatası başarı sayılmıyor.
- F6: Uçuştaki launch kapsamın run'ı sayılıyor; run'ı olan veya serbest bırakılmakta olan kapsam reddediliyor.
- F7, F8, F10, F12, F13: SPAWN cevabına 30 sn sınır; kapanmış descriptor koruması; PID sürümüyle reap; audit token el sıkışması ve hello'daki descriptor'ların kapatılması; CLOEXEC_DEFAULT.
- F9: Tarama yalnız gitmiş, zombi veya çıkıştaki (`P_WEXIT`) süreci atlıyor. Anlık okunamayan süreç yeniden deneniyor. Churn sırasında 25 bin taramada okunamayan canlı süreç 0.
- F14: Uygulama coalition tohumlaması ledger'dan kaldırıldı; `probe` artık taramıyor. Tekrarlanan kod ve yanlış yorumlar temizlendi.
- F3 tasarım değişikliği: Güven, kapsayan uygulamanın konumundan türetilmiyor; aksi halde imzası bozulmamış bir host başka bir uygulamaya kopyalanarak TCC kimliği taşınabilirdi. Paketleme, sahip gereksinimini (`LoomOwnerRequirement`) host'un imzayla mühürlenen Info.plist'ine yazıyor. Host, bağlanan tarafı audit token ile bu gereksinime karşı doğrulamadan HELLO göndermiyor. **Gerçek koruma sabit imza kimliği gerektirir;** ad-hoc pakette yalnız Loom'un kimlik adı doğrulanabilir.
- Testler: RunScopeTests 14/14. RED gösterildi: F1 4 beklentide başarısız, F3'te hata bekleniyordu ama gelmedi; A1 için RED önceden gösterilmişti.

**R2 (implementer):**
- Kapanan bulgular: SR2-P1-1–4, REAL-1 (gerçek Claude 2.1.287 registry'sinde başlangıç `idle` damgası `startedAt`'ten önce), SR3-P1-1 başlık simgesi, P2-5/8/10.
- P2-6/7: kod düzeltildi, zorlanmış test yok.
- P2-9: kısmen; lease ve shared-server kodu kaldırıldı. Belirsizlik ve seri başlatma mekanizması birim testleri için tutuldu ve runtime'dan erişilemiyor; optimizer değerlendirecek.
- S3 açık.
- 14 suite / 158 test; RED önceki ağaçta 18 issue / 7 test.

**R3 (implementer):**
- Kapanan bulgular: SR3-P1-2/3 ve P2-1/3/4/5/7/8.
- P2-2: kod düzeltildi, RED kanıtı yok.
- UI 41, terminal 20 test. C kabulü 23 kontrol (yeni host kalıntı kontrolüyle), B 38, A ve native quit geçti.
- R3'ün koşularındaki aralıklı EIO'nun nedeni, F9 sıkılaştırmasının `P_WEXIT` düzeltmesinden önceki ara derlemesiydi.

**Birleşik suite:** F3 öncesinde 318 test geçti; F3 sonrası koşu sürüyor.

## Optimizer (CP5 kapanış incelemesi, 2 Ekim 2026)

**Kapanışı engelleyen bulgu yok.** Katmanlaşma büyük ölçüde tutarlı. Kalıntı sahiplik katmanında toplanmıştı:
- S1: eski ledger, kapsamlı ürün yolunda boşuna çalışıyordu ve `observationIssue` Quit'i boş yere başarısız sayabiliyordu.
- S2: `CoalitionCapability` artık kullanılmayan bir türdü.

Planner ikisini uyguladı. Kapsam modunda ledger gözlemi, kayıtları, ortam işi gözlemi ve `observationIssue` artık devre dışı. `CoalitionCapability` ve `ledger.coalition` kaldırıldı; eski ledger'lar çözülmeye devam ediyor. Tam suite 319/319.

**Opsiyonel (CP3 öncesi değerlendirilecek):**
- S4/S5: kapsam modunda işaret okumalarını daraltmak, idle değerlendirmesindeki çift taramayı kaldırmak.
- S6/S8: dosya bölme (`SessionRuntime+Codex`, `ProcessSupervisor` kapsam uzantısı, `AppDelegate+Evidence`).
- S7: ulaşılamayan başlatma bekleme kuyruğu. Belirsizlik eşleyicisi ise canlı ve kalmalı.
- S9: betiklerde ortak yardımcılar (`lib.sh`, `loomlib.py`).
- S10: metadata/Git okumaları; ölçülmüş maliyet yok.

**Ölçülen değerler** (mikrobenchmark, 735 süreç, medyan): süreç anlık görüntüsü 0,50 ms; tam tablo kapsam taraması 0,23 ms; 50 satır için Git branch okuması 3,3 ms. Boşta yoklama yok. Oturum başına Codex sunucusunun bellek maliyeti ölçülmedi.

## Son birleşik kabul (2 Ekim 2026)

- **REAL-2 (gerçek CLI'da bulundu):** İkinci Claude konuşmasında normal akış yine "clock is ambiguous" gösterdi. Sebebi, eşzamanlı hook yardımcılarının birkaç ms ters sırayla teslimi ve yarışan registry okumalarıydı. Düzeltme:
  - yalnız 500 ms'den büyük geri atlama veya gelecekteki damga belirsiz sayılıyor;
  - eşit veya geriye giden örnek yok sayılıyor;
  - registry durumu yalnız görülen en yeni hook'tan sonra yazıldıysa uygulanıyor.
  - Test eski davranışta başarısız (RED), yeni davranışta geçiyor. Eski bir test "geriye giden örnek = bayat" anlamına güncellendi.
- **Tam suite:** 321 test (20 + 260 + 41) geçti.
- **Son paket** (app `4ff7781e…`, run host `11ee787d…`, ad-hoc, sahip gereksinimi yalnız kimlik adı):
  - kaçak süreç Quit ve çökme kabulleri geçti;
  - C sentetik kabulü 23/23;
  - [gerçek Claude/Codex](../experiments/cp5-own-real.json) 17/17 (Claude 2, Codex 3 tur).
- **Gerçek kabulde kapanan C4 kapıları:** Claude onayının karta ulaşması; Codex'in ilk onayının karttan cevaplanması; iki sağlayıcıda gizli pencerede aktif işle Quit. OWN'da gerçek Claude arka plan işinin kapsamda kalması ve Stop ile bitmesi de doğrulandı.

## Son imzalı kabul — 3 Ekim 2026

[Sabit imza kanıtı](../experiments/cp5-stable-signing.json) ve [son native kanıt](../experiments/cp5-final-signed-native.json), 2 Ekim kapanış açıklarını kısmen kapatır. Yerel leaf kimliğiyle güçlü host owner kontrolü ve iki farklı paket arasında Belgeler TCC sürekliliği doğrulandı. Suite 322/322; OWN-A4, Quit10, çökme13, C23, gerçek Claude native No ve Reduce Motion geçti. Son paket app `0e64c4c0…`, host `aedb4389…`, fixture `b9ab6e7e…`.

Yeni kaynak/gecikme/GPU kabulü [FINAL-ACCEPTANCE](FINAL-ACCEPTANCE.md) kapsamında yürür. GPU classifier'ın ilk sayaç örneğine hazırlık maliyetini katması optimizer tarafından bulundu; hazırlık ayrı kaydedilip baseline yeniden okunarak kaynakta kapatıldı. [Son optimizer](../experiments/cp5-final-optimizer-signed.json) 43 kaynak/2000 gecikme kanıtını ham toplamlarla doğruladı; yeni engel yok. [GPU](../experiments/cp5-final-runscope-gpu.json) dört görünür hücre ve pozitif Metal calibration verdi; dört örtülü hücre, Finder drop/link dispatch ve [sayısal bütçe kararı](RESOURCE-BUDGET-PROPOSAL.md) açık. CP5 kapanmadı.


[CPU/Codex kaynak kabulü](../experiments/cp5-cpu40-source.json) ve [son ölçülen D](../experiments/cp5-cpu40-optimization.json): kare dirty işleri, Codex idle polling/deadline işleri ve yanlış başarılı onay yanıtı düzeltildi; ptrace fixture cleanup'ı ownership oracle'ları korunarak bounded yapıldı. Astra/high review ve birleşik334 geçti. D23/23 koşul geçerli, gecikme2000/timeout0 ve bütün cleanup0; yoğun CPU medyan CG%44,812 / Metal%45,455 ile %40 tavanı başarısız. [ASCII adayı](../experiments/cp5-ascii-render-optimization.json) kaynak review ve yeni birleşik334'ten geçti; imzası/runtime kazancı Mac kilidinde doğrulanmadı, kurulu D korundu. Gerçek Codex modelsiz idle/Stop ayrıştırması çalıştırılmadı. C native/GPU/uzun kanıtları tarihsel paket kapsamını korur; Finder/link/örtülüGPU4 kullanıcı tarafından ertelenmiştir. Güncel iş [FINAL-ACCEPTANCE](FINAL-ACCEPTANCE.md); CP5 açık.
