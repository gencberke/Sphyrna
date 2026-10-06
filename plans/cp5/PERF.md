# CP5 PERF — Loom ek yükü ve sağlayıcı maliyeti (3 Ekim 2026)

## Hedef ve yetki

Kullanıcı Loom'un olabildiğince hafif olmasını, Claude/Codex oturumlarını takip ederken ek yük getirmemesini ve mümkünse CLI'ların kendi maliyetinin de azaltılmasını istedi; yol haritası çıkarılıp ilerlenecek. Bu slice [son kabulün](FINAL-ACCEPTANCE.md) açık CPU40 kapısını ve gerçek Codex idle/Stop ölçümünü içine alır; sözleşme §3 mimarisi (run kapsamı, oturum başına Codex app-server, gerçek CLI deneyimi) değişmez. Optimizer için kullanıcı bu oturumda **Opus 5.5 / xhigh** kullanımına izin verdi. Commit/push/PR yetkisi yok.

## Başlangıç bulguları

[Profil kanıtı](../experiments/cp5-perf-profile.json) (kurulu D, görünür 1 MiB/sn CG, tek koşu, tanımlayıcı):

- App CPU'sunun büyük kısmı **çizim**: her karede görünür bütün satırlar için `SnapshotTextBuilder.buildAttributedString` + `CTLineCreateWithAttributedString` + CG rasterizasyonu ≈ 18 / ~27 puan. Motor feed'i ≈ 1,5 puan; PTY okuma yolu küçük. 1 MiB/sn'de her karede bütün ızgara yeni içerik olduğundan satır önbelleği tek başına yetmez.
- Fixture'ın ~%12'si büyük ölçüde kendi Swift string biçimlendirmesi (user 2,98 sn / system 0,45 sn); PTY çekirdek maliyeti değil. CPU40 tanımı app + fixture + kapsam toplamıdır; fixture değiştirilmez (aşağıdaki karar noktası).
- Codex takibi: Loom'un app-server bağlantısı `optOutNotificationMethods` kullanmıyor; Codex 0.160 bunu bağlantı başına destekliyor. Loom yalnız durum/tur/onay/kapanış olaylarını işlerken her token/komut çıktısı delta'sını JSON olarak alıp çözüyor. `readThread` son tur için `includeTurns: true` ile bütün geçmişi okuyor; `thread/turns/list` (`limit`, varsayılan azalan sıra) mevcut.
- Claude takibi: 7 hook olayı (tool başına hook yok) her olayda Foundation/LoomCore'a bağlı `loom-hook` sürecini başlatır; `UserPromptSubmit` senkron olduğu için gönderim gecikmesine eklenir. Maliyeti ölçülmedi. Registry izleme vnode olayıyla çalışır, yoklama yok.
- PTY okuma her ~1 KiB okumada 16 KiB sıfırlanmış dizi ayırıp `Data`'ya tekrar kopyalıyor.

## Yol haritası ve sahiplik

| ID | İş | Sahip / yazma alanı | Durum |
| --- | --- | --- | --- |
| P1 | Basit hücre koşuları (tek genişlik ASCII, birleşik/varyasyon/bidi/fallback yok) için `NSAttributedString`/`CTLine` atlayan doğrudan glyph yolu; satır başı geçici nesne/renk kopyalarını kaldırma. Basit olmayan koşular mevcut yoldan geçer. CG ve paylaşılan builder üzerinden Metal. ASCII guard adayı bu pakete dahildir. | Implementer R: `Vendor/SwiftTerm/Sources/SwiftTerm/Apple/*`, yeni `patches/swiftterm-*.patch`, `Vendor/SwiftTerm/LOOM-VENDOR.md`, `Tests/LoomTerminalTests/*` | implementasyon |
| P2 | PTY okuma tamponunu yeniden kullan; okuma başına sıfırlama ve çift kopya yok. | Implementer R: `Sources/LoomCore/EventDrivenPTYProcess.swift` | implementasyon |
| T1 | Loom'un Codex bağlantısında kullanılmayan yüksek frekanslı bildirimleri `optOutNotificationMethods` ile kapat; işlenen olaylar ve sunucu istekleri (onaylar) korunur. TUI bağlantısı etkilenmez. | Implementer C: `Sources/LoomCore/CodexAppServer.swift`, gerekirse `CodexSessionState.swift`, `Sources/loom-fake-provider/CodexFixture.swift`, ilgili `Tests/LoomCoreTests/*Codex*` | implementasyon |
| T2 | Son tur için bütün geçmiş yerine `thread/turns/list` `limit: 1`; yeni/boş thread davranışı ve son asistan mesajı korunur. | Implementer C (T1 ile aynı alan) | implementasyon |
| M1 | Birleşik build/test, sabit imzalı paket (E `c7815294…`), CPU40 beşer CG/Metal + etkilenen gecikme/gizli/çevrim; gerçek Codex modelsiz idle/Stop: native TUI ile Loom (remote TUI + app-server + Loom) ayrımı; T1 öncesi/sonrası Loom'a gelen bildirim sayısı. | Planner-reviewer | bekliyor |
| T3 | Claude hook başına CPU/duvar süresi ölçümü; anlamlıysa Foundation'sız küçük helper. | Ölçüm sonrası karar | bekliyor |
| C1 | Sağlayıcı tarafı ayarlar (animasyon, güncelleme kontrolü, kullanılmayan özellik süreçleri) için gerçek CLI maliyet ölçümü ve etki listesi. CLI davranışını değiştiren her ayar kullanıcı kararıdır. | Planner-reviewer ölçer, kullanıcı karar verir | bekliyor |
| Z | Checkpoint optimizer (Opus 5.5 / xhigh), kalan bütçe kararları, belge uzlaştırması | Planner-reviewer | bekliyor |

