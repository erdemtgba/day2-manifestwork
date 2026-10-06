# ACM Day-2 Label Generator

`acm-day2-label-generator.sh`, `policy-repo` içindeki policy overlay ve base
dizinlerini analiz ederek Hub cluster üzerinde çalıştırılacak
`oc label managedcluster` komutlarını üretir.

## Kullanım

```bash
chmod +x acm-day2-label-generator.sh
./acm-day2-label-generator.sh --repo /path/to/policy-repo --output labels.sh
```

`--repo` bir yerel checkout yolu veya Git remote URL'si olabilir. Remote repo
geçici bir dizine shallow clone edilir ve işlem bitince temizlenir:

```bash
./acm-day2-label-generator.sh \
	--repo https://github.com/example/policy-repo.git \
	--output labels.sh
```

Repo yolu veya remote URL'si `--repo` yerine `POLICY_REPO` ortam değişkeniyle
de verilebilir:

```bash
POLICY_REPO=/path/to/policy-repo ./acm-day2-label-generator.sh
```

`whiptail` veya `dialog` bulunmuyorsa script standart `read` tabanlı CLI
akışına geçer. Repo hiç verilmezse lokal testler için istenen örnek policy
ağacını temsil eden mock envanter kullanılır. Verilen yerel repo veya remote
URL geçersizse script hata ile sonlanır. Script, checkout içindeki `resources`
dizinini bulur ve yalnızca bu dizinin altındaki policy'leri kullanır; repo
kökünde değilse alt dizinlerde bulunan `resources` dizinlerini de destekler.

Script tüm policy'leri taradıktan sonra aynı overlay kümesine sahip policy'leri
gruplar. Örneğin `prod,test` kullanan policy'ler birlikte gösterilir; aynı
zamanda `prod,test,staging` kullanan policy'ler farklı bir grup olarak ele
alınır. Grup seçiminde seçilen overlay, gruptaki tüm policy'lere uygulanır.
Aynı overlay kümesine sahip olmayan policy'ler ayrı ayrı sorulur. Overlay
bulunmayan policy'ler `sot/<policy>=base` etiketiyle üretilir.

### `change` dizini olan policy'ler

Bazı policy'lerde `base` ve `overlays` dışında opsiyonel bir `change` dizini
bulunabilir (`resources/<policy>/change/<isim>/`, örn. `prod`, `test`,
`prod-ocpadmins`). Bu dizine sahip policy'ler ortak overlay gruplarına dahil
edilmez; sırası geldiğinde ayrı bir menüyle sorulur. Menüde `change-<isim>`
seçenekleri, policy'nin overlay'leri varsa `overlays-<overlay>` seçenekleri,
overlay yoksa `base` seçeneği listelenir. `change` seçimi şu etiketi üretir:

```
sot/<policy>=change-<isim>
```

`change` dizini olmayan policy'ler önceki gibi overlay/base mantığıyla çalışır.
