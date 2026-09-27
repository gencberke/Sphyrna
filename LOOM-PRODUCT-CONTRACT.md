# Loom — ürün sözleşmesi ve geliştirme kararları

**Güncelleme:** 27 Eylül 2026  
**Durum:** Ürün yönü ve kabul edilen kararlar tanımlı; uygulama ve teknik kabul deneyleri henüz tamamlanmadı.

Bu dosya Loom için güncel başlangıç belgesidir. Kullanıcının beklentilerini, Claude ile yapılan görüşmede alınan kararları ve sonraki teknik değerlendirmeyi birleştirir. Bir davranışın burada hedeflenmesi, uygulanmış veya test edilmiş olduğu anlamına gelmez.

## 1. Amaç ve öncelikler

Loom, Claude Code ve Codex CLI oturumlarını gerçek terminalleriyle barındıran ve bir arada organize eden hafif bir masaüstü uygulamasıdır. Kullanıcı, CLI'ların kendi yeteneklerini kullanmaya devam ederken oturumları yönetebilmelidir. Başlangıç çalışma ortamı macOS'tur; diğer platformlar için kapsam kararı alınmadı.

Ürünün temel ölçütleri:

- **Düşük kaynak tüketimi:** Bırakılmış sohbetler birikerek canlı süreç, terminal tamponu ve sürekli arka plan işi biriktirmemeli.
- **Öngörülebilir davranış:** Aynı eylem aynı anlamı taşımalı; bir sohbeti görüntülemek, çalıştırmak, kapatmak ve silmek açıkça ayrılmalı.
- **Doğru durum bildirimi:** Başlatıldı, durduruldu, teslim edildi ve silindi ifadeleri doğrulanmış sonuçları anlatmalı.
- **Akıcılık ve pratiklik:** Yazma, çıktı görüntüleme, oturum geçişleri ve liste kullanımı gereksiz bekleme veya sürekli onaylarla zorlaştırılmamalı.
- **Temiz ve modüler yapı:** Arayüz, süreç sahipliği, veri saklama ve sağlayıcı entegrasyonları ayrı sorumluluklar olmalı. Modülerlik, her sorumluluk için ayrı bir süreç veya servis kurmak anlamına gelmez.
- **Güncellemelere dayanıklılık:** Claude ve Codex sürümleri kullanıcı adına sabitlenmemeli. Değişiklikler fark edilmeli; desteklenmeyen davranışlar yanlış başarı bildirimine dönüşmemeli.

Loom'un güvenilirliği, az kaynak tüketimiyle birlikte değerlendirilir. Yalnızca ekrandan kaldırılmış fakat çalışmaya devam eden bir oturum, kapatılmış kabul edilmez.

## 2. Belgelerin ve mevcut kaynakların konumu

| Kaynak | Nasıl kullanılacak? |
| --- | --- |
| Bu dosya | Güncel ürün kararları, teknik sınırlar ve geliştirme checkpoint'leri. |
| [Görsel sözleşme](design/DESIGN.md) | Korunacak arayüz öğeleri, ölçüler, renkler, kısayollar ve eski uygulamanın davranış envanteri. Envanter Loom gereksinimi değildir; çelişkide bu dosya esas alınır. |
| `design/` | Referans görseller ve `legacy-code/` altındaki eski Swift arayüz kaynakları. Eski çizim kodunun, terminal motorunun veya mimarinin aynen kullanılması şart değil. |
| `assets/` | Uygulama simgesi, sağlayıcı simgeleri ve `brand/` altında marka kaynakları ile telif notları. |
| `plans/` | Checkpoint planları ve sonuçları. |

İlk araştırma raporu, eski spec ve Herdr kaldırma kaydı bu dosyaya ve görsel sözleşmeye taşındıktan sonra repodan çıkarıldı.

Bu belgede **kabul edilen davranışlar**, **teknik adaylar** ve **açık kararlar** ayrı belirtilir. Önceki sohbetlerde önerilmiş her özellik kapsamın parçası değildir.

## 3. Kabul edilen kararlar