R ve C aynı çalışma ağacını paylaşır; ayrı `--scratch-path` kullanırlar ve birbirlerinin dosyalarına dokunmazlar. Birleşik kontrolün sahibi planner-reviewer'dır.

## Kabul ölçütleri

- **PERF-1:** Sabit imzalı yeni pakette beşer görünür CG ve Metal 1 MiB/sn koşusunun her biri toplam CPU ≤%40; ~60 draw/sn, byte/SHA/footer oracle'ları, gizli çizim 0, 100 çevrim ve temizlik korunur; gecikme p95 ≤100 ms / timeout 0. App-only medyanlar D ile mutlak birimle ayrı raporlanır.
- **PERF-2:** Basit yol ile eski yolun aynı satırlar için piksel eşdeğerliği (renk, kalın/italik, alt çizgi, seçim, imleç, ters video, geniş/birleşik karakter sınırı) testle gösterilir; basit olmayan içerik eski yoldan geçer.
- **PERF-3:** Loom'un Codex bağlantısı kapatılan yöntemleri almaz; durum, tur, onay, hata ve kapanış davranışı mevcut testlerde ve gerçek Codex kısa turunda korunur; gelen mesaj sayısı öncesi/sonrası kaydedilir.
- **PERF-4:** Gerçek Codex modelsiz idle/Stop'ta native TUI ile Loom yolunun CPU/footprint farkı ayrı bileşenlerle kayıtlıdır; Stop sonrası kapsam kalıntısı 0.
- **PERF-5:** Claude hook olay başı maliyeti ölçülmüştür; değişiklik yapılırsa öncesi/sonrası aynı yöntemle.

## Karar noktaları

- Fixture'ın kendi string üretimi CPU40 toplamının ~%11'i. Varsayılan: ölçüm tanımı değişmez, Loom'un kendi yükü düşürülür. P1 sonrası tavan hâlâ aşılırsa fixture'ı aynı byte akışını daha ucuz üretecek hale getirmek ölçüm tanımı değişikliğidir ve kullanıcıya sorulur.
- CLI davranışını değiştiren sağlayıcı ayarları (C1) ölçümle birlikte kullanıcıya sunulur; kendiliğinden uygulanmaz.

## Sonuçlar

**T1/T2 kaynak kabulü (doğrulandı).** Ürün bağlantısı 28 yüksek frekanslı/kullanılmayan bildirimi `optOutNotificationMethods` ile kapatır; probe/diagnostics bağlantıları her şeyi almaya devam eder. Son tur `thread/turns/list` `limit:1` ile okunur; durum ayrı history'siz `thread/read` ile, iki okuma çelişirse bir kez tekrar. Gerçek Codex 0.160: tek tur 31→24 çerçeve / 15 090→12 401 bayt; düz+onay iki tur 78→33 / 31 355→16 354; durum/tur/onay sırası ve son mesaj aynı; bilinmeyen adlar initialize'ı bozmaz. Yüklenmemiş kalıcı thread ve bilinmeyen thread'de davranış eskisiyle aynı. 6 model turu. [Kanıt](../experiments/cp5-perf-codex-observer.json). Gözlem PERF-O1 (önceden var, PERF dışı): gerçek Codex bilinmeyen thread için "thread not loaded" der; Stop'taki `isThreadNotFound` yalnız "not found" tanır, bu nedenle o durumda Stop başarı yerine görünür hata verir. Güvenli taraf; değiştirilmedi.

