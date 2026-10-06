# Codex CLI / DevDay taraması — 30 Eylül 2026

## Sonuç ve yöntem

Kullanıcının Orca/Herdr araştırmasına eklediği güncel CLI ve DevDay taraması. OpenAI Docs ve TinyFish becerileriyle resmî sayfalar açıldı; arama snippet'leri karar kanıtı sayılmadı. CLI alanı bağlam gereği Codex olarak alındı. `codex --version` **0.158.0** döndürdü. Kurulum, güncelleme, profil değişikliği, API inference, sağlayıcı oturumu veya model turu yapılmadı.

Resmî sürüm notlarında 29 Eylül 2026 için **0.159.0 / 0.159.1** var. Bunlar 30 Eylül yerel inceleme tarihiyle karıştırılmamalı. Sürüm notu, Loom'daki hatanın düzeldiğinin kanıtı değildir. [Resmî changelog](https://learn.chatgpt.com/docs/changelog)

## CLI: doğrudan ilgili değişiklikler

| Konu | Doğrulanan değişiklik | Loom etkisi / çıkarım |
| --- | --- | --- |
| 0.159.1 | GPT-6.1 Sol model kataloğu/varsayılanı. | CLI sürümü ile model kimliğini deney kaydında ayrı tut; eski karşılaştırmayı sessiz model değişimiyle yapma. |
| 0.159.0 girdi | Opt-in `instant_interrupt` ile yeni input'un devam eden yanıt/code-mode işini yönlendirmesi. | Özellik etkinliği görülmeden native input davranışı ve Stop eşdeğerliği varsayılmaz. |
| 0.159.0 bağlantı | TUI reconnect deadline'ı ve uzun symlink üzerinden Unix socket bağlantısı düzeltmeleri. | Remote bağlantı fixture'larına aday; eski startup sorununun nedeni ilan edilmez. |
| 0.159.0 oturum | Blank session/task switching ve ilk tur öncesi archive/list değişiklikleri; item-anchor history pagination. | Yeni/resume ve kimlik öncesi terminal akışı etkilenebilir. Pagination mevcut hydration ihtiyacını kendiliğinden değiştirmez. |
| 0.159.0 süreç/tanı | Termination sırasında observer çıktısını koruma, exec-server process ID tekilliği ve loglarda hassas payload azaltımı listelenmiş. | PR başlıkları ilgili; orphan cleanup, thread→PTY korelasyonu veya bizim Stop hatamız için düzeltme garantisi değil. |

