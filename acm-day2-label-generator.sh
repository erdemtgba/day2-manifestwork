#!/usr/bin/env bash
#
# ACM Day-2 policy overlay analizcisi, managed cluster label üreticisi ve
# tek seferlik (Orphan) OCM ManifestWork üreticisi.
#
#   ./acm-day2-label-generator.sh --repo /path/to/policy-repo
#   ./acm-day2-label-generator.sh --repo https://github.com/example/policy-repo.git
#   ./acm-day2-label-generator.sh --repo /path/to/policy-repo --cluster ocp-prod-01
#   POLICY_REPO=/path/to/policy-repo CLUSTER_NAME=ocp-prod-01 ./acm-day2-label-generator.sh
#
# Çıktılar (varsayılan olarak --output-dir, yani bulunulan dizin altına):
#   apply-labels-<cluster>.sh
#       Hub üzerinde çalıştırılacak "oc label managedcluster" komutları.
#   manifestwork-<cluster>-<policy>-<secim>.yaml
#       Seçilen her overlay/change dizini için "kubectl kustomize" ile derlenen
#       objeleri içeren ManifestWork. spec.deleteOption.propagationPolicy=Orphan
#       olduğu için ManifestWork silinse bile objeler hedef cluster'da kalır.
#       Her obje için updateStrategy=CreateOnly tanımlandığından objeler yalnızca
#       yoksa oluşturulur; sonradan cluster'da yapılan değişiklikler ezilmez.
#
# Script, whiptail veya dialog varsa menülü bir arayüz kullanır. İkisi de
# yoksa aynı akış standart read komutları ile devam eder.
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
REPO_PATH="${POLICY_REPO:-}"
RESOURCES_PATH=""
CLONE_DIR=""
WORK_DIR=""
OUTPUT_FILE=""
OUTPUT_DIR="."
UI_TOOL=""
CLUSTER_NAME="${CLUSTER_NAME:-}"
GENERATE_MANIFESTWORK=true
KUSTOMIZE_CMD=()

# OCM work webhook'u ManifestWork içindeki manifestlerin toplam boyutunu
# 500 KiB ile sınırlar; bu değeri aşan dosyalar için uyarı verilir.
MANIFESTWORK_SIZE_LIMIT=$((500 * 1024))
MANIFESTWORK_MANAGED_BY="acm-day2-label-generator"

# manifestConfigs.resourceIdentifier.resource alanı Kind'ın çoğul resource adını
# ister. Adlar kind_to_resource içinde standart İngilizce çoğul kuralıyla
# türetilir; kurala uymayan Kind'lar buraya "Kind=resource" olarak eklenmelidir.
# Yanlış bir resource adı CreateOnly ayarının sessizce uygulanmamasına yol açar.
KIND_RESOURCE_OVERRIDES=(
  "Endpoints=endpoints"
  "SecurityContextConstraints=securitycontextconstraints"
)

# Gerçek repo bulunamadığında lokal testler için kullanılan örnek envanter.
# Format: policy|overlay. Base-only policy'ler ayrıca MOCK_BASE_POLICIES içinde.
MOCK_OVERLAYS=(
  "alertmanager|iisadmins"
  "alertmanager|ocpadmins"
  "etcdbackup|prod"
  "etcdbackup|test"
  "huaweicsi|dmz-hypermetro"
  "huaweicsi|odm-dmz-hypermetro"
  "huaweicsi|odm-standalone"
  "huaweicsi|prod-hypermetro"
  "huaweicsi|prod-standalone"
  "huaweicsi|test-standalone"
  "logging6|prod"
  "logging6|test"
)
MOCK_BASE_POLICIES=("kubeletmaster" "monitoring")
# Format: policy|change. resources/<policy>/change/<change> dizinlerini temsil eder.
MOCK_CHANGES=(
  "logging6|prod"
  "logging6|test"
  "logging6|prod-ocpadmins"
)
# Alt dizini olmayan (yalnızca kustomization.yaml içeren) change dizinine sahip policy'ler.
MOCK_FLAT_CHANGE_POLICIES=("monitoring")

POLICIES=()
POLICY_COUNT=0
# Policy adı -> resources altındaki policy dizini eşleşmesi (paralel diziler).
POLICY_DIR_KEYS=()
POLICY_DIR_VALUES=()
OVERLAY_POLICIES=()
OVERLAYS=()
CHANGE_DIR_POLICIES=()
CHANGE_POLICIES=()
CHANGES=()
BASE_POLICIES=()
SELECTED_POLICIES=()
SELECTED_VALUES=()
LABEL_COMMANDS=()
OVERLAY_GROUP_SIGNATURES=()
OVERLAY_GROUP_POLICIES=()
OVERLAY_GROUP_COUNTS=()
OVERLAY_GROUP_COUNT=0
SELECTED_GROUP_POLICY_COUNT=0
# Üretilen ManifestWork dosyalarının adları (WORK_DIR içinde hazırlanır).
MANIFESTWORK_FILES=()

# ---------------------------------------------------------------------------
# Genel yardımcılar
# ---------------------------------------------------------------------------

