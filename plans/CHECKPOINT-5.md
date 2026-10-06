# Checkpoint 5 — Terminal motoru ve ilk pencere

> **CLOSED (6 Oct 2026) by user decision — [closure record](cp5/CLOSURE.md#cp5-closure-6-oct-2026), Codex-only items in the [Codex backlog](cp5/CODEX-BACKLOG.md).**
>
> **Current state (6 Oct 2026, English summary; the Turkish text below is the original map and some of its status cells are older).**
> - All slices are implemented. Package I is verified: release suite 377/377 (one intended known issue), CPU40 passed (stream1 app ~24 %, total ~25.5 %), spinner1 12.6–14.7 %, hidden stream 3.5 %, p95 ~20 ms, working indicator ≈0.005 %, real Claude check 11/11 ([PERF](cp5/PERF.md#son-paket-doğrulaması-6-ekim-2026-paket-i), [UI](cp5/UI.md#sonuçlar)). The PERF row below ("CPU40 still failing", "P3 next") and the D/A rows citing D23 are superseded by these results.
> - A UI slice ([cp5/UI.md](cp5/UI.md)) ran on 5–6 Oct from user feedback; it is not in the slice table below.
> - Codex development is paused since 4 Oct and Codex is not in the first production release ([D-08, D-14](../DECISIONS.md)); Codex-only acceptance items moved to the [Codex backlog](cp5/CODEX-BACKLOG.md) at closure (D-23).
> - Optimizer passes 1–3 are done; pass 3 found no closing blockers ([CLOSURE](cp5/CLOSURE.md)).
> - At closure: O-02 resolved (Codex items to the backlog); O-01 budgets moved to stage R; R-A moved to stage I.

Güncel iş konumu [STATUS.md](../STATUS.md), birleşik kabul ve revizyonlar [kapanış kaydındadır](cp5/CLOSURE.md). Bu belge checkpoint hedefi, kabul ölçütleri ve açık işlerin haritasıdır; tur raporları buraya eklenmez.

## Hedef ve kapsam

CP2 çekirdeğini korunmuş tasarım içinde gerçek Claude/Codex terminalleriyle kullanılabilir hale getirmek: proje/projesiz sohbet, proje/aktivite görünümü, arama, yeniden adlandırma, durum göstergeleri, yeni/devam/durdur ve temel terminal kullanımı. macOS 27+; Cmd+W pencereyi kapatır, Cmd+Q sahip olunan işleri durdurarak çıkar.

Diğer sağlayıcılar, koordinasyon, çocuk görev ekranı, bildirimler, silme/otomatik temizlik, geçmiş içe alma, transkript araması ve worktree yönetimi kapsam dışıdır. İlk pencere kabulü bütün v1 veya tam performans kabulü anlamına gelmez. Ürün kararları [sözleşmede](../LOOM-PRODUCT-CONTRACT.md), görsel hedefler [tasarımda](../design/DESIGN.md), ortak çalışma yöntemi [AGENTS.md](../AGENTS.md) içindedir.

## Slice sırası ve kayıtlar

| Slice | Teslim | Kayıt / kabul durumu |
| --- | --- | --- |
| A | Paket, terminal motoru ve mevcut PTY bağlantısı | Uygulama ve düzeltme geçmişi arşivde; aşağıdaki kabul borçları nedeniyle bütünü kapanmadı. |
| B | Katalog, proje/aktivite görünümü, arama ve adlandırma | [B kabul edildi](CHECKPOINT-5-HISTORY.md#31-review-b-düzeltmeleri-ve-kapanış-29-eylül-2026); kapanmış yazışmalar arşivde kalır. |
| C | Gerçek Claude/Codex yeni/devam/durdur ve yaşam döngüsü bağlantısı | [C kayıtları](cp5/C.md) ve [birleşik native/strict kabul](cp5/CLOSURE.md): gerçek CLI kabulü 17/17, son imzalı pakette C 23/23 ve gerçek Claude native No geçti; kanıtlar [son kabul planında](cp5/FINAL-ACCEPTANCE.md). |
| D | Kalan görsel/girdi işleri ve birleşik kapanış kabulü | [D ürün ve ölçüm planı](cp5/D.md): ürün/girdi implementasyonu ve native kısmi kabul kayıtlı; kalan kaynak matrisi, bütçeler ve son birleşik kabul açık. |
| PERF | Loom ek yükü: terminal çizimi, Codex/Claude takip maliyeti, CPU40 ve gerçek Codex idle/Stop ölçümü | [PERF](cp5/PERF.md): P1/P1b/P1c/P2 ve T1/T2 kabul; paket F app CPU 31,5→26,3, CPU40 hâlâ başarısız; fixture düzeltmesi ve P3 sırada (duraklatıldı). |

[Kapsam/sıra kararı](CHECKPOINT-5-HISTORY.md#23-kullanıcı-kararı-temel-engeli-ayır-pencereye-ilerle-28-eylül-2026): OWN-1 ve ertelenen A kabulü pencere geliştirmesini durdurmaz; tam ürün kapanışından düşülmez. Arama ve temel yerleşim B'ye alındı; branch, ayrıntılı ayarlar ve kalan terminal girdileri D'de. Yeni sonuçları arşive ekleme.

## Kabul ölçütleri

Aşağıdaki kimlikler korunmuştur. Satırlar hedefleri gösterir; tamamlanma kanıtı ilgili slice kaydındadır. B'nin genişletilmiş B1–B5 kabulü [B planında](CHECKPOINT-5-HISTORY.md#25-b-dilimi-görünür-katalog-ve-pencere-28-eylül-2026), sonuçları yukarıdaki B kapanışındadır.

| ID | Senaryo | Ölçülebilir kabul | Dilim |
| --- | --- | --- | --- |
| A1 | Paket ve dış PTY bağlantısı | Sabit SwiftTerm revision'ıyla build; LaunchServices ile tek pencere; fixture PID'si supervisor'a ait, ikinci PTY sahibi yok; Quit raporu başarılı, fixture kalıntısı 0. | A |
| A2 | Byte sırası ve terminal | Bölünmüş UTF-8/ANSI, Türkçe/emoji, alternate screen, truecolor, terminal cevapları ve art arda paste/girdi beklenen son ekran/byte dizisini üretir; kısa yazma/eski run testleri geçer. | A |
| A3 | Görünür/gizli çıktı | [Ölçüm yöntemindeki](CHECKPOINT-5-HISTORY.md#6-ölçüm-ve-kabul-yöntemi) yükler altında byte kaybı/sonsuz bekleme yok; gizle→aç son ekranı korur; örtülü/gizli çizim ısınmadan sonra 0; aynı run için ikinci scrollback yok. | A |
| A4 | Kaynak ve derleyici sınırı | Tampon/OSC/görsel/kuyruk sınırları kaynakla ve taşma fixture'ıyla gösterilir; ölçülen feed/girdi p95 kaydedilir; Swift concurrency hatası gizlenmez. | A |
| B1 | Şema ve liste | Schema 1 fixture'ı bütün sohbet/run/link kimlikleriyle korunur; kesilen migration tekrar açılır; bozuk/yabancı/yeni şema üzerine yazılmaz; 10.000 kayıtta sayfalama/arama/sıra doğru. | B |
| B2 | Yeniden açılış | Proje, sıra, başlık ve UI tercihleri korunur; uygulama açılışı hiçbir sağlayıcı/PTY başlatmaz; kayıt başına terminal yaratılmaz. | B |
| B3 | Olay kaybından toparlanma | UI tüketicisi bekletilip burst verilir; son frame'le durum, aktif run, kimlik ve son hata doğru gösterilir; ara `change` atlanınca yanlış bitiş/başarı oluşmaz. | B |
| C1 | Yeni Claude/Codex | Kullanıcı eylemiyle doğru dizin/profilde gerçek TUI; eksik CLI veya ortam hatası görünür, yeniden deneme çalışır, hayalet canlı run yok; güven/izin kullanıcıda. | C |
| C2 | Kimlik ve devam | `/clear` ve `/new` eski kaydı korur; aynı run görünümü yeni kimliğe bağlanır; eski kart yeni terminale yazamaz; açık resume aynı geçmişi açar; eksik geçmiş yeni sohbete dönüşmez. | C |
| C3 | Yaşam döngüsü | Aktif tur/onay/arka plan işi idle olmaz; idle ve stale seçimi kendiliğinden başlatmaz; görünür/etkin seçme kullanım zamanını günceller, gizli/pasif liste yenileme güncellemez. | C |
| C4 | Onay ve dürüst hata | Claude/Codex onayı kullanıcıya ulaşır ve kullanıcının yanıtıyla sonuçlanır; belirsiz kimlik, kopan server ve stop hatası doğru kartta kalır; otomatik onay yok. | C |
| C5 | Stop ve `/exit` | İki canlı sohbette birini durdurmak diğerini etkilemez; lider çıkışı sonrası iş denetlenir; başarısız stop yeniden açmayı engeller, görünümü kapatmak takibi silmez. | C |
| D1 | Tasarım ve girdi | İki görünüm 1220×780 ve minimum boyutta referansla karşılaştırılır; kontroller/başlıklar taşmaz; kısayollar, font, paste/drop, bağlantı ve erişilebilirlik tercihleri çalışır. | D |
| D2 | Pencere kapatma | Cmd+W/kırmızı düğme sonrası fixture işi sürer, çizim durur; Dock/yeniden açma aynı pencere/terminali getirir; pencere sayısı en fazla 1. | A,D |
| D3 | Tam çıkış ve hata | Başlatma sürerken/aktif turda/gizli pencerede Cmd+Q: başarılı normal çıkış sonrası tüm sahip olunan çalışan süreçler 0, dış kontrol süreci değişmez. Zorlanan hata başarı göstermez; tekrar deneme sınanır. | A,C,D |
| D4 | Uzun kullanım ve ölçek | [Ölçüm yönteminin](CHECKPOINT-5-HISTORY.md#6-ölçüm-ve-kabul-yöntemi) 50 terminal/10.000 kayıt/100 çevrim/10 dakika sonuçları tabloya yazılır; sınır aşımı veya sürekli büyüme varsa kapatma engelidir. | D |
| D5 | GPU ve görsel tercihler | Cam/opak matrisi ve azaltılmış hareket/saydamlık ayrı kayıtlı; ölçümün veremediği sonuç açıkça doğrulanmadı. Tam kaynak kabulü GPU/bütçe açıkken kapanmaz. | D |
| D6 | Çökme/Force Quit ayrımı | İzole fixture ile normal Quit'ten ayrı kanıt; sonraki açılış otomatik sohbet başlatmaz ve eski canlı durumunu başarıyla kapanmış saymaz; normal Quit sonucu çökmeye genellenmez. | D |

## Açık işler ve kapanış kapıları

| İş | Ne gerekiyor? | Dayanak |
| --- | --- | --- |
| C gerçek sağlayıcı kabulü | 2 Ekim gerçek Claude/Codex 17/17 korunur. Son imzalı paket C'de sentetik C 23/23 ve gerçek Claude 2.1.287 / Haiku 4.5 native No geçti; reddedilen marker oluşmadı, aynı run Waiting for you durumuna döndü. | [Son native kanıt](experiments/cp5-final-signed-native.json), [HOLISTIC](cp5/HOLISTIC.md) |
| OWN-1 | Sabit yerel imza ve sertifikaya bağlı owner requirement doğrulandı; farklı iki binary paketi arasında Belgeler erişimi tekrar izin istemedi. Canlı compiler XPC şartlı OWN-A4 iki tekrar ve tam suite'te geçti. Son native Quit 10/10 ve çökme 13/13; kapsam/host kalıntısı 0. | [OWN](cp5/OWN.md), [imza](experiments/cp5-stable-signing.json), [native](experiments/cp5-final-signed-native.json) |
| A kaynak kabulü | Son run-host paketinde 43 kaynak koşusu ve 2000 gecikme örneği geçerli. Paket C host dahil iki 600 sn yükte sürekli büyüme yok; gizli çizim 0. Yeni D23 valid/CPU40 başarısız ve ASCII adayının runtime kabulü açık. GPU dört görünür hücre geçerli; dört örtülü hücre ve sayısal bütçeler son kabulde açıktır; eski run-host öncesi kaynak kanıtı bu mimariye genellenmez. | [Kaynak](experiments/cp5-final-runscope-resource.json), [gecikme](experiments/cp5-final-runscope-latency.json), [FINAL-ACCEPTANCE](cp5/FINAL-ACCEPTANCE.md) |
| D birleşik kabulü | Reduce Motion native kabulü ve tercih geri yüklemesi geçti. Finder çoklu drop/no-Enter ve dört linkin native açılışı CUA drag/modifier-click araç sınırı nedeniyle doğrulanmadı. Dört örtülü GPU hücresi ve sayısal bütçe kabulü açık. | D1–D6 ve [son kabul](cp5/FINAL-ACCEPTANCE.md) |
| Birleşik inceleme | Paket C native suite 322/322 korunur; yeni CPU/Codex düzeltmeleri ve fixture teardown sonrası son kaynak suite 334/334. Astra/high kaynak review geçti; paket D23 valid fakat yoğun CPU %40 başarısız. ASCII adayı source review ve yeni334 testten geçti; imza/runtime kabulü Mac kilidi nedeniyle doğrulanmadı. Önceki strict/Herdr/Orca ve GPU hazırlık düzeltmesi kayıtları korunur; açık kapılar kapanmadan CP5 kapanmaz. | [Kapanış](cp5/CLOSURE.md), [ortak akış](../AGENTS.md#checkpoint-closure) |

Model deneyi: **2 Ekim 2026 kullanıcı kararıyla gerçek CLI/model testleri izin istenmeden çalıştırılır; yalnız büyük bütçeli işler sorulur** ([geliştirme rehberi](../DEVELOPMENT.md)). Önceki tur sayaçları (Claude Haiku 2/2, Codex 6/6) tarihsel kayıttır ve artık kapı değildir. [C §15](cp5/C.md#15-codex-deney-yetkisi-ve-uygulama-sırası-29-eylül-2026) uygulama sırası korunur. İlk sayısal kaynak hedefleri ürün bütçesi olarak onaylanmış değildir; GPU/bütçe açıkken tam kaynak kabulü verilmez.

## Gerektiğinde başvurulacak geçmiş

[Bu düzenleme öncesindeki birleşik kayıt](CHECKPOINT-5-HISTORY.md) mevcut 33 bölümü aynen korur. Eski işlem talimatları güncel akışın yerine geçmez. Kapanmış A/B yazışmaları yeni işin zorunlu okuması değildir; yalnız ilgili dayanağa git.

- [Terminal bağlantı sınırları](CHECKPOINT-5-HISTORY.md#3-terminal-ve-arayüz-teknik-yönü) ve [pencere/veri davranışları](CHECKPOINT-5-HISTORY.md#4-pencere-ve-kalıcı-veri): eski aday/seçim durumlarını güncel kodla doğrula.
- [Pencere, Stop/Quit ve paketleme kabulü](CHECKPOINT-5-HISTORY.md#5-sahiplik-kapatma-ve-geliştirme-paketi).
- [Ölçüm yöntemi](CHECKPOINT-5-HISTORY.md#6-ölçüm-ve-kabul-yöntemi): sonraki [geçerlilik düzeltmeleri](CHECKPOINT-5-HISTORY.md#19-optimizasyon-incelemesi-kota-ve-ölçüm-düzeltmeleri-28-eylül-2026) ve [uygulama sonuçları](CHECKPOINT-5-HISTORY.md#20-uygulama-sonucu-13-ve-1819-düzeltmeleri-28-eylül-2026) birlikte değerlendirilir.
- [B kapanışı ve C girdileri](CHECKPOINT-5-HISTORY.md#31-review-b-düzeltmeleri-ve-kapanış-29-eylül-2026); [B son optimizer sonucu](CHECKPOINT-5-HISTORY.md#32-optimizasyon-incelemesi-b-düzeltmeleri-29-eylül-2026).
- [Orca araştırması](CHECKPOINT-5-HISTORY.md#24-orcadan-alınacak-fikirler-ve-loomdaki-yerleri-28-eylül-2026): gelecekteki CP3 fikirleri bugünkü C kapsamına eklenmez.
- [Orca/Herdr geniş kaynak araştırması](experiments/orca-herdr-logic-research-20260930.md) ve [CLI/DevDay taraması](experiments/openai-cli-devday-research-20260930.md): C review soruları, D/optimizer ölçüm adayları ve sonraki koordinasyon fikirleri; araştırma kabul veya kapsam genişlemesi değildir.