| Konu | Karar |
| --- | --- |
| Temel deneyim | Claude Code ve Codex'in gerçek CLI/terminal deneyimi korunacak. |
| Görsel hedef | Mevcut tasarım ve ikonlar korunacak. |
| Uygulamadan tam çıkış | Loom'a ait işler durdurulabilir. Normal çıkış tamamlandığında Loom'a ait çalışan süreç kalmamalı. |
| Claude Agent View | Süreç sahipliğini korumak için Loom'un başlattığı Claude oturumlarında kapatılabilir. Bu kabul edilmiş bir CLI özellik istisnasıdır. |
| Sağlayıcı sürümleri | Claude veya Codex sürümü sabitlenmeyecek. |
| Çekirdek dili | Swift; çekirdek bu repoda yazılır ve checkpoint kodu uygulamanın çekirdeği olur. Terminal motoru ve arayüz teknolojisi ayrıca seçilecek. |
| Deney izolasyonu | Checkpoint deneyleri izole CLI profillerinde (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) yapılır. Kullanıcının gerçek profilleri ve oturumları yalnızca etkilenmediklerini doğrulamak için okunur. |
| Oturumlar arası iletişim | Kullanıcının görevlendirmesi ve yetkilendirdiği kapsam içinde gerçekleşecek. |
| Codex önbelleği | Görüşmede açıklanan, ayrılmış thread'in 30 dakikaya kadar bellekte kalması kabul edildi. Bu, çalışan iş bırakma izni değildir. |
| Stale içerik önizlemesi | Yapılması zor veya maliyetliyse ilk sürümün şartı değil. |
| Aylık temizlik hedefi | `idle` değil, uygun `stale` oturumlar. |
| Kullanım zamanı | Kullanıcının sohbeti görüntülemesi kullanım süresini yeniler. |
| Stale görüntüleme | Stale bir oturumu görüntülemek durumunu değiştirmez; oturum stale kalır. Stale'den çıkış yalnızca açık yeniden etkinleştirmeyle olur. |
| Silme bekleme süresi | Otomatik silme için oturumun en az 15 gün stale kalmış olması gerekir. |
| Temizlik istisnaları | Sabitlenmiş sohbetler, korunması gereken worktree durumları ve tamamlanmamış yetkilendirilmiş bir görevin kaynağı veya hedefi olan sohbetler otomatik temizliğin dışında tutulur. |
| Uzun aradan sonra temizlik | Uygulama uzun süre kapalı kaldıysa açılışta sürpriz toplu silme yapılmaz; liste ve onay gösterilir. |

“Kullanıcının yönetiminde iletişim”, bütün mesajların kullanıcı tarafından elle yapıştırılması demek değildir. Kullanıcının “bu işi diğer oturuma devret ve sonucunu takip et” görevlendirmesi de bu ilkeye uygundur. Kullanıcının yetkilendirdiği iş akışı için her adımda aynı izni yeniden istemek gerekmez.

Uygulamaya bağlı yardımcı süreçlerin tümünü yasaklama, MCP'yi kapsamdan çıkarma ve görev devrini yalnızca metin yapıştırmayla sınırlama kararı alınmadı.

## 4. Oturum yaşam döngüsü

### 4.1. Ana durumlar

| Durum | Anlamı | Kaynak beklentisi |
| --- | --- | --- |
| `active` | En az bir prompt gönderilmiş, üzerinde çalışılan oturum. Ekranda seçili olması gerekmez. | CLI, terminal ve gerekiyorsa sağlayıcı çalışma kaynakları bulunabilir. |
| `idle` | Kullanılmadığı için çalışması sonlandırılmış; yeni promptla aynı sohbetten devam edilebilir. | Oturuma ait canlı CLI/TUI, terminal tamponu ve işler bırakılmaz. Ortak sağlayıcı önbelleği istisnası aşağıdadır. |
| `stale` | Uzun süredir kullanılmayan, açık bir kullanıcı eylemiyle yeniden etkinleştirilecek oturum. | Canlı iş yoktur. Listeleme veya önizleme çalışma başlatmaz. |
| `deleted` | Tanımlanan silme kapsamı tamamlanmış ve doğrulanmış oturum. | Çalıştırılabilir sohbet, bekleyen iş veya kapsam içindeki veriler kalmaz. |

Henüz prompt gönderilmemiş bir terminal, `active` tanımına zorla sokulmaz. Böyle bir başlangıç durumunda da açılan bütün süreçler Loom'un sahipliği ve çıkış kurallarına tabidir; nihai UI etiketi uygulama sırasında belirlenebilir.

`deleted`, sohbet içeriğini tutan bir arşiv türü değildir. Başarılı silmeden sonra içerik taşıyan katalog kaydı kaldırılır. Silme sürerken veya başarısızken kurtarma için gerekli işlem kaydı korunabilir.

### 4.2. Yaşam döngüsünden ayrı bilgiler

“Çalışıyor”, “onay bekliyor”, “girdi bekliyor”, “hata aldı” ve “işini bitirdi” ajanın anlık durumlarıdır. `active/idle/stale` ile aynı alan olarak modellenmemelidir.

Sürecin başlatılıyor/çalışıyor/durduruluyor/durmuş olması ve oturumun ekranda seçili olması da ayrı bilgilerdir. Eski bir hata veya başarı olayı, yeni bir çalıştırmanın durumunu değiştirmemelidir.

### 4.3. Idle'a geçiş