**P1/P2 kaynak kabulü (doğrulandı).** CG renderer'da basit ASCII hücre koşuları önbellekli glyph ID'leriyle `CTFontDrawGlyphs` üzerinden çizilir; font ilk kullanımda CoreText şekillendirme probe'undan geçmezse (ligatür vb.) bütün hücreler eski yoldan gider. Piksel testleri 2x bitmap'te bayt-bayt eşit (13 karşılaştırma; kasıtlı 0,5 pt kaydırma hepsini düşürdü). Release mikro ölçüm, 45×150 tam yeni ızgara: kare başı çizim 2,294 → 0,888 ms medyan (7 tekrar). PTY okuma tamponu yeniden kullanılır, okuma başına tek kopya. Yama `patches/swiftterm-direct-glyph-runs.patch`. Metal yalnız `--metal` geliştirme/kanıt modunda açılır, ürün CG kullanır; Metal'e aynı yol sınırlı bir değişiklik değildir ve ertelendi (PERF-M).

**Birleşik suite:** release 29 + 273 + 41 = 343/343 geçti (log: probe alanında `runs/cp5-perf-20261003/combined-suite.log`).

**T3 kapandı, kod değişikliği yok.** Claude hook olay başı ~3,8 ms CPU / ~6 ms duvar, geçici 6,5 MiB; normal tur iki olay. [Kanıt](../experiments/cp5-perf-claude-hook.json).

**PERF-4 sağlayıcı tarafı (doğrulandı, Loom uygulaması bağlı değil).** Modelsiz idle, beşer dönüşümlü tekrar, 60 sn: native varsayılan (paylaşılan daemon + güncelleyici) 3 süreç / 395 MiB / %0,31; `--no-daemon` 1 süreç / 119 MiB / %0,37; Loom yolu (app-server + remote TUI) 2 süreç / 156 MiB / %0,22 medyan. Loom yolu `--no-daemon`'a göre +37 MiB ve açılışta +0,68 CPU-sn; native varsayılana göre −239 MiB (daemon sonraki native oturumlarca paylaşılır). Her Codex açılışı 29,2 MB'lık uzak plugin kataloğu önbelleğini baştan yazar; açılıştan sonraki ~20 sn CPU kuyruğu %3–4. [Kanıt](../experiments/cp5-perf-codex-idle.json). Loom gözlemcisinin app tarafı ve uygulama içinden Stop, imzalı paket ölçümünde kalır.

**PERF-1 ara sonuç (başarısız, kısmi matris).** Paket E sabit kimlikle imzalı. Terminal penceresi küçültülerek Loom penceresi örtülmeden ölçüldü; önce örtülü/etkin olmayan pencereyle yapılan iki deneme geçersiz sayıldı. CG görünür 1 MiB/sn beş koşu: app %24,7–29,0 (medyan 27,4; D 31,5), toplam %37,6–42,2 (medyan 40,4; D 44,8). Yalnız bir koşu ≤%40. Metal dört geçerli koşu toplam %46,6–48,5 (hızlı yol yok); beşinci Metal hücresinde pencere görünür olmadığından matris durdu. Koşular ilerledikçe toplamın yükselmesi fansız makinede ısınmayı düşündürür, ölçülmedi. [Kanıt](../experiments/cp5-perf-cpu40-e-partial.json).

E profili: çizim ana thread'de 1152→230 örneğe indi. Kalan en büyük app maliyeti Core Animation'ın asenkron CG kuyruğunda glyph başına sınır kutusu için glyph path kopyalanması (`DrawGlyphs::compute_dod_ → CopyGlyphPath`, ~3,8 puan). Sıradaki iş **P1b**: terminal katmanını piksel-eşdeğer biçimde senkron çizmek ya da bu maliyetin tetikleyicisini kaldırmak; uygulama içi A/B ile ölçülür (implementer R).

