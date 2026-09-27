# Geliştirme başlangıcında rc süreçlerinin tam izolasyonu

**Durum:** Planlandı; uygulanmadı. Kullanıcı kararı: küçük düzeltmeler tamamlanacak, tam izolasyon ayrı çalışma olacak.
**Dayanak:** [CP1 §16](CHECKPOINT-1.md#16-review-takibi).

## Sorun ve mevcut sınır

Terminalden çalışan Loom ortak resource coalition içindedir. Ortam çözücü shell artık başlatılmadan önce run işareti alır; ayrılmış süreç grubunun üyeleri shell kimliği hâlâ rezerveyken kaydedilir. Gözlenen torunlar ve okunabilir run işaretleri de mevcut sahiplik mekanizmasına katılır. Bunlar uygulama çıkışında PID ve başlangıç zamanı doğrulanarak temizlenir.

Gerçek `/usr/bin/ssh-agent -s` deneyi, hızlı daemonlaşan ve ortamı okunamayan sürecin bu yöntemlerle gözlemden kaçabildiğini gösterdi. Süreç grubunu/oturumunu değiştiren, üst süreçten ayrışan ve işareti okunamayan süreçler için terminal geliştirme yolunda tam garanti yok. PID adı, başlama zamanı yakınlığı, ortamdan dönen SSH_AGENT_PID veya kullanıcı kimliği tek başına sahiplik kanıtı değildir; bunlara dayanarak sinyal gönderilmez.

## Amaç

Terminalden geliştirme başlatmasında da rc çalışmadan önce ayrı, doğrulanmış resource coalition veya eşdeğer güvenilir sahiplik sınırı kurmak. Kullanıcının mevcut SSH ajanına ve diğer oturumlarına dokunmadan, Loom'un rc üzerinden başlattığı daemonları çıkışta ve çökme sonrası kurtarmada temizlemek.

## Uygulama adımları

1. LaunchServices ile başlatılan küçük bir yardımcı `.app` ve geliştirme girişinin uygulama üzerinden yürütülmesini karşılaştır. CLI argümanları, stdout/stderr, çıkış durumu, çalışma dizini ve sinyallerin aktarımını tanımla; ürün akışına gereksiz seçenek ekleme.
2. İzolasyonu herhangi bir rc çalıştırmadan önce doğrula. Doğrulama başarısızsa tam temizlik iddiasında bulunma; mevcut dar garantiyi açık raporla.
3. Yardımcı kimliğini, boot kimliğini ve sahiplik kanıtını kalıcı ledger'a yaz. Ortam çözücü başarısızlığını, yeniden denemeyi, normal çıkışı ve SIGKILL sonrası kurtarmayı kapsa.
4. Mevcut doğal zsh başlangıcını, 30 saniye sınırını, stdin EOF ve çıktı sınırını koru. Kullanıcının gerçek rc ve CLI profillerini değiştirme.

## Kabul ve kontroller

- Sentetik `.zshrc` içinden gerçek `ssh-agent` başlat: soket oturum boyunca çalışmalı; normal Quit ve başarısız başlangıç temizliğinden sonra süreç kimliği kalmamalı.
- Owner SIGKILL sonrası sonraki başlangıç aynı daemonı kalıcı kayıt üzerinden temizlemeli.
- Deneyden önce çalışan ayrı kontrol ajanının kimliği ve erişilebilirliği değişmemeli; hiçbir sinyal raporunda yer almamalı.
- Hızlı çift fork, yeni session/process group, işaretsiz Apple binary ve kimlik yeniden kullanımı sınırları test edilmeli.
- Gerçek uygulama ve terminal girişinde aynı kabul matrisi geçmeli; mevcut A9a–A9f ve ortam testleri tekrar çalışmalı.
- Kanıtlar `.build` yerine probe kökünde kalıcı tutulmalı; raporlarda ortam değerleri yer almamalı.

Bu plan ayrı izolasyon çalışmasının kapsamıdır; CP2'nin oturum devamı işlerini içermez.