Başlangıç hedefi yaklaşık **bir saatlik kullanılmama** sonrası idle'a geçiştir. Son prompttan geçen süre tek başına yeterli değildir: uzun süren bir iş, bekleyen onay, çalışan alt ajan veya arka plan komutu olabilir.

Önerilen geçiş sözleşmesi:

1. Devam eden iş ve kapanmayı engelleyen durumlar kontrol edilir.
2. Sohbetin devam ettirilebilmesi için kimliği ve gerekli kayıtları doğrulanır.
3. Yeni iş kabulü ile kapatma işlemi eşgüdümlenir; kapanırken gelen prompt kaybolmaz veya ikinci süreç başlatmaz.
4. Çalışma düzgünce sonlandırılır; gerekiyorsa tanımlanmış durdurma yolu uygulanır.
5. Oturuma ait işler ve terminal kaynakları bırakıldığı doğrulanır.
6. Ancak sonra `idle` gösterilir.

Bir arka plan işi güvenli otomatik geçişi engelliyorsa oturum kapatılmış gibi gösterilmez. Kullanıcı nedeni anlayabilmelidir. **Otomatik idle'a alma ile kullanıcının açık kapatma/çıkış talebi aynı işlem politikası değildir:** tam çıkışta devam eden işler durdurulabilir.

Yeni promptla devam etmek yeni bir OS süreci gerektirebilir. Sohbet kimliği, çalışma dizini ve devam için gerekli oturuma özel ayarlar korunmalıdır; devam başarısızsa sessizce yeni sohbet oluşturulmamalıdır.

### 4.4. Codex önbelleği istisnası

Codex app-server, son abonelik kaldırıldıktan sonra belirli koşullarda thread'i hemen boşaltmıyor; araştırmada 30 dakikalık bekleme belgelenmişti. Bu davranış kabul edildi. [Codex App Server](https://learn.chatgpt.com/docs/app-server)

Bu yüzden idle için “mutlak sıfır bellek” iddiası kullanılmaz. Kapatılan oturumun aktif işi ve terminali sonlanmalı; ortak sağlayıcının tuttuğu geçici bellek ayrı ölçülmelidir. Loom'a ait sunucuya ihtiyaç kalmadığında sunucunun da kapatılması aday davranıştır; başka canlı oturumları etkilemediği kanıtlanmalıdır.

## 5. Stale ve saklama politikası

Başlangıç hedefi, yaklaşık **15 gündür kullanılmayan** oturumları stale olarak sınıflandırmaktır. Kullanım hesabına kullanıcı promptu ve kullanıcının bilinçli sohbet görüntülemesi girer. Liste yenilemesi, arka plan taraması veya ajanın sırf olay üretmesi kullanıcı görüntülemesi sayılmaz.

Stale oturumun çalıştırılması açık yeniden etkinleştirme gerektirir. Stale bir oturumu görüntülemek onu stale durumundan çıkarmaz, CLI'ı başlatmaz ve oturumu active yapmaz. Stale olmayan oturumlarda görüntüleme, kullanım süresini yenileyerek stale'e geçişi geciktirir. Stale bir hedef, başka ajandan gelen mesajla sessizce uyandırılmaz; yetkilendirilmiş iş akışı yeniden etkinleştirme gereksinimini görünür kılmalıdır.

Otomatik temizliğin kabul edilen koşulları:

- Aylık temizlik, yalnızca uygun stale oturumları hedefler.
- Bir oturum silinmeden önce en az 15 gün stale kalmalıdır.
- Kullanıcının görüntülemesi veya yeniden kullanması değerlendirmeye katılır; eski bir silme planı körlemesine uygulanmaz.
- Sabitlenmiş sohbetler otomatik temizlenmez. Sabitleme, canlı CLI'ı sürekli açık tutma anlamına gelmez.
- Korunması gereken worktree durumu varsa ilgili sohbet otomatik temizlenmez. İtilmemiş commit ve kaybedilebilecek yerel değişiklikler bu korumanın uygulamada kontrol edilecek örnekleridir.
- Tamamlanmamış yetkilendirilmiş bir görevin kaynağı veya hedefi olan sohbet otomatik temizlenmez.
- Uygulamanın uzun süre kapalı kalmasından sonraki toplu silme, kullanıcıya liste gösterilip onay alınmadan yapılmaz.
- Temizlik de elle silmeyle aynı doğrulama ve hata kurallarını kullanır.

**Henüz kesinleştirilmeyen politika ayrıntıları:** Aylık çalıştırmanın takvim ayına mı son çalıştırmaya mı bağlı olduğu; stale bir oturumu görüntülemenin otomatik silme bekleme süresini etkileyip etkilemediği; “uzun süre kapalı” eşiği. Otomatik silme etkinleşmeden önce bu kurallar tek bir hesaplama olarak netleşmeli. “15 gün kullanılmama + en az 15 gün stale” koşulu, her sohbetin tam 30. günde silineceği anlamına gelmez.

