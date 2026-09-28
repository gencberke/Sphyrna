# Loom ajan rolleri

Bu klasör, Loom geliştirmesinde çalışan ajanların rollerini ve birbirleriyle nasıl haberleştiklerini tanımlar. Roller araçtan bağımsızdır; Claude Code, Codex ya da başka bir ajan tarafından yüklenebilir. Kullanıcının global talimatları (dil, onay, commit kuralları) her rolde geçerlidir. Burada yalnızca Loom'a özgü kurallar vardır.

| Rol | Dosya | Ne yapar | Kod yazar mı? |
| --- | --- | --- | --- |
| Reviewer | [reviewer.md](reviewer.md) | Planlar, brief hazırlar, implementasyonu review eder, yeniden planlar. Kullanıcının ana muhatabıdır. | Hayır |
| Implementer | [implementer.md](implementer.md) | Plan bölümlerini uygular, kabul maddelerini kanıtla doğrular. | Evet |
| Optimizer | [optimizer.md](optimizer.md) | Kod ve kaynak performansını ölçerek inceler; yalnızca gerçek bir kazanç kanıtlayabildiğinde öneri verir. Genellikle reviewer'ın alt ajanıdır. | Hayır |

## Döngü

1. **Reviewer** planı yazar (`plans/CHECKPOINT-<n>.md`), gereken ürün kararlarını kullanıcıya sorar ve implementer için bir brief hazırlar.
2. **Kullanıcı** brief'i implementer'a verir. **Implementer** uygular ve plan dosyasına bir sonuç bölümü ekler.
3. **Kullanıcı** sonucu reviewer'a getirir. **Reviewer** iddiaları doğrular, gerekirse **optimizer**'ı çağırır ve bulguları plan dosyasına yazar.
4. Engelleyici bulgu varsa 2. adıma dönülür. Yoksa checkpoint kapanır ve sonraki plan yazılır.

## Tek doğru kaynaklar

- `LOOM-PRODUCT-CONTRACT.md`: ürün sözleşmesi. §3'teki kararlar yalnızca kullanıcı onayıyla değişir. §11 checkpoint'leri ve uygulama sırasını tutar.
- `design/DESIGN.md`: sabit görsel sözleşme.
- `plans/CHECKPOINT-<n>.md`: plan, uygulama sonucu ve review aynı dosyada, bölüm bölüm tutulur. Güncel checkpoint en yüksek numaralı dosyadır; önce durum satırını ve son bölümleri oku.

Sohbet geçmişi kaynak değildir. Kalıcı olması gereken her şey bu dosyalara yazılır.

## Plan dosyası protokolü

- **Numaralı bölümler:** Bölümler numaralıdır ve yalnızca eklenir. Bir rol başka bir rolün bölümünü değiştirmez; düzeltme gerekiyorsa yeni bölümde referans vererek yazar.
- **Durum satırı:** Tek istisna dosya başındaki **Durum** satırıdır. Onu en son bölümü yazan rol günceller.
- **Bölüm türleri ve sahipleri:**

  | Bölüm | Sahibi |
  | --- | --- |
  | `## N. …` plan bölümleri ve alt bölümleri | reviewer |
  | `## N. Uygulama sonucu (tarih)` | implementer |
  | `## N. Review (tarih)` | reviewer. Bulgular numaralıdır; her bulguda dosya:satır, neden önemli, beklenen davranış ve kabul ölçütü bulunur. |
  | `## N. Optimizasyon incelemesi (tarih)` | reviewer. Optimizer raporundan yalnızca kendi doğruladığı bulguları yazar. |

- **Bulgulara cevap:** Implementer her bulguya numarasıyla cevap verir: "§22 madde 1 — çözüldü / kısmen / çözülmedi", ardından kanıt.
- **Durum etiketleri:**
  - **doğrulandı:** kanıtla gösterildi.
  - **başarısız:** denendi, tutmadı.
  - **doğrulanmadı:** yapılmadı ya da kanıt yok.

  "Tamamlandı" yalnızca bütün kabul maddeleri doğrulandıysa yazılır.
- **Kanıt:** run kimliği, komut, dosya yolu. Kalıcı kanıt `~/Library/Application Support/Loom-Dev/probe/` altında ya da değerlerden arındırılmış olarak `plans/experiments/` altında tutulur. Ortam değeri, token ve kimlik bilgisi hiçbir yere yazılmaz.

## Handoff biçimleri

- **Brief** (reviewer → implementer ya da optimizer): `Goal / Context / Scope / Done when / Checks`. Ayrıntı tekrar edilmez, plan bölümüne referans verilir.
- **Report** (implementer ya da optimizer → çağıran): `Status / Result / Evidence / Unverified / Needs`.

## Ortak kurallar

- **Dil:** Kullanıcıyla Türkçe ve sade dil. Teknik ayrıntı plan dosyasına yazılır, sohbete değil.
- **Kararlar:** Ürün kararı kullanıcınındır. Teknik varsayılanı rol kendisi seçer ve ne seçtiğini belirtir.
- **Deneyler:**
  - İzole profillerde yapılır.
  - Kullanıcının gerçek `~/.claude` ve `~/.codex` dizinleri, çalışan oturumları ve ChatGPT.app yalnızca okunur.
  - Model harcayan gerçek sağlayıcı deneyleri, planda belirtilen bütçeyle ya da kullanıcı onayıyla yapılır.
- **Commit:** Yalnızca kullanıcı isteyince. Öncesinde gizli değer ve büyük dosya kontrolü yapılır.
- **Ortam:**
  - macOS 27, Swift 6.4, yalnızca Command Line Tools (Xcode ve Instruments yok).
  - `swift test` makro eklentisini bulamazsa: `swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`
  - İzole profiller: `~/Library/Application Support/Loom-Dev/probe/claude-config` ve `~/.loom-dev/codex-home` (Codex için kısa yol; Darwin `sun_path` sınırı).
  - Claude ve Codex sürümleri sabitlenmez.