Bu tablonun kaynağı [resmî CLI sürüm notlarıdır](https://learn.chatgpt.com/docs/changelog); PR diff'leri ve yeni binary çalışması incelenmedi. Ephemeral yardımcıyı kullanıcı sohbetinden ayıran yeni PTY/run marker garantisi veya Loom'un OWN-1 açığını kapatan değişiklik doğrulanmadı.

## Güncel app-server belgesinden en yakın review girdisi

`serverRequest/resolved`, pending isteğin cevaplanmasını/temizlenmesini bildiriyor. Belge, user-input isteğinin turn başlangıcı, bitişi veya kesilmesiyle temizlenmesinde de aynı bildirimi anlatıyor; command/file approval akışlarında da resolution bildirimi var. Ephemeral fork'un `thread/started` üretmesi ve unsubscribe sonrası 30 dakikalık inactivity unload koşulu belgede sürüyor. [App-server](https://learn.chatgpt.com/docs/app-server)

**Kaynakta doğrulandı:** Loom [event enum'u](../../Sources/LoomCore/CodexAppServer.swift#L129) resolution olayını temsil etmiyor. [Coordinator](../../Sources/LoomCore/CodexSessionCoordinator.swift#L147) kendi `respond` çağrısı başarıyla yazıldıktan sonra matching pending request'i kaldırıyor. **Çıkarım / doğrulanmadı:** remote TUI'den cevaplanan request'in Loom'da pending kalması mümkün bir entegrasyon açığıdır; hangi bildirimlerin bizim abonelik bağlantımıza geldiği ve kurulu sürümün tam payload'ı ayrıca sınanmalı. Bu olayın 0.159'da yeni eklendiği doğrulanmadı.

**Dar kontrol adayı:** request A → TUI/başka client resolution → `serverRequest/resolved(threadId, requestId)` → aynı run'daki yalnız A'nın temizlenmesi; duplicate resolution, yanlış thread/run ve interruption cleanup. Terminal ekranından approval sonucunu tahmin etme; otomatik cevap verme. İlgili decoder/router/coordinator fixture'ı önce aranır; eksikse review sırasında davranış yeniden üretilir. Bu araştırma yeni formal bulgu veya kabul sonucu değildir.

## DevDay: Loom açısından öncelik

### 1. Sign in with ChatGPT — yüksek stratejik ilgi, ayrı ürün kararı

Açık kaynak/yerel uygulamalar, uygun Responses istekleri için kullanıcının ChatGPT planından yararlanma izni isteyebiliyor. Bu izin geçmiş ChatGPT konuşmalarını açmıyor; kalıcı host ID, OAuth kaydı/onayı ve uygulamanın token yönetimi gerekiyor. Loom'un uygunluğu ve dağıtım modeli doğrulanmadı. [OSS plan kullanımı](https://learn.chatgpt.com/siwc/token-sharing-open-source)

Belgelenmiş app-server örneği OAuth token'ını child ortamında tutan Responses provider, stdio yerel taşıma ve HTTP/SSE inference kullanıyor. `model/list` entitlement kanıtı değil; token yenilemede bu yapılandırma app-server restart + resume istiyor. **Loom çıkarımı:** ortak sunucudaki başka canlı oturumları etkileyebileceğinden mevcut native remote TUI yoluna doğrudan uygulanmaz; ayrı tasarım/izolasyon deneyi gerekir. [App-server entegrasyonu](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server)

Preview sınırları `multi_agent` gibi alanları ve bazı hosted araçları dışlıyor; app-server'ın yerel shell/MCP/child-agent işleri ayrı mekanizma. **Responses multi-agent beta + ChatGPT plan kullanımını birleştirip destekleniyor sayamayız.** Yerel history/resume ile sunucuda saklanan Responses conversation da ayrı. [Preview sınırları](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)

### 2. MCP Events — gelecek yetkilendirilmiş koordinasyon için

ChatGPT'nin kullanıcı talimatıyla sunucu olaylarına abone olması için webhook yolu var. MCP 2.0, kalıcı subscription ve callback doğrulaması gerektiriyor; bu entegrasyon polling/streaming veya draft gap/terminated bildirimlerini desteklemiyor. **Loom çıkarımı:** ileride dışarıya görev sonucu bildirme köprüsünde değerli olabilir; yerel Swift EventHub/Unix socket'in yerine geçmez, bugün servis/webhook kurma nedeni değil. [MCP Events](https://developers.openai.com/plugins/build/mcp-events)

### 3. Plugin Extensions — isteğe bağlı eşlikçi arayüz

Sidebar/panel, dosya görüntüleyici, composer mention ve model-app context yüzeyleri belgelenmiş. **Loom çıkarımı:** gelecekte ChatGPT içinden Loom katalog/görev görünümü için aday; native macOS terminal ve süreç sahibini bununla değiştirmek ayrı ürün kararıdır. [Extensions](https://developers.openai.com/plugins/build/extensions)

### 4. GPT-6.1 Sol / Responses multi-agent — maliyet ve koordinasyon araştırması

GPT-6.1 Sol ve multi-agent desteği güncel duyurularda var. Model fiyatı/hesap erişimi ve CLI ile API tüketimi aynı sözleşme değildir. Bu araştırmada model seçimi veya bütçe değiştirilmedi. [API changelog](https://developers.openai.com/api/docs/changelog)

Responses multi-agent beta, bir request içinde kökün alt ajanlar açıp sonuç birleştirmesine izin veriyor; ortak model/araç kümesiyle çalışıyor. **Loom çıkarımı:** mevcut bağımsız Claude/Codex oturumları arasında kullanıcı yetkisine bağlı iletişimin yerine geçmez. İleride API tabanlı ayrı sağlayıcı için aday olabilir; bugünkü C kapsamı değil. [Multi-agent rehberi](https://developers.openai.com/api/docs/guides/responses-multi-agent)

### 5. Dots, cloud ortamları, Security Cloud, hosted computer use

DevDay özetinde sürekli çalışan dots, cloud ortamları, Security Cloud ve cihazlar arası Work bulunuyor. Bunlar ürün karşılaştırması/gelecek iş akışı açısından takip edilebilir; yerel terminal sahipliği sorununa doğrudan çözüm sunulduğu doğrulanmadı. Hosted computer use da Agents API'de ayrı API yoludur. Bu taramada hesap erişimi sınanmadı, plugin veya cloud iş kurulmadı. [DevDay özeti](https://learn.chatgpt.com/docs/whats-new), [API changelog](https://developers.openai.com/api/docs/changelog)

## Önerilen sıra

1. Mevcut §26 review'unu tamamlarken çözülmüş approval bildirimi, aynı cwd'deki ilgisiz interactive thread ve pending-approval/status sırasını ilgili fixture'larda incele. Araştırma sonucunu otomatik kabul sayma.
2. CLI yükseltmesi yapılacak turda eski/yeni sürüm kanıtını ayır; önce model kullanmayan şema ve dar fixture kontrolleri. Gerçek model deneyi mevcut yetki/tekrar sınırına bağlıdır. Bu tur güncelleme yapılmadı.
3. CP5 D/optimizer sırasında Orca/Herdr kaynak ölçüm adaylarını kullan; tam suite yalnız checkpoint/büyük değişiklik gerektirdiğinde.
4. SIWC, MCP Events ve API multi-agent ayrı gelecek tasarım adayları olarak dursun. Native TUI, auth veya koordinasyon kapsamı değişecekse ürün kararı ayrıca alınır.

**Doğrulandı:** kurulu version çıktısı, resmi sayfa içeriği ve belirtilen mevcut Loom kodu. **Doğrulanmadı:** 0.159.1 runtime/şema davranışı, hesap entitlement'ı, gerçek onay/resume/Stop kabulü, DevDay özelliklerinin Loom'daki uygulanabilirliği. Codex **1/4 harcandı, kalan 3, tekrar 0**; Claude ek yetki **0** korunur.