Uygulama kapalıyken temizlik için sürekli bir Loom servisi hedeflenmiyor. Açılışta ve uygulama açıkken seyrek kontrol aday uygulamadır. Her kayıt için ayrı timer gerekmez.

Sağlayıcının kendi saklama politikası Loom'dan önce geçmişi kaldırabilir. Böyle bir kayıt çalıştırılabilir gibi gösterilmemeli; “sağlayıcı geçmişi bulunamadı” durumu açık olmalıdır. Sağlayıcı dosyalarının saklanma süresinin Loom politikasıyla nasıl uyumlandırılacağı silme/retention deneyinin parçasıdır. [Claude veri saklama](https://code.claude.com/docs/en/claude-directory)

## 6. Süreç sahipliği ve uygulamadan çıkış

Normal Quit işleminin kabul ölçütü: **Loom'un başlattığı ve sahip olduğu çalışan iş kalmaz; Loom dışındaki kullanıcı oturumlarına dokunulmaz.** Bu kapsam CLI, alt ajan, arka plan shell'i, dev server, oturuma ait MCP/LSP gibi yardımcılar ve varsa Loom'a ait sağlayıcı sunucusunu içerir.

Kapatma sırası yeni işleri engelleme, sahip olunan çalışmaları durdurma, sonlanmayı doğrulama ve kalıcı işlemleri tutarlı biçimde bitirmeyi kapsamalıdır. Kapatma doğrulanamıyorsa uygulama bunu başarı gibi sunmamalıdır.

