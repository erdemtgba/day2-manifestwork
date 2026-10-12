# ACM Day-2 Label Generator

`acm-day2-label-generator.sh`, `policy-repo` içindeki policy overlay, change ve
base dizinlerini analiz eder ve Hub cluster üzerinde kullanılacak şu çıktıları
üretir:

| Çıktı | İçerik |
|---|---|
| `apply-labels-<cluster>.sh` | `oc label managedcluster` komutları (çalıştırılabilir script) |
| `apply-manifestworks-<cluster>.sh` | `manifestwork/` altındaki ManifestWork'leri tek seferlik uygulayan script: oluştur → `Applied` bekle → sil |
| `manifestwork/manifestwork-<cluster>-<policy>-<secim>.yaml` | Seçilen her overlay/change dizininin `kubectl kustomize` çıktısını içeren, `propagationPolicy: Orphan` ve `updateStrategy: ServerSideApply` (`force`) ayarlı OCM ManifestWork |

Örnek çıktı dizini (`--output-dir out/`):

```
out/
├── apply-labels-ocp-prod-01.sh
├── apply-manifestworks-ocp-prod-01.sh
└── manifestwork/
    ├── manifestwork-ocp-prod-01-kubeletconfig-overlays-prod.yaml
    └── manifestwork-ocp-prod-01-logging6-change-prod.yaml
```

`manifestwork/` dizini birden fazla çalıştırmanın dosyalarını biriktirebilir.
Script eski dosyaları silmez. Aynı cluster için önceki bir çalıştırmadan kalan
ve bu çalıştırmada üretilmeyen dosyalar için uyarı verir. Uygulama scripti
yalnızca o çalıştırmada üretilen ManifestWork'leri uygular.

## Gereksinimler

