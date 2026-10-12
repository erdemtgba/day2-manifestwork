# ACM Day-2 Label Generator

`acm-day2-label-generator.sh`, `policy-repo` içindeki policy overlay, change ve
base dizinlerini analiz eder ve Hub cluster üzerinde kullanılacak iki çıktı
üretir:

| Çıktı | İçerik |
|---|---|
| `apply-labels-<cluster>.sh` | `oc label managedcluster` komutları (çalıştırılabilir script) |
| `manifestwork-<cluster>-<policy>-<secim>.yaml` | Seçilen her overlay/change dizininin `kubectl kustomize` çıktısını içeren, `propagationPolicy: Orphan` ve `updateStrategy: CreateOnly` ayarlı OCM ManifestWork |

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
| `--output-dir DIR` | | Çıktı dizini (varsayılan: `.`); yoksa oluşturulur |
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
    sot/policy: <policy>
    sot/selection: <secim>
  annotations:
    sot/source-path: <policy>/<overlays|change>/<x>
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
        type: CreateOnly        # yalnızca yoksa oluştur, asla güncelleme
  workload:
    manifests:
      - <kubectl kustomize çıktısındaki her obje>
```

### `Orphan` + `CreateOnly` birlikte

| Ayar | Etkisi |
|---|---|
| `deleteOption.propagationPolicy: Orphan` | ManifestWork silindiğinde objeler cluster'dan silinmez. |
| `updateStrategy: CreateOnly` | Work agent objeyi yalnızca cluster'da yoksa oluşturur. Var olan objeyi hiçbir zaman güncellemez; sonradan cluster'da yapılan değişiklikler geri alınmaz. |

Bu iki ayar birlikte enjeksiyonu gerçekten tek seferlik yapar.

Dikkat edilmesi gerekenler:

- `CreateOnly`, cluster'da **zaten var olan** objeleri değiştirmez. OpenShift'in
  `config.openshift.io` / `operator.openshift.io` singleton'ları (`Proxy/cluster`,
  `APIServer/cluster`, `Scheduler/cluster` vb.) her zaman var olduğu için bunlara
  yapılan değişiklikler uygulanmaz; script bu durumda uyarı verir.
- `resourceIdentifier.resource`, Kind'ın çoğul resource adıdır ve standart çoğul
  kuralıyla türetilir (`KubeletConfig` → `kubeletconfigs`, `Proxy` → `proxies`).
  Kurala uymayan bir Kind için yanlış ad üretilirse o objede `CreateOnly`
  sessizce uygulanmaz. Böyle Kind'ları scriptteki `KIND_RESOURCE_OVERRIDES`
  dizisine `Kind=resource` olarak ekleyin. Doğru adı
  `oc api-resources | grep -i <kind>` ile kontrol edebilirsiniz. Script her
  ManifestWork için kullanılan `resource/name` listesini ekrana basar.
- `updateStrategy` alanı eski ACM/OCM sürümlerinde bulunmaz. Hub'ınızda
  desteklendiğini şu komutla doğrulayın:
  `oc explain manifestwork.spec.manifestConfigs.updateStrategy`

Hub üzerinde uygulamak için:

```bash
bash apply-labels-ocp-prod-01.sh
oc apply -f manifestwork-ocp-prod-01-kubeletconfig-overlays-prod.yaml
```

### Doğrulamalar ve hata yönetimi

- Seçilen her dizin ve içindeki `kustomization.yaml` (veya `.yml` /
  `Kustomization`), derlemeye başlamadan önce kontrol edilir. Biri eksikse
  script sonlanır.
- Kustomize derlemesi başarısız olursa kustomize hata çıktısı gösterilir ve
  script sonlanır.
- Derleme boş çıkarsa veya `apiVersion`/`kind` içermeyen bir doküman varsa
  script sonlanır.
- Üretilen dosyadaki `propagationPolicy: Orphan` değeri, manifest sayısı ve her
  manifest için bir `CreateOnly` girdisi olduğu tekrar okunarak doğrulanır.
- Tüm çıktılar önce geçici bir dizinde hazırlanır ve yalnızca tüm adımlar
  başarılıysa çıktı dizinine taşınır. Hata durumunda yarım çıktı kalmaz.
- Uyarılar:
  - `Secret` içeren çıktılar için: dosyayı git'e commit etmeyin.
  - Managed cluster'a gönderilecek ACM hub objeleri (`Policy`,
    `PlacementBinding` vb.) için.
  - OCM'in 500 KiB manifest sınırını aşan dosyalar için.
  - `CreateOnly` nedeniyle güncellenmeyecek OpenShift singleton objeleri için.