Claude Agent View, yalnızca Loom tarafından başlatılan oturumlarda devre dışı bırakılabilir. Bu seçenek belgelenmiştir; diğer terminal oturumlarının global ayarları değiştirilmez. [Claude ortam seçenekleri](https://code.claude.com/docs/en/env-vars)

Codex için iki yol deneyle karşılaştırılacak:

1. Loom'a ait app-server ve ona bağlanan gerçek Codex TUI.
2. Paylaşılan daemon kullanımını kapatan doğrudan Codex TUI.

Kurulu codex-cli 0.157.1'de `daemon_auto_start` özelliği açık ve `--no-daemon` seçeneği bulunuyor; düz `codex` komutunun paylaşılan daemon'ı kendiliğinden başlatıp başlatmadığı doğrulanmadı. Bu, 1. checkpoint'in ilk sorusudur.

Başka uygulamaların veya kullanıcının terminalinin paylaşılan Codex sunucusu Loom'a ait kabul edilmez. Önlenemeyen veya sahipliği belirsiz daemon davranışında “nasıl olsa çıkışta öldürürüz” yaklaşımı uygulanmaz.

Süreç grupları, PID + başlangıç zamanı ve ortam işaretleri inceleme adaylarıdır. **Bunlar tek başına tüm süreçlerin bulunup kapatılacağını kanıtlamaz.** Ön kontrolde ortam işareti, aynı kullanıcıya ait Apple dışı bir binary'de `KERN_PROCARGS2` ile okunabildi; `/bin/sleep` gibi Apple platform binary'lerinde görünmedi. Bu yüzden işaret taraması tek başına yeterli değildir. Üst sürecin ölmesi çocukları doğrudan sonlandırmaz; terminal kapanması da bütün torunlar için garanti değildir. [POSIX süreç sonlandırma](https://pubs.opengroup.org/onlinepubs/9799919799/functions/_exit.html)

Normal Quit, uygulama çökmesi ve Force Quit ayrı test senaryolarıdır. Sonraki açılışta kalıntı temizlemek bir kurtarma yolu olabilir; kapalı kalınan sürede sıfır kaynak garantisi sayılmaz. Çökme sonrası davranış kanıtlanmadan normal çıkış testinin sonucu bu senaryoya genellenmez.

Pencere kapatma düğmesinin tam çıkışla aynı mı farklı mı davranacağı hâlâ açık ürün kararıdır.

## 7. Kullanıcının yönetiminde oturumlar arası koordinasyon

Hedef, Claude ve Codex oturumlarının kullanıcı tarafından yetkilendirilen işler için birbirini bulabilmesi, görev iletebilmesi ve sonucu takip edebilmesidir. Bu hedef yalnızca kopyala/yapıştır özelliğine indirgenmiş değildir.

Yetkilendirme ve görev yürütme ayrı düşünülür:

- Kullanıcı bir hedefe tek mesajı veya kapsamı belli bir görev akışını yetkilendirebilir.
- Yetki olmadan oturumlar kendiliğinden yeni işler başlatmamalıdır.
- Kullanıcının verdiği görevin sınırları dışına çıkan bir zincir otomatik yetkilendirilmiş sayılmaz.
- Ajan mesajı, başka bir oturumun bekleyen araç/işlem onayına kullanıcı adına cevap değildir.

Mesajın kaydedilmesi, sağlayıcıya iletilmesi, hedef tarafından kabul edilmesi ve görevin tamamlanması farklı aşamalardır. Taşıma yanıtı veya bir ajanın “bitti” demesi, Loom'un kontrolündeki işlemlerin gerçekten yapıldığına tek başına kanıt değildir. Sonuç bildiriminin kaynağı anlaşılır olmalıdır.

Belirsiz teslimde kör otomatik tekrar yapılmamalı; çökme veya yeniden bağlantı aynı işi iki kez çalıştırmamalıdır. Kuyruk kullanılacaksa kalıcılık, iptal, süre/boyut sınırları ve silinen hedefe geç mesaj davranışı tanımlanmalıdır. Uygulama kapalıyken zaten kaydedilmiş görevler saklanabilir; kapalı bir uygulamanın yeni gelen işleri kendiliğinden alacağı varsayılmaz.

### Teknik adaylar ve sınırlar

- **Ortak MCP arayüzü:** Her iki CLI destekliyor. Oturum bulma, görev verme ve sonuç okuma için aday; gelen mesajın hedefe teslimini tek başına çözmez.
- **Codex app-server:** Olay ve tur kontrolü için aday. Gerçek TUI ile eşzamanlı kontrol, onayların hangi istemciye gittiği ve kaynak sahipliği sınanmalı. `turn/start` ve `turn/steer` belgelenmiş; `thread/queue/*` ise resmî app-server sayfasında yok, yalnızca kurulu sürümden üretilen şemada ve `codex queue` komutunda görülüyor. Görev devri kuyruğa dayanırsa belgelenmemiş arayüz olarak ele alınmalı.
- **Claude cross-session messaging:** Gerçek bir yerel iletişim olanağı. Harici Loom entegrasyonunun belgelenmiş sözleşmesi ve kullanıcı yetkisiyle uyumu doğrulanmadan temel bağımlılık yapılmamalı.
- **Claude Channels/hooks:** Alternatif entegrasyon yolları. Preview, dağıtım, teslim onayı ve ek süreç maliyetleri değerlendirilir. Hook'lar tur sırasında veya tur sonunda çalışır; istemde boşta bekleyen canlı oturum için belgelenmiş aday `asyncRewake` hook'udur ve oturum başına bekleyen bir süreç gerektirir. Süreç çalışmıyorsa sohbet, CLI'ın resume yoluyla promptla açılabilir.
- **Metin aktarma:** Kullanıcının hedef terminale metin taşıması için ayrı bir kolaylık olabilir. Bracketed paste, hedefin doğru prompt alanında olduğunu veya görevi kabul ettiğini kanıtlamaz.

Claude'un cross-session messaging özelliği varsayılan olarak açıktır ve Claude gerek gördüğünde kullanıcıya sormadan diğer yerel oturumlara mesaj gönderebilir. Bu varsayılan, yukarıdaki yetki kuralıyla çelişir; Loom'un yönettiği Claude oturumları bu davranış ele alınmadan başlatılmamalıdır. Asgari önlem adayı, oturuma özel ayarla `crossSessionInbound: refuse` vermektir. Bu ayar yalnızca gelen mesajları engeller: Loom oturumundan Loom dışındaki bir oturuma giden mesaj açık kalan bir boşluktur ve bütün giden iletişimi yönetmenin eşdeğeri değildir. `SendMessage` aracını yasaklamak subagent ve ekip mesajlaşmasını da kapattığı için çözüm olarak kullanılmamalı; yetkilendirme davranışı subagent işlevleri korunarak ayrıca tasarlanmalıdır. [Claude oturumlar arası iletişim](https://code.claude.com/docs/en/cross-session-messaging)

Görev devri, bütün sohbet geçmişinin veya harness iç durumunun diğer sağlayıcıya çevrilmesi anlamına gelmez. Gerekli görev bağlamı ve sonuç yeterliyse transkriptlerin ikinci kopyası tutulmamalıdır.

## 8. Kalıcı silme sözleşmesi

Silme, oturumu gizlemek veya idle'a almak değildir. Kullanıcının “tamamen silme” beklentisi ürün hedefidir; teknik olarak verilecek garanti, kontrol edilebilen yerel veri kapsamı açıkça tanımlanıp doğrulandıktan sonra sunulur.

Silme işlemi şunları kapsamalıdır:

1. Yeni mesaj, çalışma ve yeniden başlatma girişlerini durdurmak.
2. Oturuma bağlı bekleyen işleri ve ilgili teslimleri iptal etmek.
3. Sahip olunan canlı çalışmaları sonlandırıp doğrulamak.
4. Loom'un katalog, önbellek ve oturuma ait verilerini temizlemek.
5. Sağlayıcının bu sohbete ait, güvenle sahiplenilebilen yerel verilerini tanımlanmış kapsamda temizlemek.
6. Kayıtların listeleme, yeniden açılış ve devam yollarından geri gelmediğini doğrulamak.
7. Başarıyı ancak kapsam tamamlanınca göstermek.

Yarım silme görünür ve tekrar denenebilir olmalıdır. Katalog kaydını erken kaldırıp kalan sağlayıcı verisini sahipsiz bırakmak kabul edilmez. Silme sürerken kurtarma kaydı tutulabilir; tamamlandıktan sonra kalıcı bir silinmiş-ID listesi gerekip gerekmediği, geç olay ve mesaj davranışıyla birlikte belirlenecek. Sonsuza kadar büyüyen bir kayıt varsayılan çözüm değildir.

Claude `rm`, transkripti kaldıran tek sohbet silme komutu değildir; `project purge` ise daha geniş proje kapsamına sahiptir. Codex `thread/delete` ve `codex delete` kullanılabilir adaylardır; yardımcı verilerin kapsamı ayrıca kontrol edilmelidir. [Claude oturumları](https://code.claude.com/docs/en/sessions), [Codex App Server](https://learn.chatgpt.com/docs/app-server)

**Ortak veride veri kaybı oluşturulmaz.** Başka CLI oturumlarının yazdığı bir `history.jsonl` dosyasını boyut kontrolü ve atomik değiştirmeyle yeniden yazmak, eşzamanlı eklemeleri korumaya yetmez. Desteklenen API, ortak yazma koordinasyonu veya uygun veri sahipliği çözülmeden bu yöntem uygulanmaz. O zamana kadar kullanıcıya sunulan silme ifadesi ortak prompt geçmişini kapsamaz. `CLAUDE_CODE_SKIP_PROMPT_HISTORY` transkript yazımını da kapattığı ve resume'u bozduğu için çözüm değildir. [Claude ortam seçenekleri](https://code.claude.com/docs/en/env-vars)

Silme kapsamı için açık sınırlar:

- Başka oturuma gönderilmiş içerik ve ortak hafıza, tek sohbet verisi gibi varsayılarak silinmez.
- Projedeki kod, kullanıcı dosyaları ve worktree'ler sohbet silmenin otomatik yan etkisi değildir.
- Uzak sağlayıcı kopyaları, dışa aktarımlar ve yedeklerin yok olduğu iddia edilmez.
- SQLite satır silme, dosyanın küçülmesi ve silinmiş içeriğin fiziksel izlerinin temizlenmesi farklı konulardır. WAL ve günlük davranışı da veri politikasına dahildir.

Kesin yerel veri envanteri ve kullanıcıya sunulacak silme ifadesi, silme checkpoint'i geçmeden tamamlanmış sayılmaz.

## 9. Mimari yön ve güncelleme stratejisi

**Teknik aday:** Loom içinde modüler bir koordinatör; ayrı süreç sahipliği, katalog, yaşam döngüsü, sağlayıcı uyarlayıcıları ve terminal sunumu sorumlulukları. Çekirdek dili Swift olarak kabul edildi (§3). Küçük bir kalıcı katalog için SQLite; macOS arayüzü için SwiftUI/AppKit adaydır. Bunlar henüz ölçümle seçilmiş teknoloji kararları değildir.

Terminalin her karakterini mesaj kuyruğu veya JSON katmanından geçirmek zorunlu değil. Sürekli çalışan ayrı Loom daemon'ı başlangıç ihtiyacı olarak kabul edilmedi. Uygulamaya bağlı bir yardımcı gerektiği kanıtlanırsa kendi kaynak ve kapanma maliyetiyle değerlendirilir.

Sağlayıcı entegrasyonlarında:

- Belgelenmiş arayüzler tercih edilir; özel dosya ve soket biçimleri değişmez kabul edilmez.
- CLI yolu/sürümü değiştiğinde ilgili yetenek kontrolleri yenilenir. Her açılışta pahalı bir tam tarama yapılması hedeflenmez.
- Şema kontrolü arayüzün varlığını; davranış deneyi ilgili garantiyi doğrular. Biri diğerinin yerine geçmez.
- Bilinmeyen bir olaydan “iş bitti”, “onaylandı” veya “kapandı” sonucu çıkarılmaz.
- İsteğe bağlı görünüm özelliği bozulursa o özellik kapatılabilir. Temel sahiplik/kapatma garantisi bozulursa yönetilen oturum normalmiş gibi başlatılmaz.
- Kullanıcının global CLI ayarları sahiplenilmez; Loom entegrasyonu oturuma özel ve kaldırılabilir olmalıdır.
- Gerçek sohbet kimliği, Loom katalog kimliği ve o anki çalıştırma kimliği ayrı tutulur. Aynı sohbetin eşzamanlı sahiplenilmesi ve eski çalıştırmadan gelen olaylar ele alınır.

Oturuma özel entegrasyon için belgelenmiş, henüz Loom akışında sınanmamış adaylar:

- **Claude:** `--session-id` ile kimliği başlangıçta atamak; `--settings` ile yalnızca o oturuma hook ve ayar vermek; her olayda süreç başlatmayan `http` hook tipi; `Stop` hook'undaki `last_assistant_message` alanı.
- **Codex:** `thread/status/changed` olayındaki onay/girdi bekleme bilgisi; arka plan işleri için `thread/backgroundTerminals/*`; silme için `thread/delete` veya `codex delete`.

### Herdr Desktop'tan taşınan teknik dersler

- **Ortam mirası gerçek hata kaynağıdır:** Loom bir Claude oturumunun içinden açılırsa `CLAUDE_CODE_*` gibi üst oturum değişkenleri (oturum kimliği, mesajlaşma soketi ve token'ı dahil) başlatılan CLI'lara sızabilir. Loom'un kendi oturum sınırı açık kurulmalı; yönetilen süreçlerin ortamı bilinçli oluşturulmalı.
- **Başlatma ve kapatma tek işlem zinciridir:** Başlatma başarısızsa hayalet canlı kayıt kalmamalı; çıkış, silme ve arka plan kayıt yazımı yarışmamalı. Süreç ağacının yeniden ebeveynlenmesi ve yeni Unix session açılması test edilmeli.
- **Hook sayısı mimari tercihtir:** Olay başına süreç başlatan ve dosya yazan hook'lar ek maliyettir. Codex her hook kaydını ayrı güven onayına tabi tutabilir; kayıtları tek dosyada toplamak onayları birleştirmez. Terminal ekranından durum çıkarmak ise CLI arayüzü değişince bozulabilir. Karma yöntem seçilirse hangi durumun hangi kaynaktan geldiği ve çakışma kuralı açık olmalı.
- **İzin UX'i ürünün parçasıdır:** Otomatik güven verme, sağlayıcının güven veya izin kontrolünü atlama ya da kullanıcıya açıklanmamış çoklu onay çıkarmak kabul edilmez.
- **Geliştirme ve günlük kullanım ayrı olmalı:** Geliştirme sürümü ayrı bundle kimliği ve veri dizini kullanmalı; denemeler gerçek oturumlara ve kataloğa dokunmamalı. Sabit bir yerel imza, macOS izinlerinin her kurulumda yeniden istenmesini önler. Yalnızca derlemenin geçmesi tamamlandı kanıtı sayılmaz.

## 10. Kaynak ve performans kabulü

Az kaynak tüketimi yalnızca uygulama paketinin veya Loom ana sürecinin boyutu değildir. Loom, sağlayıcı süreçleri, alt işler ve arayüz/WindowServer etkisi ayrı ölçülmelidir.

Ölçülecek koşullar: boş uygulama, bir ve birden çok çalışan oturum, çok sayıda idle/stale kayıt, yoğun terminal çıktısı, hızlı oturum geçişleri, görünür/gizli pencere ve uzun süreli kullanım. Önerilen başlangıç ölçekleri 1, 10 ve 50 oturumdur.

Ölçüm birimleri doğrulanmalı: macOS `proc_pid_rusage` CPU değerleri Mach tick dönüşümü ister; %100 CPU bir mantıksal çekirdektir. `proc_listchildpids` dönüşü PID sayısıdır. RSS ile physical footprint farklıdır; çocuk süreç bellek toplamı paylaşılan sayfaları çift sayabilir. Ölçüm aracının kendi maliyeti ayrıca kaydedilir.

Kontrol edilecek davranışlar:

- Görünmeyen terminaller gereksiz çizim yapmamalı; yaşayan işler için çıktı işleme ve tampon kullanımı sınırlı olmalı.
- Çalışma animasyonu bütün arayüz ağacını her karede yenilememeli; gizli veya etkin olmayan pencerede animasyon ve çizim durmalı.
- Idle/stale kayıtlar için canlı terminal oluşturulmamalı.
- Transkript, scrollback, log ve kuyruklar sınırsız büyümemeli.
- Geçmişin tamamı her yenilemede okunmamalı; görünüm gerektiği kadar veri yüklemeli.
- Günlük ve bakım işlemlerinin kendi maliyeti de ölçülmeli. SQLite incremental vacuum seçilirse ayrıca ne zaman çalıştırılacağı tanımlanmalı.

Eski Herdr GPU sorununun kök nedeni kanıtlanmış değil. Aynı terminal yüküyle **cam/opak arka plan × boşta/çıktı** deneyi, görünür ve örtülü pencere koşullarında yapılmalı. Gerekirse animasyon etkisi ayrı deneyle ölçülür. CPU gözlemlerinden GPU sonucu çıkarılmaz. [Apple çizim verimliliği](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)

Sayısal bellek, CPU, GPU ve gecikme bütçeleri henüz belirlenmedi. İlk ölçüm checkpoint'inde kaydedilip kabul edilmeden “hafiflik doğrulandı” denmez.

## 11. Geliştirme checkpoint'leri

Her checkpoint sonucu **doğrulanan / başarısız / doğrulanmayan** olarak kaydedilir. Sentetik veri ve Loom'a ait test süreçleri kullanılır. Kullanıcı verisi, başka uygulamaların süreçleri ve gerçek sohbet geçmişi deneme malzemesi değildir.

| Checkpoint | Bitmiş sayılması için gereken kanıt |
| --- | --- |
| 1 — Sahiplik ve başlatma | Claude Agent View kapalı yol ve iki Codex yolunun karşılaştırılması; doğru süreç/sohbet sahipliği; dış oturumların etkilenmemesi; normal Quit sonrası kalıntı olmaması. Çökme/Force Quit sonucu ayrıca raporlanır. |
| 2 — Durum ve devam | Kimlik, tur, hata ve onay durumlarının kaynağı belli; güvenli idle geçişi ve aynı sohbetten resume çalışıyor; sağlayıcı önbelleği ile canlı iş birbirinden ayrılıyor. |
| 3 — Yetkilendirilmiş koordinasyon | Kullanıcının verdiği görev kapsamında iki yönde teslim ve sonuç takibi; hedef çalışırken, beklerken ve yeniden bağlanırken doğru davranış; belirsiz teslim ve çift çalıştırma yönetiliyor. Belirleyici durum: canlı ve istemde boşta bekleyen Claude TUI'sine yalnızca belgelenmiş arayüzlerle teslim. Yetkisiz oturumlar arası mesajın engellendiği de gösterilir. |
| 4 — Silme ve saklama | Yerel veri kapsamı tamamlanmış; başka oturumun verisine zarar vermeden silme; yarım işlemden kurtarma; geç olayla geri gelmeme; stale/istisna/takvim kuralları örnek zaman çizelgelerinde doğru. |
| 5 — Görsel deneyim ve performans | Tasarım/ikon hedefi korunmuş; kaynak ve gecikme ölçümleri kabul edilen bütçelerde; geçmiş büyümesi ve gizli pencere davranışı doğrulanmış. GPU deneyi diğer checkpoint'lerden bağımsız yürütülebilir. |

Bu sıra, tüm uygulamayı kurmadan yüksek riskli iddiaları dar deneylerle sınamak içindir. Bir sonraki adıma geçmek, önceki checkpoint'in bilinmeyenlerini gizlemek anlamına gelmez.

## 12. Kalan kararlar

Ürün amacı ve temel davranışlar büyük ölçüde net. Uygulamadan önce bütün teknik ayrıntıları seçmek gerekmiyor; fakat şu sonuçlar açık bırakılmamalı:

1. **Çıkış sınırı:** Normal Quit dışında çökme/Force Quit için hangi garanti gerçekten verilebiliyor; pencere kapatma nasıl davranacak?
2. **Başlatma ve iletişim yolu:** Hangi Codex çalışma yolu ve Claude teslim mekanizması, sahiplik ve güncelleme şartlarını birlikte karşılıyor?
3. **Veri sözleşmesi:** Güvenli tek sohbet silmenin kesin yerel kapsamı, ortak dosyaların yönetimi ve sağlayıcı retention uyumu.
4. **Temizlik hesabı:** Aylık takvim, stale görüntülemesinin sayaca etkisi ve uzun kapalı kalma eşiği.
5. **Ölçülebilir bütçeler:** Kabul edilen kaynak, ölçek ve etkileşim sınırları.

Bu maddeler yeni ürün fikirleri bekleyen boşluklar değil; kabul edilen deneyimi gerçekte sağlayabilmek için gereken karar ve kanıt kapılarıdır.

## 13. Kapsam kararı alınmamış fikirler

Kullanıcının daha önce dile getirdiği fikirler. İlk sürüme veya uygulama sırasına otomatik olarak girmezler:

- Ana bağlamdan açılan, yazışması ana sohbete eklenmeyen side chat ve sağ panel.
- Sağ panelde alt görevlerin daha kapsamlı izlenmesi.
- ChatGPT/Claude kullanım hakkı ve kalan limitlerin gösterilmesi.
- Proje içindeki sohbetlerin oluşturulma sırasına göre sabit kalması; ayrıca son etkinliğe göre sıralanan ayrı bir görünüm.
- Önceden var olan sağlayıcı geçmişini içe alma ve tam transkript araması.
- Claude ve Codex dışındaki harness'lar (OpenCode, Antigravity vb.).
