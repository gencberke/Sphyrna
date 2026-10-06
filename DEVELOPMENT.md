# Loom geliştirme rehberi

İş akışı [AGENTS.md](AGENTS.md), ürün ve mimari sınırlar [ürün sözleşmesi](LOOM-PRODUCT-CONTRACT.md), slice'a özgü kabul ölçütleri ilgili slice dosyasındadır. Burada yalnız çalışma yöntemi tutulur.

## Kontroller

Kod değişikliklerinde `swift build`, `git diff --check` ve değişen davranışı veya etkilenmesinden endişe edilen komşu davranışları kapsayan testler çalıştırılır (`swift test --filter …`). Her revize veya implementasyon sonrasında tam suite zorunlu değildir; tam suite checkpoint kapanışında veya büyük revizyon/implementasyon sonrasında çalıştırılır. Test kapsamı değişikliğin riskine göre seçilir ve raporda belirtilir. Yeni/izlenmeyen dosyalar da diff incelemesine dahil edilir. Yalnız dokümantasyon değiştiyse bağlantı, içerik tutarlılığı ve whitespace kontrolü yeterlidir.

`swift test` makro eklentisini bulamazsa:

```sh
swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

Değişen C katmanı `clang -Wall -Wextra -Werror` ile temiz olmalıdır; `fork` sonrası yalnız async-signal-safe çağrılar yapılır. Testler gerçek kabul davranışını veya regresyonu sınar; regresyon testinin düzeltme olmadan başarısızlığı gösterilir.

Planner-reviewer kabul senaryolarını bağımsız doğrular. Aynı kaynak durumu için geçerli kontroller gereksiz yere tekrarlanmaz; değişen girdiler, başarısız sonuç veya kanıt açığı varsa ilgili kontrol yeniden çalıştırılır. Test başarısı, denenmemiş UI veya gerçek sağlayıcı davranışının kanıtı değildir.

## İzolasyon ve kanıt

- Kullanıcının gerçek `~/.claude`, `~/.codex`, çalışan oturumları ve ChatGPT.app yalnız okunur; test verisi değildir. Geçici test kökleri ve izole sağlayıcı profilleri kullanılır.
- Kalıcı deney alanı: `~/Library/Application Support/Loom-Dev/probe/`. Claude profili burada `claude-config`; Codex profili Darwin `sun_path` sınırı nedeniyle `~/.loom-dev/codex-home` yolundadır. Testler önceki kanıtları veya ortak deney kökünü temizlemez.
- Gerçek Claude/Codex testleri zorunlu kabul kanıtıdır ve ayrıca izin istenmeden çalıştırılır (2 Ekim 2026 kullanıcı kararı). Kabul için gereken kısa model turları bu kapsamdadır. Yalnız büyük bütçe tüketecek işler önceden kullanıcıya sorulur: uzun otonom görevler, yüksek hacimli tekrarlar veya pahalı model seçimi. Testler izole profillerde (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) yapılır; harcanan tur sayısı kanıta yazılır.
- Kanıt: çalıştırılan komut, sonucu, run kimliği ve dosya yolu. Kalıcı kayıt probe alanında veya değerlerden arındırılmış `plans/experiments/` altında tutulur. Token, kimlik bilgisi ve ortam değerleri kayda girmez.
- Paket/süreç deneylerinde ilgili planın izolasyon koşullarını izle; sahiplik güvencesi dar bir deneyden bütün ürüne genellenmez.

## Yerel geliştirme imzası

Bu Mac'te `Loom Dev Code Signing` login keychain kimliği kurulu; paket scripti bu adı öncelikle seçer. Yeni sertifika her derlemede üretilmez. Açık seçimle identity yokluğunda build'i durdurmak için `LOOM_CODESIGN_IDENTITY=223E8AC2708373C99E1D8CF82AF2D23114F884AD scripts/package-dev-app.sh` kullanılır. Ana uygulama ve run host aynı leaf sertifikasına bağlanır. Özel anahtar repoya veya loga girmez; güven yalnız kullanıcı codeSign politikasındadır. 3 Ekim 2026'da yalnız bu özel anahtar ("Imported Private Key") için `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "Imported Private Key"` kullanıcı tarafından çalıştırıldı; `codesign` artık parola sormaz. Ekran kilitliyken imzalama SecurityServer'da bekler; paketleme kilit açıkken yapılır.

[İmza kanıtı](plans/experiments/cp5-stable-signing.json) farklı iki pakette Belgeler izninin tekrar istenmediğini doğrular. Bundle kimliği, signer veya kurulum yolu değiştirilirse eski TCC kabulü kendiliğinden geçerli sayılmaz.

## Ölçüm

Kaynak kabulü ve birimlerin anlamı için [sözleşme §10](LOOM-PRODUCT-CONTRACT.md#10-kaynak-ve-performans-kabulü) esas alınır. Loom, sağlayıcılar ve WindowServer ayrı değerlendirilir; CPU ölçümünden GPU sonucu çıkarılmaz.

Gerçekçi ve tekrarlanabilir yük seç; sentetik ve gerçek sağlayıcı sonuçlarını ayır. Süreyi, girdiyi, ısınmayı, tekrar sayısını ve kullanılan komutu kaydet. Planda farklı yöntem tanımlanmadıysa karşılaştırmalı performans iddiası için en az beş tekrar, medyan ve dağılım raporla. Kazancı mutlak birimle ver ve ölçüm gürültüsüyle karşılaştır. Ölçülmemiş algoritmik maliyet veya yapısal bulguyu sayısal kazanç diye sunma.

Görünür pencere ölçümünde Loom penceresi örtülmemeli (ölçüm betiği pencereyi öne getirmez; önde tam ekran bir pencere hücreyi geçersiz kılar), ekran kilitlenmemeli ve aynı anda build/test çalışmamalıdır. Fansız Mac14,2'de ardışık yoğun koşular ısıl sapma yaratır; karşılaştırmalarda dönüşümlü sıra ve soğuma aralığı kullan.

Araçlar: `proc_pid_rusage`, `top -l`, `ps`, `sample`, `vmmap`, `time` ve `loom-probe`. Geçici ölçüm betikleri `/tmp` altında tutulabilir; kalıcı kanıtı ayırdıktan sonra yalnız kendi geçici dosyalarını temizle. Ayrı yetki gerektiren ölçümler mevcut kullanıcı yetkisi olmadan çalıştırılmaz.

29 Eylül 2026 başlangıç ortamı kaydı: macOS 27, Swift 6.4, Command Line Tools; Xcode/Instruments yok. Bu kayıt kurulum şartı değildir; gerekirse mevcut ortamı doğrula. Sağlayıcı sürümleri kullanıcı adına sabitlenmez.
