# Loom çalışma akışı

## Başlangıç ve roller

1. Ana ajan planner-reviewer'dır: planlar, işi subagent'lara delege eder ve kabul review'unu yapar. Kullanıcının açık rol veya görev ataması önceliklidir.
2. [STATUS.md](STATUS.md), [rol dosyan](agents/README.md) ve status'un işaret ettiği plan bölümünü oku. En yüksek checkpoint numarasını güncel iş sayma. Subagent işini planner-reviewer'ın brief'inden alır; status'tan kendine iş seçmez.
3. `git status` ile mevcut değişiklikleri gör ve koru. İlgili ürün/tasarım maddelerini ve gerektiğinde [geliştirme rehberini](DEVELOPMENT.md) oku.

## Delegasyon ve iletişim

Planner-reviewer implementer, araştırmacı ve optimizer subagent'larını doğrudan görevlendirir; ilerleme, teknik sorular, sonuçlar ve düzeltmeler doğrudan mesajlarla iletilir. Kullanıcının ajanlar arasında prompt taşıması veya dosyaya yanıt eklenmesini beklemek gerekmez. Subagent yeni ajan başlatmaz; koordinasyon ve kabul kararı planner-reviewer'da kalır.

Brief kısa ve işi yapmaya yeterli olsun: **Goal / Context / Scope / Done when / Checks**. Hedefi, gerekli kaynakları ve kararları, dosya sahipliğini, kapsam dışını, kabul ölçütlerini ve kontrolleri belirt. Varsa deney yetkisini/bütçesini açıkça aktar. Subagent'ın başka ajanlarla aynı çalışma ağacını paylaştığını ve onların değişikliklerini koruması gerektiğini söyle. Geçmiş sohbeti veya bütün plan arşivini okumasına güvenme.

Subagent sonucu **Status / Result / Evidence / Unverified / Needs** başlıklarıyla doğrudan planner-reviewer'a verir; kısa işte her başlık bir satır olabilir. Eksik bilgi ve engeller de mesajla iletilir. Kanıtı **doğrulandı / başarısız / doğrulanmadı** diye ayır. Implementasyonun raporlanması kabul edildiği anlamına gelmez.

Bağımsız işler ayrık yazma alanlarıyla paralel yürüyebilir; sıkı bağlı işleri bölme. Birleşik kontrollerin tek sahibi planner-reviewer tarafından belirlenir. Planner-reviewer değişiklikleri ve belirleyici kanıtları inceler, eksikleri doğrudan ilgili subagent'a döner. Rutin teknik kararları ajan verir; kullanıcıya yalnız ürün tercihi, kapsam veya yetki gerektiren karar gider.

## Kalıcı kayıt ve durum

Dosyalar haberleşme kanalı değil, sonraki oturumun işi sürdürebilmesi için kısa plan ve karar kaydıdır. Bu kayıtları planner-reviewer günceller; subagent'lar plan, checkpoint haritası ve status'a yazmaz.

- `plans/CHECKPOINT-<n>.md`: hedef, slice sırası, kabul ölçütleri, açık işler ve kayıt bağlantıları. Tur raporu veya yazışma eklenmez.
- `plans/cp<n>/<slice>.md`: slice planı, önemli kapsam/uygulama kararları, açık bulgular ve kabul sonuçları; gereken kanıta bağlantı verir. Her mesaj veya ajan turu için bölüm ekleme. Checkpoint kapanışı gerektiğinde aynı klasörde `CLOSURE.md` içinde tutulur.
- Deney dosyaları: ayrıntılı ölçüm ve kanıt. Subagent kendi brief'inde atanmış kanıt dosyalarına yazabilir; ham log ve bütün diff anlatısı slice'a kopyalanmaz.
- Eski slice bölümleri ve kapanmış kayıtlar korunur. Düzeltmeler ilgili eski bulguya referans veren kısa bir yeni kayıtla yapılır. Eski dosyadan devir/yazışma talimatları tarihsel kayıttır; güncel çalışma biçimi bu dosyadır. Ürün kabulü, açık bulgular ve deney yetkisi bu geçişle değişmez.

Planner-reviewer tur sonunda gerekli karar/sonuç kaydını tamamlar, ardından `STATUS.md` dosyasını günceller. Status yalnız checkpoint, slice, durum, sıradaki rol/iş sahibi, iş bağlantısı, son sonuç bağlantısı ve varsa engeli içerir; geçmiş ve test dökümü biriktirilmez. Konum değişmediyse korunur. Güncel iş konumunun tek kaynağı status'tur.

Durumlar: **planlama bekleniyor**, **implementasyon bekleniyor**, **review bekleniyor**, **optimizasyon bekleniyor**, **kullanıcı kararı bekleniyor**, **tamamlandı**. Implementasyon veya optimizasyon beklenmesi ayrı bir kullanıcı oturumu beklendiği anlamına gelmez; yetkili kapsam içinde planner-reviewer subagent'ı başlatır ve sonucunu takip eder. Devam ederken önce mevcut subagent'ların durumunu kontrol et; aynı işi tekrar başlatma. Kayıt yazmadan önce son içeriği yeniden oku ve araya giren değişikliği hesaba kat.

## Checkpoint kapanışı

Her slice planner-reviewer'ın davranış/kabul review'undan geçer. Optimizer her slice'ta rutin çalıştırılmaz; checkpoint kapanmadan önce zorunludur. Planner-reviewer optimizer subagent'ını görevlendirir, belirleyici bulgularını doğrular ve sonucu checkpoint kapanış kaydına ekler. Daha erken inceleme yalnız somut bir yapı/kaynak sorunu gerektiriyorsa yapılır.

Optimizer için zorunlu model **`gpt-6-astra`**, reasoning effort **`high`** (3 Ekim 2026 kullanıcı kararı); Claude Code oturumunda **Opus 5.5 / `xhigh`** de kabul edilir (3 Ekim 2026 kullanıcı izni). Planner-reviewer optimizer'ı bu ayarlardan biriyle başlatır; daha düşük model/effort'a kendiliğinden düşmez. İstenen ayar kullanılamıyorsa sınırlamayı kullanıcıya bildirir; başka modelin incelemesini checkpoint sonu optimizer kabulü saymaz.

Checkpoint, kabul ölçütleri doğrulanıp optimizer incelemesi tamamlandıktan ve engelleyici bulgular kapandıktan sonra kapanır. Düzeltme yapılırsa etkilenen kabul ve optimizer bulgusu yeniden doğrulanır; ilgisiz incelemeler tekrarlanmaz. İyileştirme önerileri kendiliğinden yeni kapsam veya kapanış engeli sayılmaz; planner-reviewer etkisini ve önceliğini gerekçelendirir.

## Kaynaklar ve sınırlar

- [Ürün sözleşmesi](LOOM-PRODUCT-CONTRACT.md): ürün kararları ve teknik sınırlar. §3 değişiklikleri kullanıcı kararı gerektirir.
- [Görsel sözleşme](design/DESIGN.md): tasarım hedefleri.
- [Geliştirme rehberi](DEVELOPMENT.md): kontroller, izolasyon ve kanıt yöntemi.

Kullanıcıyla kısa ve sade Türkçe konuş; teknik kanıta kalıcı kayıttan bağlantı ver. Commit, push ve PR yalnız kullanıcı isteyince yapılır; planın bunları istemesi tek başına kullanıcı yetkisi değildir.