# Scriptin kullanım seçeneklerini ve örnek komutlarını ekrana basar.
usage() {
  cat <<EOF
Kullanım: $SCRIPT_NAME [--repo PATH_OR_GIT_URL] [--cluster NAME] [--output-dir DIR]
          [--output /path/to/file] [--no-manifestwork]

Seçenekler:
  --repo VALUE        Yerel policy-repo yolu veya Git repo URL'si (varsayılan: POLICY_REPO)
  --cluster NAME      Managed cluster adı (varsayılan: CLUSTER_NAME, verilmezse sorulur)
  --output-dir DIR    Üretilen dosyaların yazılacağı dizin (varsayılan: .)
  --output PATH       Label scriptinin yolu (varsayılan: DIR/apply-labels-<cluster>.sh)
  --no-manifestwork   ManifestWork üretme; yalnızca label scriptini üret
  -h, --help          Bu yardımı göster

Repo verilmezse örnek mock envanter kullanılır; mock envanterde kustomize
dizinleri olmadığı için yalnızca label scripti üretilir.

ManifestWork üretimi için yq (mikefarah, v4+) ve kubectl, oc veya kustomize
araçlarından biri gerekir.
EOF
}

# Hata mesajını stderr'e yazıp scripti kontrollü şekilde sonlandırır.
die() {
  printf 'Hata: %s\n' "$*" >&2
  exit 1
}

# Uyarı mesajını stderr'e yazar; akışı durdurmaz.
warn() {
  printf 'Uyarı: %s\n' "$*" >&2
}

# Bilgi mesajını stderr'e yazar (stdout menü cevapları için temiz kalır).
info() {
  printf '%s\n' "$*" >&2
}