- `bash` 3.2+ ve `git` (remote repo için)
- ManifestWork üretimi için:
  - [`yq`](https://github.com/mikefarah/yq) **v4+** (mikefarah). Aynı adlı Python `yq` desteklenmez.
  - `kubectl`, `oc` veya `kustomize`. Bu sırayla aranır ve ilk bulunan kullanılır (`kubectl kustomize`, `oc kustomize`, `kustomize build`).
- Opsiyonel: `whiptail` veya `dialog`. Bunlar yoksa standart `read` akışı kullanılır.

Araçlar, seçim menüleri açılmadan önce kontrol edilir. Eksik bir araç varsa
script hemen hata verir. Yalnızca label üretmek için `--no-manifestwork`
kullanılabilir; bu modda `yq` ve `kubectl` gerekmez.

## Kullanım

```bash
chmod +x acm-day2-label-generator.sh
./acm-day2-label-generator.sh --repo /path/to/policy-repo --cluster ocp-prod-01
```

| Seçenek | Ortam değişkeni | Açıklama |
|---|---|---|
| `--repo VALUE` | `POLICY_REPO` | Yerel policy-repo yolu veya Git remote URL'si |
| `--cluster NAME` | `CLUSTER_NAME` | Managed cluster adı; verilmezse sorulur |
| `--output-dir DIR` | | Çıktı dizini (varsayılan: `.`); yoksa oluşturulur. ManifestWork YAML'ları `DIR/manifestwork/` altına yazılır |
| `--output PATH` | | Label scriptinin yolu (varsayılan: `DIR/apply-labels-<cluster>.sh`) |
| `--no-manifestwork` | | ManifestWork üretmez, yalnızca label scripti üretir |

`--repo` bir yerel checkout yolu veya Git remote URL'si olabilir. Remote repo
geçici bir dizine shallow clone edilir ve işlem bitince temizlenir:

```bash
./acm-day2-label-generator.sh \
	--repo https://github.com/example/policy-repo.git \
	--cluster ocp-prod-01 \
	--output-dir out/
```

Repo hiç verilmezse lokal testler için istenen örnek policy ağacını temsil eden
mock envanter kullanılır. Mock envanterde derlenecek dizin olmadığı için bu
modda yalnızca label scripti üretilir. Verilen yerel repo veya remote URL
geçersizse script hata ile sonlanır. Script, checkout içindeki `resources`
dizinini bulur ve yalnızca bu dizinin altındaki policy'leri kullanır. Repo
kökünde `resources` yoksa alt dizinlerdeki `resources` dizinlerini de bulur.

Cluster adı, hub'da aynı adlı namespace'e karşılık geldiği için DNS-1123 label
kuralına uymalıdır: küçük harf, rakam ve `-`, en fazla 63 karakter.

## Overlay seçimleri

Script tüm policy'leri taradıktan sonra aynı overlay kümesine sahip policy'leri
gruplar. Örneğin `prod,test` kullanan policy'ler birlikte gösterilir;
`prod,test,staging` kullanan policy'ler ise ayrı bir grup olarak ele alınır.
Grup seçiminde seçilen overlay, gruptaki tüm policy'lere uygulanır.
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

`change` dizininin alt dizini yoksa (örneğin yalnızca `kustomization.yaml`
içeriyorsa) seçenek `change` olur ve `sot/<policy>=change` etiketi üretilir.
Policy'nin overlay'i de yoksa kullanıcıya hiçbir şey sorulmadan bu etiket
doğrudan üretilir; overlay'i varsa menüde `change` ve `overlays-<overlay>`
seçenekleri gösterilir.

`change` dizini olmayan policy'ler önceki gibi overlay/base mantığıyla çalışır.

## ManifestWork üretimi

ManifestWork'ler, cluster kurulumunda yalnızca bir kez uygulanması gereken
kritik altyapı yapılandırmalarını (KubeletConfig, MachineConfigPool vb.)
hedef cluster'a doğrudan enjekte etmek için kullanılır. Bu kaynaklar sürekli
bir ACM Policy yaşam döngüsüne bağlanmaz.

Seçim sonucu ile derlenen dizin arasındaki eşleşme:

| Seçim (label değeri) | Derlenen dizin |
|---|---|
| `overlays-<x>` | `resources/<policy>/overlays/<x>/` |
| `change-<x>` | `resources/<policy>/change/<x>/` |
| `change` | `resources/<policy>/change/` |
| `base` | ManifestWork üretilmez (ACM Policy tarafından yönetilir) |

Her seçim için ayrı bir ManifestWork üretilir:

```yaml
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: <cluster>-<policy>-<secim>
  namespace: <cluster>          # hub'daki managed cluster namespace'i
  labels:
    app.kubernetes.io/managed-by: acm-day2-label-generator
    acm-sot/policy: <policy>
    acm-sot/selection: <secim>
  annotations:
    acm-sot/source-path: <policy>/<overlays|change>/<x>
    acm-sot/lifecycle: apply-once
spec:
  deleteOption:
    propagationPolicy: Orphan   # ManifestWork silinse de objeler cluster'da kalır
  manifestConfigs:              # her manifest için bir girdi
    - resourceIdentifier:
        group: machineconfiguration.openshift.io
        resource: kubeletconfigs
        name: set-max-pods
        # namespace: yalnızca namespaced objelerde
      updateStrategy:
        type: ServerSideApply   # yoksa oluştur, varsa güncelle
        serverSideApply:
          force: true           # başka field manager'lara ait alanları devral
  workload:
    manifests:
      - <kubectl kustomize çıktısındaki her obje>
```

### Tek seferlik uygulama: uygula → bekle → sil

OCM'de "bir kez uygula, sonra bırak" diye bir `updateStrategy` yoktur.
`ServerSideApply`, ManifestWork hub'da durduğu sürece objeyi yönetmeye ve
drift'i geri almaya devam eder. Bu yüzden tek seferlik davranış, ManifestWork
uygulandıktan sonra silinerek elde edilir:

| Ayar / adım | Etkisi |
|---|---|
| `updateStrategy: ServerSideApply` + `force: true` | Obje yoksa oluşturulur; varsa yalnızca manifestteki alanlar güncellenir. Installer veya operator'ün sahiplendiği alanlar da devralınır. |
| `deleteOption.propagationPolicy: Orphan` | ManifestWork silindiğinde objeler cluster'dan silinmez. |
| `apply-manifestworks-<cluster>.sh` | Her ManifestWork'ü oluşturur, `Applied` koşulunu bekler ve siler. Silme sonrası objeler cluster'da kalır ve artık hiçbir şey tarafından yönetilmez. |

Hub üzerinde uygulamak için:

```bash
bash apply-labels-ocp-prod-01.sh
bash apply-manifestworks-ocp-prod-01.sh
```

`apply-manifestworks-<cluster>.sh`, ManifestWork dosyalarını kendi bulunduğu
dizindeki `manifestwork/` alt dizininden okur; bu yüzden hangi dizinden
çalıştırıldığı fark etmez. Her ManifestWork için sırasıyla şunları yapar:

1. Önceki bir çalıştırmadan kalan aynı adlı ManifestWork'ü siler. Bunun nedeni,
   eski `Applied` durumunun yanlış pozitif vermesini önlemek. `Orphan` olduğu
   için objeler etkilenmez.
2. ManifestWork'ü `oc create` ile oluşturur.
3. `oc wait --for=condition=Applied` ile uygulanmasını bekler.
4. ManifestWork'ü siler.

Bekleme zaman aşımına uğrarsa script hata koduyla durur. Bu durumda
ManifestWork'ün koşullarını ekrana basar, sonraki ManifestWork'lere geçmez ve
hatalı ManifestWork'ü incelenmek üzere hub'da bırakır.

| Ortam değişkeni | Varsayılan | Açıklama |
|---|---|---|
| `OC` | `oc` | Kullanılacak CLI (`kubectl` de olabilir) |
| `MANIFESTWORK_TIMEOUT` | `10m` | Silme ve `Applied` bekleme adımlarının her biri için zaman aşımı |

Dikkat edilmesi gerekenler:

- ManifestWork dosyalarını doğrudan `oc apply` ile uygulamayın. Bu durumda
  silinene kadar objeleri `ServerSideApply` ile yönetmeye ve drift'i geri almaya
  devam ederler.
- Var olan bir `KubeletConfig`, `MachineConfig` veya `ContainerRuntimeConfig`
  güncellenirse MCO ilgili pool'daki node'ları sırayla yeniden başlatır. Script
  `machineconfiguration.openshift.io` objeleri için uyarı verir. Bu tür
  değişiklikleri bakım penceresinde uygulayın.
- `resourceIdentifier.resource`, Kind'ın çoğul resource adıdır ve standart çoğul
  kuralıyla türetilir (`KubeletConfig` → `kubeletconfigs`, `Proxy` → `proxies`).
  Kurala uymayan bir Kind için yanlış ad üretilirse `ServerSideApply` o objeye
  uygulanmaz. Obje yine uygulanır, ama varsayılan `Update` stratejisiyle (tüm
  objeyi yazarak) ve sessizce. Böyle Kind'ları scriptteki
  `KIND_RESOURCE_OVERRIDES` dizisine `Kind=resource` olarak ekleyin. Doğru adı
  `oc api-resources | grep -i <kind>` ile kontrol edebilirsiniz. Script her
  ManifestWork için kullanılan `resource/name` listesini ekrana basar.
- `updateStrategy` alanı eski ACM/OCM sürümlerinde bulunmaz. Hub'ınızda
  desteklendiğini şu komutla doğrulayın:
  `oc explain manifestwork.spec.manifestConfigs.updateStrategy.serverSideApply`

### Doğrulamalar ve hata yönetimi

- Seçilen her dizin ve içindeki `kustomization.yaml` (veya `.yml` /
  `Kustomization`), derlemeye başlamadan önce kontrol edilir. Biri eksikse
  script sonlanır.
- Kustomize derlemesi başarısız olursa kustomize hata çıktısı gösterilir ve
  script sonlanır.
- Derleme boş çıkarsa veya `apiVersion`/`kind` içermeyen bir doküman varsa
  script sonlanır.
- Üretilen dosya tekrar okunarak şunlar doğrulanır: `propagationPolicy: Orphan`
  değeri, manifest sayısı ve her manifest için bir `ServerSideApply` (`force`)
  girdisi olduğu.
- Tüm çıktılar önce geçici bir dizinde hazırlanır ve yalnızca tüm adımlar
  başarılıysa çıktı dizinine taşınır. Hata durumunda yarım çıktı kalmaz.
- Uyarılar:
  - `Secret` içeren çıktılar için: dosyayı git'e commit etmeyin.
  - Managed cluster'a gönderilecek ACM hub objeleri (`Policy`,
    `PlacementBinding` vb.) için.
  - OCM'in 500 KiB manifest sınırını aşan dosyalar için.
  - Güncellendiğinde node yeniden başlatmasına yol açabilecek
    `machineconfiguration.openshift.io` objeleri için.