**PERF-1 son matris (paket F, 23/23 geçerli; CPU40 başarısız).** F = P1 + P1b (boşluk glyph'leri kaydedilmez) + P1c (açık koşu devamı) + P2 + T1/T2; app `0e1803b6…`. CG görünür 1 MiB/sn beş koşu: app %25,7–27,2 (medyan **26,3**; D 31,5), fixture medyan 14,6 (D 12,3), toplam %40,5–41,5 (medyan 40,9; D 44,8) — hiçbiri ≤%40. Metal (yalnız geliştirme) toplam medyan 48,6. Gizli yoğun: toplam 25,3, çizim 0. Boş görünür: %0,14 / 25,7 MiB. 100 çevrim geçti. Gecikme 10×200, timeout 0, p95 CG 17,9–18,4 / Metal 18,3–18,8 ms. Peak footprint CG 115,3 MiB. Okuma düzeni D/E/F'de aynı (1099 okuma/sn, 954 B); fixture'ın artışı tamamen kendi user süresinde (10,7→12,8) ve Metal'de de var: oturumlar arası makine sapması, Loom etkisi değil. [Kanıt](../experiments/cp5-perf-cpu40.json).

Karar noktası (kullanıcı): toplamın ~%14'ü fixture'ın kendi string üretimi. (a) Tanım korunur, Loom'da sonraki sınırlı hedeflere devam edilir; (b) fixture aynı bayt akışını önceden hazırlanmış tampondan üretir (byte/SHA oracle aynı), %40 toplam tavanı korunur ve Loom app CPU'su ayrıca raporlanır. Bu bir ölçüm tanımı değişikliğidir.

**Kullanıcı kararı (3 Ekim 2026): "ikisini birden".** %40 toplam tavanı korunur. Fixture aynı bayt akışını aynı write boyutları ve zamanlamayla, string biçimlendirmesi olmadan üretir (byte/SHA oracle aynı); Loom app CPU'su ayrıca raporlanır, sayısal app tavanı önerisi (≤%30) onaysızdır. Loom'da sınırlı iyileştirmeler sürer; tek son matrisle ölçülür.

Ölçüm notu: aynı paket F tek soğuk koşuda app %18,3 / toplam %33,0 (örnekleme dahil), ardışık matriste %26,3 / %40,9 verdi; fansız Mac14,2'de ısıl durum sonucu belirgin değiştiriyor (`pmset` uyarı kaydı yok; doğrudan frekans ölçülmedi). Son matris: ağır hücreler öncesi sabit soğuma aralığı ve D ile dönüşümlü CG koşuları. D kendi eski fixture'ını taşır; D–yeni karşılaştırması app CPU'su üzerinden yapılır.

| ID | İş | Sahip | Durum |
| --- | --- | --- | --- |
| F-fix | `loom-test-child` stream üretimini string biçimlendirmesiz yap; write çağrı boyutları/zamanlaması ve baytlar birebir aynı. `cp5-d-measure.py`'ye spinner benzeri kısmi güncelleme senaryosu ekle (mevcut senaryolar değişmez). | Implementer F: `Sources/loom-test-child/main.swift`, `scripts/cp5-d-measure.py`, evidence bağlantısı için `Sources/loom-app/EvidenceResourcePool.swift` / `DevelopmentEvidence.swift` | bekliyor (duraklatıldı) |
| P3 | CG görünümünde yalnız değişen satırları geçersiz say ve çiz (dirtyRect dışındaki satırları atla); tam/kısmi çizimin son pikselleri eşit. | Implementer R: `Vendor/SwiftTerm/...`, yeni yama, `Tests/LoomTerminalTests` | bekliyor (duraklatıldı) |

## Kaldığımız yer (3 Ekim 2026, kullanıcı isteğiyle duraklatıldı)

Durum: F-fix ve P3 görevlendirilmişti, değişiklik yapılmadan durduruldu; ağaçta yarım iş yok (paket F girdileri freeze ile aynı). Kaynak kabulleri: P1, P1b, P1c, P2, T1/T2 ve PERF-R1 test düzeltmesi. Son birleşik release suite'te tek başarısızlık PERF-R1 idi (macOS ONLCR'nin yük altında `\r` çiftlemesi, Python ile bağımsız 4/40 yeniden üretildi); düzeltilmiş testten sonra tam suite yeniden koşulmadı.

Paketler (sabit `Loom Dev Code Signing` kimliği): D `8318fa10…` (`packages/cp5-D-before-perf`), E `c7815294…` (`packages/cp5-E-perf`), **F `0e1803b6…` kurulu**. `packages/perf-sync-candidate` P1b A/B adayıdır; `packages/perf-p1c-candidate` imzası yarım kaldığından kullanılamaz.