# Geçici dizinleri temizler. EXIT trap'i ile her çıkışta çalışır.
cleanup() {
  [[ -n "$CLONE_DIR" ]] && rm -rf "$CLONE_DIR"
  [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  return 0
}

# Sinyaller doğrudan EXIT trap'ine yönlendirilir; böylece Ctrl+C sonrasında
# script devam etmez ve geçici dosyalar yine de temizlenir.
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Verilen değerin değişken sayıda öğe içeren listede bulunup bulunmadığını kontrol eder.
contains() {
  local wanted="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  return 1
}

# Policy listesindeki mevcut bir policy'yi kontrol eder.
policy_exists() {
  local wanted="$1"
  local policy
  [[ $POLICY_COUNT -gt 0 ]] || return 1
  for policy in "${POLICIES[@]}"; do
    [[ "$policy" == "$wanted" ]] && return 0
  done
  return 1
}

# Policy'yi envantere ekler ve (biliniyorsa) resources altındaki dizinini kaydeder.
register_policy() {
  local policy="$1"
  local policy_dir="${2:-}"
  if ! policy_exists "$policy"; then
    POLICIES+=("$policy")
    POLICY_COUNT=$((POLICY_COUNT + 1))
  fi
  [[ -n "$policy_dir" ]] || return 0
  contains "$policy" "${POLICY_DIR_KEYS[@]+"${POLICY_DIR_KEYS[@]}"}" && return 0
  POLICY_DIR_KEYS+=("$policy")
  POLICY_DIR_VALUES+=("$policy_dir")
}

# Policy'nin resources altındaki dizinini döndürür.
policy_dir() {
  local policy="$1" i
  for ((i = 0; i < ${#POLICY_DIR_KEYS[@]}; i++)); do
    if [[ "${POLICY_DIR_KEYS[$i]}" == "$policy" ]]; then
      printf '%s\n' "${POLICY_DIR_VALUES[$i]}"
      return 0
    fi
  done
  printf '%s\n' "$RESOURCES_PATH/$policy"
}

# ---------------------------------------------------------------------------
# Argümanlar ve girdi doğrulama
# ---------------------------------------------------------------------------

# Komut satırı seçeneklerini ayrıştırır ve ilgili global değişkenleri doldurur.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || die "--repo bir yol bekler."
        REPO_PATH="$2"
        shift 2
        ;;
      --cluster)
        [[ $# -ge 2 ]] || die "--cluster bir cluster adı bekler."
        CLUSTER_NAME="$2"
        shift 2
        ;;
      --output-dir)
        [[ $# -ge 2 ]] || die "--output-dir bir dizin yolu bekler."
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --output)
        [[ $# -ge 2 ]] || die "--output bir dosya yolu bekler."
        OUTPUT_FILE="$2"
        shift 2
        ;;
      --no-manifestwork)
        GENERATE_MANIFESTWORK=false
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Bilinmeyen seçenek: $1"
        ;;
    esac
  done
}

# Managed cluster adı, hub'da aynı adlı bir namespace'e karşılık geldiği için
# DNS-1123 label kuralına uymalıdır: küçük harf, rakam, '-' ve en fazla 63 karakter.
validate_cluster_name() {
  [[ -n "$CLUSTER_NAME" ]] || die 'Cluster adı boş bırakılamaz.'
  if [[ ! "$CLUSTER_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || (( ${#CLUSTER_NAME} > 63 )); then
    die "Geçersiz cluster adı: '$CLUSTER_NAME' (DNS-1123 label: küçük harf, rakam, '-', en fazla 63 karakter)."
  fi
}

# Kubernetes label adı/değeri kuralını kontrol eder: en fazla 63 karakter,
# alfanümerik ile başlayıp biten, arada '-', '_' veya '.' içerebilen değer.
is_valid_label_segment() {
  local value="$1"
  (( ${#value} <= 63 )) || return 1
  [[ "$value" =~ ^([A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?)?$ ]]
}

# Çıktı dizinini doğrular, yoksa oluşturur.
prepare_output_dir() {
  if [[ -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ]]; then
    die "--output-dir bir dizin değil: $OUTPUT_DIR"
  fi
  mkdir -p "$OUTPUT_DIR" || die "Çıktı dizini oluşturulamadı: $OUTPUT_DIR"
  [[ -w "$OUTPUT_DIR" ]] || die "Çıktı dizinine yazılamıyor: $OUTPUT_DIR"
}

# ---------------------------------------------------------------------------
# Kullanıcı arayüzü
# ---------------------------------------------------------------------------

# Kullanılabilir terminal arayüzünü öncelik sırasıyla whiptail, dialog veya read olarak belirler.
select_ui_tool() {
  if command -v whiptail >/dev/null 2>&1; then
    UI_TOOL="whiptail"
  elif command -v dialog >/dev/null 2>&1; then
    UI_TOOL="dialog"
  else
    UI_TOOL="read"
  fi
}

# Kullanılan arayüz aracına göre kullanıcıdan tek satırlık metin girdisi alır.
ui_input() {
  local prompt="$1"
  local default_value="${2:-}"
  if [[ "$UI_TOOL" == "whiptail" ]]; then
    whiptail --inputbox "$prompt" 10 70 "$default_value" 3>&1 1>&2 2>&3
  elif [[ "$UI_TOOL" == "dialog" ]]; then
    dialog --inputbox "$prompt" 10 70 "$default_value" 3>&1 1>&2 2>&3
  else
    local answer
    read -r -p "$prompt [$default_value]: " answer || die 'Girdi okunamadı (EOF).'
    printf '%s\n' "${answer:-$default_value}"
  fi
}

# Kullanıcıya seçenek menüsü gösterir ve seçilen seçeneğin indeksini döndürür.
ui_menu() {
  local prompt="$1"
  shift
  local options=("$@")
  local answer
  local index=1

  if [[ "$UI_TOOL" == "whiptail" || "$UI_TOOL" == "dialog" ]]; then
    local args=("$prompt" 20 80 "${#options[@]}")
    local option label
    for option in "${options[@]}"; do
      label="$option"
      args+=("$index" "$label")
      index=$((index + 1))
    done
    if [[ "$UI_TOOL" == "whiptail" ]]; then
      whiptail --menu "${args[@]}" 3>&1 1>&2 2>&3
    else
      dialog --menu "${args[@]}" 3>&1 1>&2 2>&3
    fi
  else
    printf '\n%s\n' "$prompt" >&2
    index=1
    for option in "${options[@]}"; do
      printf '  %d) %s\n' "$index" "$option" >&2
      index=$((index + 1))
    done
    while true; do
      read -r -p 'Seçiminiz: ' answer || die 'Girdi okunamadı (EOF).'
      if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#options[@]} )); then
        printf '%s\n' "$answer"
        return 0
      fi
      printf 'Geçersiz seçim. 1-%d arasında bir değer girin.\n' "${#options[@]}" >&2
    done
  fi
}

# ---------------------------------------------------------------------------
# Envanter
# ---------------------------------------------------------------------------

# Gerçek policy repo bulunamadığında test amacıyla örnek policy envanterini yükler.
load_mock_inventory() {
  local entry policy overlay
  for entry in "${MOCK_OVERLAYS[@]}"; do
    policy="${entry%%|*}"
    overlay="${entry#*|}"
    OVERLAY_POLICIES+=("$policy")
    OVERLAYS+=("$overlay")
    register_policy "$policy"
  done
  for policy in "${MOCK_BASE_POLICIES[@]}"; do
    BASE_POLICIES+=("$policy")
    register_policy "$policy"
  done
  for entry in "${MOCK_CHANGES[@]}"; do
    policy="${entry%%|*}"
    CHANGE_DIR_POLICIES+=("$policy")
    CHANGE_POLICIES+=("$policy")
    CHANGES+=("${entry#*|}")
    register_policy "$policy"
  done
  for policy in "${MOCK_FLAT_CHANGE_POLICIES[@]}"; do
    CHANGE_DIR_POLICIES+=("$policy")
    register_policy "$policy"
  done
}

# Gerçek repo içindeki resources/<policy>/overlays/<overlay>,
# resources/<policy>/change/<change> ve resources/<policy>/base dizinlerini
# tarayıp policy envanterini oluşturur.
load_repo_inventory() {
  local resource_dir policy overlay_dir overlay base_dir relative_dir change_dir
  local inventory_file
  inventory_file="$WORK_DIR/policy-repo-inventory"

  find "$RESOURCES_PATH" -mindepth 2 -maxdepth 4 -type d -print >"$inventory_file"
  while IFS= read -r resource_dir; do
    case "$resource_dir" in
      */resources/*/overlays)
        policy="${resource_dir%/overlays}"
        policy="${policy##*/}"
        register_policy "$policy" "${resource_dir%/overlays}"
        while IFS= read -r -d '' overlay_dir; do
          overlay="${overlay_dir##*/}"
          OVERLAY_POLICIES+=("$policy")
          OVERLAYS+=("$overlay")
        done < <(find "$resource_dir" -mindepth 1 -maxdepth 1 -type d -print0)
        ;;
      */resources/*/change)
        # Yalnızca resources/<policy>/change dizinini kabul et; örneğin
        # overlays/change gibi daha derindeki dizinler policy sayılmaz.
        relative_dir="${resource_dir#"$RESOURCES_PATH"/}"
        [[ "$relative_dir" == */*/* ]] && continue
        policy="${relative_dir%/change}"
        # change dizini alt dizin içermese de (yalnızca kustomization.yaml) kaydedilir.
        CHANGE_DIR_POLICIES+=("$policy")
        register_policy "$policy" "${resource_dir%/change}"
        while IFS= read -r -d '' change_dir; do
          CHANGE_POLICIES+=("$policy")
          CHANGES+=("${change_dir##*/}")
        done < <(find "$resource_dir" -mindepth 1 -maxdepth 1 -type d -print0)
        ;;
      */resources/*/base)
        base_dir="${resource_dir%/base}"
        policy="${base_dir##*/}"
        BASE_POLICIES+=("$policy")
        register_policy "$policy" "$base_dir"
        ;;
    esac
  done <"$inventory_file"
  rm -f "$inventory_file"
}

# Repo checkout'u içinde yalnızca resources ağacını seçer.
locate_resources() {
  if [[ -d "$REPO_PATH/resources" ]]; then
    RESOURCES_PATH="$REPO_PATH/resources"
    return 0
  fi

  RESOURCES_PATH="$(find "$REPO_PATH" \
    -path '*/.git' -prune -o \
    -type d -name resources -print -quit)"
  [[ -n "$RESOURCES_PATH" ]] || die "Repo içinde resources dizini bulunamadı: $REPO_PATH"
}

# Repo URL'sini geçici bir checkout'a indirir veya yerel repo yolunu doğrular.
prepare_repo() {
  if [[ -z "$REPO_PATH" ]]; then
    return 0
  fi

  if [[ "$REPO_PATH" =~ ^[[:alpha:]][[:alnum:]+.-]*:// || "$REPO_PATH" =~ ^git@ ]]; then
    CLONE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/policy-repo.XXXXXX")"
    info "Git repo klonlanıyor: $REPO_PATH"
    git clone --depth 1 "$REPO_PATH" "$CLONE_DIR" >/dev/null || die "Git repo klonlanamadı: $REPO_PATH"
    REPO_PATH="$CLONE_DIR"
    return 0
  fi

  [[ -d "$REPO_PATH" ]] || die "Repo yolu bulunamadı: $REPO_PATH"
}

# Gerçek repo kullanılabiliyorsa repo envanterini, repo verilmediyse mock envanteri yükler.
load_inventory() {
  prepare_repo
  if [[ -n "$REPO_PATH" ]]; then
    locate_resources
    load_repo_inventory
    [[ $POLICY_COUNT -gt 0 ]] || die "Repo içinde resources altında policy bulunamadı."
    info "Repo envanteri okundu: $RESOURCES_PATH"
  else
    load_mock_inventory
    info 'Bilgi: Gerçek policy repo bulunamadı; mock envanter kullanılıyor.'
  fi
}

# Belirli bir policy için tanımlı overlay adlarını listeler.
policy_overlays() {
  local policy="$1" i
  for ((i = 0; i < ${#OVERLAY_POLICIES[@]}; i++)); do
    [[ "${OVERLAY_POLICIES[$i]}" == "$policy" ]] && printf '%s\n' "${OVERLAYS[$i]}"
  done
  return 0
}

# Belirli bir policy için change/ altındaki dizin adlarını sıralı ve tekrarsız listeler.
policy_changes() {
  local policy="$1" i
  for ((i = 0; i < ${#CHANGE_POLICIES[@]}; i++)); do
    [[ "${CHANGE_POLICIES[$i]}" == "$policy" ]] && printf '%s\n' "${CHANGES[$i]}"
  done | sort -u
}

# Policy'nin change/ dizini olup olmadığını kontrol eder (alt dizin şart değil).
policy_has_change() {
  local policy="$1" i
  for ((i = 0; i < ${#CHANGE_DIR_POLICIES[@]}; i++)); do
    [[ "${CHANGE_DIR_POLICIES[$i]}" == "$policy" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Overlay / change seçimleri
# ---------------------------------------------------------------------------

# Policy'nin overlay listesini sıralı ve tekrarsız grup imzasına dönüştürür.
overlay_signature() {
  local policy="$1"
  policy_overlays "$policy" | sort -u | paste -sd, -
}

find_overlay_group() {
  local signature="$1"
  local index
  for ((index = 0; index < OVERLAY_GROUP_COUNT; index++)); do
    if [[ "${OVERLAY_GROUP_SIGNATURES[$index]}" == "$signature" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

# Tüm policy'leri tarayıp aynı overlay kümesine sahip olanları gruplar.
# change/ dizini olan policy'ler gruplara dahil edilmez; ayrıca sorulur.
choose_common_overlay_groups() {
  local policy signature group_index policy_list selected_index value
  local group_policies=()
  local group_options=()

  for policy in "${POLICIES[@]}"; do
    policy_has_change "$policy" && continue
    signature="$(overlay_signature "$policy")"
    [[ -n "$signature" ]] || continue
    if group_index="$(find_overlay_group "$signature")"; then
      policy_list="${OVERLAY_GROUP_POLICIES[$group_index]}"
      OVERLAY_GROUP_POLICIES[$group_index]="$policy_list,$policy"
      OVERLAY_GROUP_COUNTS[$group_index]=$((OVERLAY_GROUP_COUNTS[$group_index] + 1))
    else
      OVERLAY_GROUP_SIGNATURES+=("$signature")
      OVERLAY_GROUP_POLICIES+=("$policy")
      OVERLAY_GROUP_COUNTS+=(1)
      OVERLAY_GROUP_COUNT=$((OVERLAY_GROUP_COUNT + 1))
    fi
  done

  for ((group_index = 0; group_index < OVERLAY_GROUP_COUNT; group_index++)); do
    [[ "${OVERLAY_GROUP_COUNTS[$group_index]}" -gt 1 ]] || continue
    group_options=()
    IFS=',' read -r -a group_options <<< "${OVERLAY_GROUP_SIGNATURES[$group_index]}"
    group_policies=()
    IFS=',' read -r -a group_policies <<< "${OVERLAY_GROUP_POLICIES[$group_index]}"
    policy_list="${group_policies[*]}"
    selected_index="$(ui_menu "Ortak overlay grubu [$policy_list]" "${group_options[@]}")"
    value="${group_options[$((selected_index - 1))]}"
    for policy in "${group_policies[@]}"; do
      SELECTED_POLICIES+=("$policy")
      SELECTED_VALUES+=("overlays-$value")
      SELECTED_GROUP_POLICY_COUNT=$((SELECTED_GROUP_POLICY_COUNT + 1))
    done
  done
}

common_group_contains() {
  local wanted="$1"
  local policy
  local group_policies
  local group_index
  [[ $SELECTED_GROUP_POLICY_COUNT -gt 0 ]] || return 1
  for ((group_index = 0; group_index < OVERLAY_GROUP_COUNT; group_index++)); do
    [[ "${OVERLAY_GROUP_COUNTS[$group_index]}" -gt 1 ]] || continue
    IFS=',' read -r -a group_policies <<< "${OVERLAY_GROUP_POLICIES[$group_index]}"
    for policy in "${group_policies[@]}"; do
      [[ "$policy" == "$wanted" ]] && return 0
    done
  done
  return 1
}

# Policy için base veya overlay seçer; ortak gruplar dışında kalanları ayrı sorar.
choose_overlay() {
  local policy="$1"
  local overlays=()
  local overlay selected_index candidate
  while IFS= read -r overlay; do
    [[ -n "$overlay" ]] && overlays+=("$overlay")
  done < <(policy_overlays "$policy")

  if [[ ${#overlays[@]} -eq 0 ]]; then
    SELECTED_POLICIES+=("$policy")
    SELECTED_VALUES+=("base")
    return 0
  fi

  if [[ ${#overlays[@]} -eq 1 ]]; then
    SELECTED_POLICIES+=("$policy")
    SELECTED_VALUES+=("overlays-${overlays[0]}")
    return 0
  fi

  local menu_options=()
  for candidate in "${overlays[@]}"; do
    menu_options+=("$candidate")
  done
  selected_index="$(ui_menu "$policy policy overlay seçin" "${menu_options[@]}")"
  SELECTED_POLICIES+=("$policy")
  SELECTED_VALUES+=("overlays-${overlays[$((selected_index - 1))]}")
}

# change/ dizini olan policy için change-<dizin> seçeneklerini, varsa
# overlays-<overlay> seçeneklerini, overlay yoksa base seçeneğini listeler.
# change/ alt dizin içermiyorsa seçenek "change" olur; overlay da yoksa
# kullanıcıya sorulmadan doğrudan sot/<policy>=change üretilir.
choose_change() {
  local policy="$1"
  local menu_options=()
  local item selected_index
  local change_count=0
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    menu_options+=("change-$item")
    change_count=$((change_count + 1))
  done < <(policy_changes "$policy")
  [[ $change_count -gt 0 ]] || menu_options+=("change")
  local overlay_count=0
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    menu_options+=("overlays-$item")
    overlay_count=$((overlay_count + 1))
  done < <(policy_overlays "$policy" | sort -u)

  if [[ $change_count -eq 0 && $overlay_count -eq 0 ]]; then
    SELECTED_POLICIES+=("$policy")
    SELECTED_VALUES+=("change")
    return 0
  fi

  if [[ $overlay_count -eq 0 ]] && contains "$policy" "${BASE_POLICIES[@]+"${BASE_POLICIES[@]}"}"; then
    menu_options+=("base")
  fi

  selected_index="$(ui_menu "$policy policy için change seçin" "${menu_options[@]}")"
  SELECTED_POLICIES+=("$policy")
  SELECTED_VALUES+=("${menu_options[$((selected_index - 1))]}")
}

# ---------------------------------------------------------------------------
# Label komutları
# ---------------------------------------------------------------------------

# Kullanıcı seçimlerini oc label managedcluster komutlarına dönüştürür.
# SELECTED_VALUES label değerini hazır tutar: base, overlays-<x> veya change-<x>.
# Geçersiz bir label adı/değeri hub'da "oc label" aşamasında hata vereceği için
# burada erkenden yakalanır.
build_commands() {
  local i policy value
  for ((i = 0; i < ${#SELECTED_POLICIES[@]}; i++)); do
    policy="${SELECTED_POLICIES[$i]}"
    value="${SELECTED_VALUES[$i]}"
    is_valid_label_segment "$policy" \
      || die "Policy adı geçerli bir label adı değil (en fazla 63 karakter, alfanümerik/-/_/.): sot/$policy"
    is_valid_label_segment "$value" \
      || die "Label değeri geçersiz (en fazla 63 karakter, alfanümerik/-/_/.): sot/$policy=$value"
    LABEL_COMMANDS+=("oc label managedcluster $CLUSTER_NAME sot/$policy=$value --overwrite")
  done
}

# ---------------------------------------------------------------------------
# ManifestWork üretimi (kustomize + yq)
# ---------------------------------------------------------------------------

# ManifestWork üretimi için gereken araçları doğrular ve kustomize komutunu seçer.
# Mock envanterde derlenecek dizin olmadığı için ManifestWork üretimi kapatılır.
prepare_manifestwork_tools() {
  [[ "$GENERATE_MANIFESTWORK" == true ]] || return 0
  if [[ -z "$REPO_PATH" ]]; then
    info 'Bilgi: Mock envanterde kustomize dizini olmadığı için ManifestWork üretilmeyecek.'
    GENERATE_MANIFESTWORK=false
    return 0
  fi

  # mikefarah/yq v4 sözdizimi kullanılır; aynı adlı Python yq (kislyuk) uyumsuzdur.
  command -v yq >/dev/null 2>&1 || die "yq bulunamadı. ManifestWork üretimi için mikefarah/yq v4+ gerekli (veya --no-manifestwork)."
  local yq_version
  yq_version="$(yq --version 2>&1 || true)"
  if [[ ! "$yq_version" =~ mikefarah ]] || [[ ! "$yq_version" =~ version\ v?([0-9]+) ]] || (( BASH_REMATCH[1] < 4 )); then
    die "Desteklenmeyen yq sürümü: '$yq_version'. mikefarah/yq v4+ gerekli."
  fi

  if command -v kubectl >/dev/null 2>&1; then
    KUSTOMIZE_CMD=(kubectl kustomize)
  elif command -v oc >/dev/null 2>&1; then
    KUSTOMIZE_CMD=(oc kustomize)
  elif command -v kustomize >/dev/null 2>&1; then
    KUSTOMIZE_CMD=(kustomize build)
  else
    die "kubectl, oc veya kustomize bulunamadı. ManifestWork üretimi için biri gerekli (veya --no-manifestwork)."
  fi
}

# Label değerini (overlays-<x>, change-<x>, change) kustomize dizinine çevirir.
# base seçimleri ACM Policy tarafından yönetildiği için ManifestWork üretmez (return 1).
selection_source_dir() {
  local policy="$1"
  local value="$2"
  local base
  base="$(policy_dir "$policy")"
  case "$value" in
    overlays-*) printf '%s\n' "$base/overlays/${value#overlays-}" ;;
    change-*)   printf '%s\n' "$base/change/${value#change-}" ;;
    change)     printf '%s\n' "$base/change" ;;
    *)          return 1 ;;
  esac
}

# Dizinin var olduğunu ve kustomize'ın tanıdığı bir kustomization dosyası
# içerdiğini doğrular; aksi halde scripti sonlandırır.
validate_kustomize_dir() {
  local dir="$1"
  local file
  [[ -d "$dir" ]] || die "Kustomize dizini bulunamadı: $dir"
  for file in kustomization.yaml kustomization.yml Kustomization; do
    [[ -f "$dir/$file" ]] && return 0
  done
  die "kustomization.yaml bulunamadı: $dir"
}

# ManifestWork adını DNS-1123 subdomain kuralına uyacak şekilde normalleştirir:
# küçük harfe çevirir, izin verilmeyen karakterleri '-' yapar, en fazla 253 karakter.
manifestwork_name() {
  local raw="$1"
  local name
  name="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '-')"
  if [[ ! "$name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || (( ${#name} > 253 )); then
    die "Geçerli bir ManifestWork adı üretilemedi: '$raw' -> '$name'"
  fi
  printf '%s\n' "$name"
}

# Dizini kustomize ile derler ve tüm objeleri tek bir YAML dizisi olarak yazar.
# Boş dokümanlar ayıklanır; apiVersion/kind içermeyen bir obje varsa hata verilir.
render_manifests() {
  local dir="$1"
  local manifests_file="$2"
  local rendered="$WORK_DIR/rendered.yaml"
  local errors="$WORK_DIR/kustomize.err"
  local count invalid

  if ! "${KUSTOMIZE_CMD[@]}" "$dir" >"$rendered" 2>"$errors"; then
    sed 's/^/  kustomize: /' "$errors" >&2
    die "Kustomize derlemesi başarısız (${KUSTOMIZE_CMD[*]} $dir)."
  fi
  # Derleme başarılı olsa da kustomize uyarıları (deprecated alanlar vb.) gösterilir.
  [[ -s "$errors" ]] && sed 's/^/  kustomize: /' "$errors" >&2

  # eval-all ile tüm dokümanlar tek bir diziye toplanır.
  yq eval-all '[.] | map(select(. != null))' "$rendered" >"$manifests_file" \
    || die "Kustomize çıktısı YAML olarak okunamadı: $dir"

  count="$(yq 'length' "$manifests_file")"
  [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || die "Kustomize çıktısı boş, ManifestWork'e eklenecek obje yok: $dir"

  invalid="$(yq '[.[] | select((has("apiVersion") and has("kind")) | not)] | length' "$manifests_file")"
  [[ "$invalid" == "0" ]] || die "Kustomize çıktısında apiVersion/kind içermeyen $invalid doküman var: $dir"
}

# Derlenen objeleri inceler: içerik özetini yazar, riskli türler için uyarır.
inspect_manifests() {
  local manifests_file="$1"
  local label="$2"
  local kinds secrets hub_objects

  kinds="$(yq '[.[] | .kind] | unique | join(", ")' "$manifests_file")"
  info "  $label: $(yq 'length' "$manifests_file") obje ($kinds)"

  secrets="$(yq '[.[] | select(.kind == "Secret")] | length' "$manifests_file")"
  if [[ "$secrets" != "0" ]]; then
    warn "$label $secrets Secret içeriyor; üretilen ManifestWork dosyasını git'e commit etmeyin."
  fi

  # ACM Policy objeleri hub'a aittir; managed cluster'a ManifestWork ile
  # gönderilmeleri genellikle yanlış dizinin seçildiğini gösterir.
  hub_objects="$(yq '[.[] | select(.apiVersion | test("^(policy|apps)\.open-cluster-management\.io/"))] | length' "$manifests_file")"
  if [[ "$hub_objects" != "0" ]]; then
    warn "$label $hub_objects adet ACM hub objesi (Policy/PlacementBinding vb.) içeriyor; bunlar managed cluster'a gönderilecek."
  fi
}

# Kind adından Kubernetes resource (çoğul, küçük harf) adını türetir.
# Örn: KubeletConfig -> kubeletconfigs, NetworkPolicy -> networkpolicies, Proxy -> proxies.
kind_to_resource() {
  local kind="$1"
  local entry lower
  for entry in "${KIND_RESOURCE_OVERRIDES[@]}"; do
    if [[ "${entry%%=*}" == "$kind" ]]; then
      printf '%s\n' "${entry#*=}"
      return 0
    fi
  done
  lower="$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *s|*x|*z|*ch|*sh) printf '%ses\n' "$lower" ;;
    *[!aeiou]y)       printf '%sies\n' "${lower%y}" ;;
    *)                printf '%ss\n' "$lower" ;;
  esac
}

# Her manifest için spec.manifestConfigs girdisi üretir:
#   resourceIdentifier: group / resource / name / (namespace)
#   updateStrategy.type: CreateOnly
# CreateOnly ile work agent objeyi yalnızca cluster'da yoksa oluşturur, var olan
# objeyi hiçbir zaman güncellemez; böylece enjeksiyon gerçekten tek seferlik olur.
build_manifest_configs() {
  local manifests_file="$1"
  local configs_file="$2"
  local label="$3"
  local api_version kind name namespace group resource
  local identifiers=()

  printf '[]\n' >"$configs_file"
  while IFS='|' read -r api_version kind name namespace; do
    [[ -n "$name" ]] || die "$label: metadata.name içermeyen $kind objesi için CreateOnly tanımlanamaz."
    # Core API (apiVersion: v1) için group boş string'dir.
    group=""
    [[ "$api_version" == */* ]] && group="${api_version%%/*}"
    resource="$(kind_to_resource "$kind")"

    RI_GROUP="$group" RI_RESOURCE="$resource" RI_NAME="$name" RI_NAMESPACE="$namespace" \
    yq -i '
      . += [{
        "resourceIdentifier": {
          "group": strenv(RI_GROUP),
          "resource": strenv(RI_RESOURCE),
          "name": strenv(RI_NAME),
          "namespace": strenv(RI_NAMESPACE)
        },
        "updateStrategy": {"type": "CreateOnly"}
      }] |
      del(.[-1].resourceIdentifier.namespace | select(. == ""))
    ' "$configs_file" || die "$label: manifestConfigs oluşturulamadı ($kind/$name)."
    identifiers+=("$resource/$name")

    # OpenShift'in config/operator singleton'ları (ör. Proxy/cluster) cluster'da
    # her zaman vardır; CreateOnly ile bu objeler hiç güncellenmez.
    if [[ "$name" == "cluster" && ( "$group" == "config.openshift.io" || "$group" == "operator.openshift.io" ) ]]; then
      warn "$label $kind/$name cluster'da zaten var olan bir singleton; CreateOnly nedeniyle değişiklik uygulanmayacak."
    fi
  done < <(yq '.[] | [.apiVersion, .kind, (.metadata.name // ""), (.metadata.namespace // "")] | join("|")' "$manifests_file")

  info "  CreateOnly: ${identifiers[*]}"
}

# Derlenmiş manifest dizisini, Orphan silme politikasına sahip bir ManifestWork'e sarar.
#   metadata.namespace = cluster adı (hub'daki managed cluster namespace'i)
#   spec.deleteOption.propagationPolicy = Orphan
#   spec.manifestConfigs = her obje için updateStrategy CreateOnly
#   spec.workload.manifests = kustomize çıktısındaki tüm objeler
build_manifestwork() {
  local manifests_file="$1"
  local configs_file="$2"
  local output_file="$3"
  local name="$4"
  local policy="$5"
  local selection="$6"
  local source_dir="$7"
  local manifest_count

  MW_NAME="$name" \
  MW_NAMESPACE="$CLUSTER_NAME" \
  MW_MANAGED_BY="$MANIFESTWORK_MANAGED_BY" \
  MW_POLICY="$policy" \
  MW_SELECTION="$selection" \
  MW_SOURCE="${source_dir#"$RESOURCES_PATH"/}" \
  MW_MANIFESTS="$manifests_file" \
  MW_CONFIGS="$configs_file" \
  yq --null-input '
    .apiVersion = "work.open-cluster-management.io/v1" |
    .kind = "ManifestWork" |
    .metadata.name = strenv(MW_NAME) |
    .metadata.namespace = strenv(MW_NAMESPACE) |
    .metadata.labels."app.kubernetes.io/managed-by" = strenv(MW_MANAGED_BY) |
    .metadata.labels."sot/policy" = strenv(MW_POLICY) |
    .metadata.labels."sot/selection" = strenv(MW_SELECTION) |
    .metadata.annotations."sot/source-path" = strenv(MW_SOURCE) |
    .spec.deleteOption.propagationPolicy = "Orphan" |
    .spec.manifestConfigs = load(strenv(MW_CONFIGS)) |
    .spec.workload.manifests = load(strenv(MW_MANIFESTS))
  ' >"$output_file" || die "ManifestWork oluşturulamadı: $name"

  # Kritik alanlar üretilen dosyadan tekrar okunarak doğrulanır.
  manifest_count="$(yq 'length' "$manifests_file")"
  [[ "$(yq '.spec.deleteOption.propagationPolicy' "$output_file")" == "Orphan" ]] \
    || die "ManifestWork deleteOption doğrulaması başarısız: $output_file"
  [[ "$(yq '.spec.workload.manifests | length' "$output_file")" == "$manifest_count" ]] \
    || die "ManifestWork manifest sayısı doğrulaması başarısız: $output_file"
  [[ "$(yq '[.spec.manifestConfigs[] | select(.updateStrategy.type == "CreateOnly")] | length' "$output_file")" == "$manifest_count" ]] \
    || die "ManifestWork CreateOnly doğrulaması başarısız (her manifest için bir CreateOnly girdisi olmalı): $output_file"

  local size
  size="$(wc -c <"$output_file" | tr -d ' ')"
  if (( size > MANIFESTWORK_SIZE_LIMIT )); then
    warn "$(basename "$output_file") $size bayt; OCM 500 KiB manifest sınırını aşabilir, dizini bölmeyi düşünün."
  fi
}

# base dışındaki her seçim için ManifestWork üretir. Önce tüm hedef dizinler
# doğrulanır; biri bile eksikse hiçbir dosya üretilmeden script sonlanır.
generate_manifestworks() {
  [[ "$GENERATE_MANIFESTWORK" == true ]] || return 0

  local i policy value source_dir name file
  local target_policies=()
  local target_values=()
  local target_dirs=()

  for ((i = 0; i < ${#SELECTED_POLICIES[@]}; i++)); do
    policy="${SELECTED_POLICIES[$i]}"
    value="${SELECTED_VALUES[$i]}"
    source_dir="$(selection_source_dir "$policy" "$value")" || continue
    validate_kustomize_dir "$source_dir"
    target_policies+=("$policy")
    target_values+=("$value")
    target_dirs+=("$source_dir")
  done

  if [[ ${#target_policies[@]} -eq 0 ]]; then
    info 'Bilgi: overlay/change seçimi olmadığı için ManifestWork üretilmedi.'
    return 0
  fi

  info ''
  info "ManifestWork'ler derleniyor (${KUSTOMIZE_CMD[*]}):"
  for ((i = 0; i < ${#target_policies[@]}; i++)); do
    policy="${target_policies[$i]}"
    value="${target_values[$i]}"
    source_dir="${target_dirs[$i]}"
    name="$(manifestwork_name "$CLUSTER_NAME-$policy-$value")"
    file="manifestwork-$name.yaml"
    if contains "$file" "${MANIFESTWORK_FILES[@]+"${MANIFESTWORK_FILES[@]}"}"; then
      die "Aynı ManifestWork adı birden fazla seçim için üretildi: $name"
    fi

    render_manifests "$source_dir" "$WORK_DIR/manifests.yaml"
    inspect_manifests "$WORK_DIR/manifests.yaml" "$policy ($value)"
    build_manifest_configs "$WORK_DIR/manifests.yaml" "$WORK_DIR/configs.yaml" "$policy ($value)"
    build_manifestwork "$WORK_DIR/manifests.yaml" "$WORK_DIR/configs.yaml" "$WORK_DIR/$file" \
      "$name" "$policy" "$value" "$source_dir"
    MANIFESTWORK_FILES+=("$file")
  done
}

# ---------------------------------------------------------------------------
# Çıktı
# ---------------------------------------------------------------------------

# Label komutlarını çalıştırılabilir bir script olarak hazırlar.
write_label_script() {
  local target="$1"
  local command
  {
    printf '#!/usr/bin/env bash\n'
    printf '# %s tarafından %s cluster için üretildi.\n' "$SCRIPT_NAME" "$CLUSTER_NAME"
    printf 'set -o errexit\nset -o nounset\nset -o pipefail\n\n'
    for command in "${LABEL_COMMANDS[@]}"; do
      printf '%s\n' "$command"
    done
  } >"$target"
  chmod +x "$target"
}

# Üretilen komutları terminale yazdırır; label scriptini ve ManifestWork
# dosyalarını çıktı dizinine taşır. Dosyalar ancak tüm adımlar başarılıysa
# yazıldığı için hata durumunda yarım çıktı kalmaz.
write_output() {
  local command file
  printf '\nÜretilen label komutları:\n'
  for command in "${LABEL_COMMANDS[@]}"; do
    printf '%s\n' "$command"
  done

  [[ -n "$OUTPUT_FILE" ]] || OUTPUT_FILE="$OUTPUT_DIR/apply-labels-$CLUSTER_NAME.sh"
  write_label_script "$WORK_DIR/labels.sh"
  mv "$WORK_DIR/labels.sh" "$OUTPUT_FILE" || die "Label scripti yazılamadı: $OUTPUT_FILE"

  printf '\nÜretilen dosyalar:\n'
  printf '  %s\n' "$OUTPUT_FILE"
  for file in "${MANIFESTWORK_FILES[@]+"${MANIFESTWORK_FILES[@]}"}"; do
    mv "$WORK_DIR/$file" "$OUTPUT_DIR/$file" || die "ManifestWork yazılamadı: $OUTPUT_DIR/$file"
    printf '  %s\n' "$OUTPUT_DIR/$file"
  done

  printf '\nHub üzerinde uygulamak için:\n'
  printf '  bash %s\n' "$OUTPUT_FILE"
  for file in "${MANIFESTWORK_FILES[@]+"${MANIFESTWORK_FILES[@]}"}"; do
    printf '  oc apply -f %s\n' "$OUTPUT_DIR/$file"
  done
}

# ---------------------------------------------------------------------------
# Ana akış
# ---------------------------------------------------------------------------

# Scriptin ana akışını yönetir: argüman, envanter, kullanıcı seçimleri ve çıktı.
main() {
  parse_args "$@"
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/acm-day2.XXXXXX")"
  prepare_output_dir
  select_ui_tool
  load_inventory
  # Araç kontrolü menülerden önce yapılır; eksik araç seçimler bittikten
  # sonra değil, en başta fark edilir.
  prepare_manifestwork_tools

  if [[ -z "$CLUSTER_NAME" ]]; then
    CLUSTER_NAME="$(ui_input 'Managed cluster adını girin')"
  else
    info "Managed cluster: $CLUSTER_NAME"
  fi
  validate_cluster_name

  local policy
  choose_common_overlay_groups
  for policy in "${POLICIES[@]}"; do
    if policy_has_change "$policy"; then
      choose_change "$policy"
    elif ! common_group_contains "$policy"; then
      choose_overlay "$policy"
    fi
  done
  build_commands
  generate_manifestworks
  write_output
}

main "$@"