Sıradaki adımlar:
1. **F-fix** (yeni implementer): `runStream` aynı baytları, aynı write boyutlarıyla (≈10 KiB tick, kesme ve footer aynı) ve aynı zamanlamayla bayt düzeyinde üretir; eski/yeni stdout ve write sınırları birebir karşılaştırılır; ≥30 sn bağımsız CPU ölçümü. Spinner senaryosu (`spinner1`): 30 Hz, alttaki ~6 satırlık dinamik bölge yerinde yeniden yazılır, scrollback büyümez, bağımsız SHA/footer oracle'ı; mevcut senaryolar değişmez. Kurulu pakete ve GUI ölçümüne dokunmaz.
2. **P3** (R; yeni oturumda bağlam brief'le verilir): CG'de yalnız değişen satır dikdörtgenlerini geçersiz say, dirtyRect dışını çizme; scroll/resize/font/seçim/görsel/çift genişlik-yükseklik/senkron çıktıda tam geçersizleme. Kabul: güncelleme dizisi sonrası kısmi/tam çizim bitmap eşitliği, tek satır güncellemede beklenen kirli bölge, kasıtlı eksik geçersizleme testi düşürür; katman-tabanlı NSView'in kirli dikdörtgen dışını koruduğuna kanıt; 6 satır güncelleme mikro ölçümü; Metal'e dokunulmaz.
3. **Birleşik kontroller** (planner-reviewer): release tam suite, yeni imzalı paket G.
4. **Son matris**: mevcut 23 hücre + `spinner1` + D ile dönüşümlü beş CG yoğun koşu; her ağır hücre öncesi sabit soğuma aralığı (öneri 90–120 sn). Koşullar: Terminal pencereleri `tell application "Terminal" to set miniaturized …` ile küçültülür (System Events kullanma: otomasyon izni bekler), `caffeinate -u` döngüsü ekran kilidini engeller, ölçüm sırasında build/test yok. Bu yöntemle CPU40, app CPU'su (D'ye karşı) ve spinner maliyeti raporlanır.
5. Paket G ile Codex'in uygulama içinden gözlemci maliyeti ve Stop; ardından optimizer (Opus 5.5 / xhigh) ve C1 sağlayıcı ayarları (ör. Codex'in her açılışta 29 MB katalog yazması) kullanıcıya sunulur.

Açık kullanıcı kararları: app CPU tavanı önerisi ≤%30 (onaysız); diğer sayısal bütçeler; Metal hızlı yolu (yalnız geliştirme renderer'ı, ertelendi).

## Kullanıcı kararı: Codex geliştirmesi duraklatıldı (4 Ekim 2026)

Codex tarafındaki geliştirme duraklatıldı; odak Claude. Gerçek sağlayıcıyla yapılan testler Claude üzerinden sürer. [Kaldığımız yer](#kaldığımız-yer-3-ekim-2026-kullanıcı-isteğiyle-duraklatıldı) listesine etkisi:

- Sağlayıcıdan bağımsız terminal işleri değişmez: F-fix, P3, birleşik kontroller, paket G ve son CPU40 matrisi.
- 5. adımın Codex kısmı ertelendi: uygulama içi gözlemci maliyeti, uygulama içinden Stop (PERF-4'ün app tarafı), Codex için C1 ayarları ve PERF-O1. Bu ölçümler paket G'de Claude ile yapılır (gözlemci maliyeti ve Stop); C1, Claude CLI ayarlarına yöneltilir.
- Mevcut Codex kabulleri (T1/T2, sağlayıcı tarafı PERF-4, C kabulü) ve Codex kodu korunur. Mevcut testler suite'te kalır; Codex için yeni gerçek model turu çalıştırılmaz.
- CP5 kapanışının ertelenen Codex maddeleri olmadan nasıl kapanacağı, kapanış aşamasında kullanıcıya sunulur.

## Kullanıcı kararı: ağır testler sona (4 Ekim 2026)

Laptop ısınması ve pil tüketimi nedeniyle geliştirme sırasında ağır test/ölçüm yapılmaz. Implementer'lar yalnız build, `git diff --check` ve birkaç saniyelik dar testler çalıştırır; planner-reviewer review'u bu kanıtla ve kod incelemesiyle yapar, kabul "kaynak review" düzeyinde kalır. Ertelenen her kontrol tek bir **son büyük teste** toplanır: F-fix CPU ve tam boy eşitlik karşılaştırmaları, P3 mikro ölçümü, release tam suite, paket G, son CPU40 matrisi ve Claude ile app tarafı gözlemci/Stop ölçümü. Geliştirmeler bitince planner-reviewer listeyi hazırlayıp kullanıcıya bildirir; testi kullanıcı başlatır.

**F-fix kaynak kabulü (4 Ekim 2026; doğrulandı: kod + hafif kontroller, ağır kısım son teste).** `stream` tek 64 baytlık kayıt şablonunu yerinde ondalık sayaçla tekrar kullanır; tick boyutu kuralı, son kayıt kesmesi, pacing, footer ve burst aynıdır. Eski/yeni payload SHA ve `write(2)` boyut dizisi (`DYLD_INSERT_LIBRARIES` interposer) beş küçük vakada birebir aynı. `spinner <fps> <frames>`: 200 statik satır, altta 5 satırlık dinamik bölge her karede `\r ESC[4A` + `ESC[2K` ile yerinde yazılır; 7 satır ayrıldığı için kare ve footer alt satırda LF üretmez (≥7 satırlık ekranda kaydırma yok). Uygulamada yeni `openspinner` işlemi; mevcut `open` ve senaryolar değişmedi; `spinner1` oracle'ı ve self-test eklendi. `spinner 30 120` doğrudan: SHA/bayt/footer oracle ile aynı, ~30 Hz. Planner-reviewer self-test ve diff check'i bağımsız tekrarladı. [Kanıt](../experiments/cp5-perf-fixture-fix.json). Son teste kalan: tam boy (≥20 MiB) eşitlik, ≥30 sn CPU karşılaştırması, uzun koşuda 30 Hz, paketli uygulamada `spinner1`.

**P3 kaynak kabulü (4 Ekim 2026; doğrulandı: kod + dar testler, ölçüm son teste).** CG artık yalnız snapshot'ta içeriği, bidi düzeni veya görseli değişen satırların aralığını (+1 satır alt pay) geçersiz sayar ve çizer. Değişiklik tespiti satır kimliği + `generation` ile yapılır; snapshot önbelleğinin kullandığı yöntemle aynıdır, bu yüzden yeni bir bayat içerik yolu açmaz. Yalnız imleç hareketi çizim yapmaz (caret ayrı view). Tam çizim tetikleyicileri: yDisp/boyut/buffer değişimi, scrollback'te gezinme, resize, herhangi bir stil değişikliği (seçim, link, blink, palet), bidi girdisi, çift boy satır, görsel/Kitty yerleşimi ve kaybolduğu kare, senkron çıktı sonrası ilk kare. Terminal update range artık yalnız erişilebilirlik için kullanılır. Testler: artımlı çizim ile tam çizim bitmap'i bayt-bayt aynı; tek satır güncellemede beklenen bölge; atlanan satır testi düşürür (known issue, 3260 bayt fark); gerçek pencerede AppKit kısmi rect verir ve dokunulmayan satırlar korunur (WindowServer kompozitinde kanal başına ≤1 yuvarlama farkı; capture yoksa test başarısız olur, sessiz geçmez). `TerminalDirectGlyphTests` + yeni testler 9/9 (1 beklenen known issue). Yama `patches/swiftterm-partial-row-invalidation.patch` (LOOM-VENDOR madde 10). Bilinen ödünler: bölge tek dikdörtgendir (ayrık satırlar arası da çizilir); blink içeren ekranda her yanıp sönme tam çizimdir. [Kanıt](../experiments/cp5-perf-p3-partial-draw.json).

## Son büyük test (geliştirmeler bitti; kullanıcı başlatacak)

Ağır kontrollerin tamamı burada toplandı. Koşullar: ekran kilitsiz, adaptör takılı, ölçüm sırasında başka build/test yok, Terminal pencereleri `tell application "Terminal" to set miniaturized …` ile küçültülmüş, `caffeinate -u` açık. Codex ölçümleri 4 Ekim kararıyla kapsam dışıdır.

1. **Birleşik release suite** (planner-reviewer): tam suite tek koşu. PERF-R1 düzeltmesi ve yeni P3 pencere testi dahil; P3 pencere testi ekran kilitliyken başarısız olur.
2. **Dar ağır kontroller:** F-fix tam boy eşitlik `bash /tmp/ffix/cmp.sh` (8 vaka, ≥20 MiB; `/tmp/ffix-old` ve interposer gerekir, silinmişse kanıt dosyasındaki yöntemle yeniden kurulur); fixture CPU eski/yeni ≥30 sn × 5 dönüşümlü (kanıt dosyasındaki komut); P3 mikro ölçüm `LOOM_RENDER_BENCH=1 swift test -c release … --filter TerminalPartialDrawTests/partialDrawCostBenchmark`.
3. **Paket G:** `scripts/package-dev-app.sh`, sabit `Loom Dev Code Signing` kimliği, deep-strict imza doğrulaması, SHA kaydı.
4. **Son CPU40 matrisi:** paket F'nin 23 hücresi + `spinner1`; CG yoğun beş koşu D ile dönüşümlü, her ağır hücre öncesi 90–120 sn soğuma. Raporlanan: CPU40 toplamı, app CPU'su (D'ye karşı), spinner maliyeti, gecikme p95, gizli çizim 0, 100 çevrim, temizlik.
5. **Claude, paket G içinde:** gerçek Claude oturumunda app tarafı gözlemci maliyeti (idle ve kısa tur), uygulama içinden Stop ve kapsam kalıntısı 0; Claude CLI ayar adaylarının (animasyon, güncelleme kontrolü vb.) maliyet ölçümü (C1). Ayar değişiklikleri kullanıcı kararıdır. Kısa model turları izinlidir.
6. Ardından checkpoint optimizer'ı (henüz yapılmadıysa) ve kapanış kararları: app CPU tavanı önerisi ≤%30, diğer bütçeler, ertelenen Codex maddeleri.

**Paket G (5 Ekim 2026, kullanıcının elle denemesi için).** F, `packages/cp5-F-perf` altına arşivlendi (app `0e1803b6…`, deep-strict doğrulandı). G = F + F-fix + P3; sabit `Loom Dev Code Signing` kimliği, deep-strict doğrulandı; app `0a04e429…`, hook `4444ac77…`, fixture `75672faf…`. Optimizer kodu değiştirirse son test öncesi yeniden paketlenir.

### Son büyük test eki (5 Ekim 2026; UI ve optimizer düzeltmeleri sonrası)

Kullanıcı 5 Ekim'de testi onayladı. Paket öncesi kullanıcının kurulu Loom Dev'i kapatılır (paket betiği çalışan hedefi reddeder). Mevcut 1–6 maddelerine ek olarak:

- **Gösterge maliyeti (R1):** çıktı üretmeyen çalışan oturumla (sahte sağlayıcı `busy` ya da uzun Claude turu) 60 sn × 5: app CPU ve `packageIdleWakeups`; animasyonlu vs Hareketi Azalt, N=1 vs N=3, sidebar kapalı, satır görünüm dışında, pencere etkin değil (B1: durağan olmalı).
- **Gizli terminal (F4):** gizli stream1 hücresinde app CPU ve uyanmalar D/F ile karşılaştırılır; gizle→aç son ekranı korur.
- **Idle döngüsü (F2):** kalıcı alt süreçli (MCP benzeri) çalışan oturumda 10 dk boyunca değerlendirme sayısı geri çekilmeyle uyumlu.
- **P3 ek senaryosu:** akış sürerken oturum değiştirme ve Cmd+W/yeniden açma sonrası bayat satır yok.
- **Renk:** gerçek Claude oturumunda `COLORTERM=truecolor` ile turuncu/diff renkleri.
- **Evidence izolasyonu (F1):** bütün koşular boyunca varsayılan katalog boyut/mtime değişmez.
- **Kullanıcı kontrol listesi (gerçek pencere):** sidebar düğmesinde mavi dolgu yok; cam üzerinde mavi parlama yok; trafik ışıkları hover/tıklama ve başlık düğmeleri çalışıyor; proje görünümünde kartta proje adı yok; dikkat noktası; durum göstergeleri; terminal renkleri.

## Son büyük test sonuçları (6 Ekim 2026, paket H)

Paket H = G + UI turu + optimizer düzeltmeleri (app `ac0e3881…`; G `packages/cp5-G-perf` arşivde). Birleşik release suite 373/373 (UI.md). Matris 22/22 geçerli, D karşılaştırması eski paketin global komut kanalı için yalnız kanal adı değiştirilmiş betik kopyasıyla ([özet](../experiments/cp5-final-matrix-20261006.json); probe `runs/cp5-final-20261006/`).

- **PERF-1 / CPU40 (CG): geçti.** H görünür 1 MiB/sn beş koşu toplam %26,7–27,1 (medyan 26,8); app medyan **25,4** (D dönüşümlü 31,9; −6,5 puan); fixture 14,0 → 1,5 (F-fix). Metal çalıştırılmadı (yalnız geliştirme renderer'ı, PERF-M ertelendi).
- **Gizli akış (F4):** app 9,2 → 4,2 (D → H, tek koşu).
- **Boş görünür:** %0,08. **Gecikme:** p95 18,8–19,7 ms, 1000 örnek, timeout 0. **100 çevrim:** geçti.
- **spinner1:** app %17,8–18,4 (≈30 çizim/sn, kare başı ~6 ms) — kısmi çizimin beklenen kazancını göstermiyor; P3-S olarak incelemede.
- **Gösterge (R1): kusur bulundu.** Pencere etkin, oturum Working, sidebar açıkken bile app CPU %0,003–0,017, 0,33 kesme uyanması/sn ve ana thread örneğinde `TimelineView`/`Canvas` yok: çalışıyor göstergesi gerçek uygulamada dönmüyor (testler yalnız predicate'i sınıyordu). UA-5 olarak düzeltiliyor; maliyet düzeltme sonrası yeniden ölçülecek.
- Henüz koşulmadı: gerçek Claude kontrolü (betik hazır: `claude_real.py`), P3 akış sırasında oturum değiştirme senaryosu (kullanıcı kontrol listesine).

**P3-S (6 Ekim).** Spinner maliyetinin nedeni tam çizim değil: kısmi bölge zaten 6 satırdı. (1) Sabit satırlar her karede `ESC[2K`+aynı metinle yeniden yazıldığından generation değişip "değişti" sayılıyordu; `BufferLine.snapshotRendersLike` ile hücreleri/genişliği/bayrakları aynı satır snapshot kopyasını korur (grapheme/hyperlink satırları hariç), tek satırlık bidi paragrafı yeni revizyonu benimser. (2) Kutu çizimi hücre başına NSColor→CGColor dönüşümü yapıyordu; renk koşu başına bir kez dönüştürülür. Uygulama içi: çizim 0,570 → 0,348 ms/kare, bölge kararlı durumda 2–3 satır. Paketli spinner1 (dönüşümlü, kendi kopyaları): app %15,5/15,3/14,6 → %12,3/11,7/12,2. Kalan maliyetin çoğu Core Animation commit/backing store; alt bölgeyi ayrı katmana ayırmak katman yapısı değişikliği olduğundan kararlı sürüm sonrasına ertelendi. Yama `patches/swiftterm-identical-row-skip.patch`. [Kanıt](../experiments/cp5-perf-p3s-spinner.json).

## Son paket doğrulaması (6 Ekim 2026, paket I)

Paket I = H + UA-5/UA-6 (render sunucusu göstergesi) + P3-S (aynı satır atlama). Release suite 377/377 ([UI kaydı](UI.md#sonuçlar)). Kısa matris 9/9 geçerli, 90 sn soğuma, CG ([özet](../experiments/cp5-final-matrix-I-20261006.json); probe `runs/cp5-final2-20261006/`).

- **stream1 görünür:** app %23,8–24,0, toplam %25,4–25,6 (H: app medyan 25,4, toplam 26,8). CPU40 korunuyor.
- **spinner1:** app %12,6–14,7 (H: %17,8–18,4); P3-S kazancı paketli ölçümde de görünüyor.
- **Gizli akış:** app %3,5 (H 4,2). **Gecikme:** p95 20,0–20,6 ms, 200 örnek, timeout 0 (H 18,8–19,7 ms / 1000 örnek; fark gürültü düzeyinde).
- **Gösterge (R1 kapandı):** sistem Hareketi Azalt açıkken pencere etkin + sidebar açık: 2/2 gösterge dönüyor, app %0,003–0,008, boşta uyanma ≈0. Pasif pencerede animasyon 0/2, %0,013. Üç Working oturum %0,007.
- **Gerçek Claude:** 11/11 kontrol, 2 kısa tur: yanıt transcript'te, gösterge State unknown → Working → Ready, onay kartı, arka plan işi kapsamda, Stop kapsamı boşalttı, normal Quit sahip süreç bırakmadı, dışarıdaki süreç korundu. Tek Claude açıkken boşta gözlemci maliyeti app %0,044. `colortermTruecolor` kontrolü her Claude sürecine bakıyor; asıl kanıt `LaunchEnvironmentTests`.
- Betik düzeltmeleri (yalnız probe): 1 sn'lik tur gönderim kontrolünü kaçırıyordu, gönderim artık sağlayıcı transcript'inden kanıtlanıyor; `rusage_info_v2` ctypes yapısında iki alan eksikti (Python segfault). Çöken denemede kalan evidence uygulaması normal Quit ile kapandı, sahip süreç kalmadı.
- Varsayılan katalog boyut/mtime değişmedi.
