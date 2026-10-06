#!/usr/bin/env bash
#
# ACM Day-2 policy overlay analizcisi ve managed cluster label üreticisi.
#
#   ./acm-day2-label-generator.sh --repo /path/to/policy-repo
#   ./acm-day2-label-generator.sh --repo https://github.com/example/policy-repo.git
#   POLICY_REPO=/path/to/policy-repo ./acm-day2-label-generator.sh
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
OUTPUT_FILE=""
UI_TOOL=""
CLUSTER_NAME=""

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

POLICIES=()
POLICY_COUNT=0
OVERLAY_POLICIES=()
OVERLAYS=()
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

# Scriptin kullanım seçeneklerini ve örnek komutlarını ekrana basar.
usage() {
  cat <<EOF
Kullanım: $SCRIPT_NAME [--repo PATH_OR_GIT_URL] [--output /path/to/file]

Seçenekler:
  --repo VALUE      Yerel policy-repo yolu veya Git repo URL'si (varsayılan: POLICY_REPO)
  --output PATH     Üretilen oc komutlarını dosyaya kaydet
  -h, --help        Bu yardımı göster

Repo verilmezse örnek mock envanter kullanılır.
EOF
}

# Hata mesajını stderr'e yazıp scripti kontrollü şekilde sonlandırır.
die() {
  printf 'Hata: %s\n' "$*" >&2
  exit 1
}

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

# Komut satırı seçeneklerini ayrıştırır ve ilgili global değişkenleri doldurur.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || die "--repo bir yol bekler."
        REPO_PATH="$2"
        shift 2
        ;;
      --output)
        [[ $# -ge 2 ]] || die "--output bir dosya yolu bekler."
        OUTPUT_FILE="$2"
        shift 2
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
    read -r -p "$prompt [$default_value]: " answer
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

# Gerçek policy repo bulunamadığında test amacıyla örnek policy envanterini yükler.
load_mock_inventory() {
  local entry policy overlay
  for entry in "${MOCK_OVERLAYS[@]}"; do
    policy="${entry%%|*}"
    overlay="${entry#*|}"
    OVERLAY_POLICIES+=("$policy")
    OVERLAYS+=("$overlay")
    if ! policy_exists "$policy"; then
      POLICIES+=("$policy")
      POLICY_COUNT=$((POLICY_COUNT + 1))
    fi
  done
  for policy in "${MOCK_BASE_POLICIES[@]}"; do
    BASE_POLICIES+=("$policy")
    if ! policy_exists "$policy"; then
      POLICIES+=("$policy")
      POLICY_COUNT=$((POLICY_COUNT + 1))
    fi
  done
  for entry in "${MOCK_CHANGES[@]}"; do
    policy="${entry%%|*}"
    CHANGE_POLICIES+=("$policy")
    CHANGES+=("${entry#*|}")
    if ! policy_exists "$policy"; then
      POLICIES+=("$policy")
      POLICY_COUNT=$((POLICY_COUNT + 1))
    fi
  done
}

# Gerçek repo içindeki resources/<policy>/overlays/<overlay>,
# resources/<policy>/change/<change> ve resources/<policy>/base dizinlerini
# tarayıp policy envanterini oluşturur.
load_repo_inventory() {
  local resource_dir policy overlays_dir overlay base_dir relative_dir change_dir
  local inventory_file
  inventory_file="$(mktemp "${TMPDIR:-/tmp}/policy-repo-inventory.XXXXXX")"

  find "$RESOURCES_PATH" -mindepth 2 -maxdepth 4 -type d -print >"$inventory_file"
  while IFS= read -r resource_dir; do
    case "$resource_dir" in
      */resources/*/overlays)
        policy="${resource_dir%/overlays}"
        policy="${policy##*/}"
        while IFS= read -r -d '' overlay_dir; do
          overlay="${overlay_dir##*/}"
          OVERLAY_POLICIES+=("$policy")
          OVERLAYS+=("$overlay")
          if ! policy_exists "$policy"; then
            POLICIES+=("$policy")
            POLICY_COUNT=$((POLICY_COUNT + 1))
          fi
        done < <(find "$resource_dir" -mindepth 1 -maxdepth 1 -type d -print0)
        ;;
      */resources/*/change)
        # Yalnızca resources/<policy>/change dizinini kabul et; örneğin
        # overlays/change gibi daha derindeki dizinler policy sayılmaz.
        relative_dir="${resource_dir#"$RESOURCES_PATH"/}"
        [[ "$relative_dir" == */*/* ]] && continue
        policy="${relative_dir%/change}"
        while IFS= read -r -d '' change_dir; do
          CHANGE_POLICIES+=("$policy")
          CHANGES+=("${change_dir##*/}")
          if ! policy_exists "$policy"; then
            POLICIES+=("$policy")
            POLICY_COUNT=$((POLICY_COUNT + 1))
          fi
        done < <(find "$resource_dir" -mindepth 1 -maxdepth 1 -type d -print0)
        ;;
      */resources/*/base)
        base_dir="${resource_dir%/base}"
        policy="${base_dir##*/}"
        BASE_POLICIES+=("$policy")
        if ! policy_exists "$policy"; then
          POLICIES+=("$policy")
          POLICY_COUNT=$((POLICY_COUNT + 1))
        fi
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
    trap 'rm -rf "$CLONE_DIR"' EXIT HUP INT TERM
    printf 'Git repo klonlanıyor: %s\n' "$REPO_PATH"
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
    printf 'Repo envanteri okundu: %s\n' "$RESOURCES_PATH"
  else
    load_mock_inventory
    printf 'Bilgi: Gerçek policy repo bulunamadı; mock envanter kullanılıyor.\n'
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

# Policy'nin change/ altında en az bir dizini olup olmadığını kontrol eder.
policy_has_change() {
  local policy="$1" i
  for ((i = 0; i < ${#CHANGE_POLICIES[@]}; i++)); do
    [[ "${CHANGE_POLICIES[$i]}" == "$policy" ]] && return 0
  done
  return 1
}

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
choose_change() {
  local policy="$1"
  local menu_options=()
  local item selected_index
  while IFS= read -r item; do
    [[ -n "$item" ]] && menu_options+=("change-$item")
  done < <(policy_changes "$policy")
  local overlay_count=0
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    menu_options+=("overlays-$item")
    overlay_count=$((overlay_count + 1))
  done < <(policy_overlays "$policy" | sort -u)
  if [[ $overlay_count -eq 0 ]] && contains "$policy" "${BASE_POLICIES[@]+"${BASE_POLICIES[@]}"}"; then
    menu_options+=("base")
  fi

  selected_index="$(ui_menu "$policy policy için change seçin" "${menu_options[@]}")"
  SELECTED_POLICIES+=("$policy")
  SELECTED_VALUES+=("${menu_options[$((selected_index - 1))]}")
}

# Kullanıcı seçimlerini oc label managedcluster komutlarına dönüştürür.
# SELECTED_VALUES label değerini hazır tutar: base, overlays-<x> veya change-<x>.
build_commands() {
  local i policy value
  for ((i = 0; i < ${#SELECTED_POLICIES[@]}; i++)); do
    policy="${SELECTED_POLICIES[$i]}"
    value="${SELECTED_VALUES[$i]}"
    LABEL_COMMANDS+=("oc label managedcluster $CLUSTER_NAME sot/$policy=$value --overwrite")
  done
}

# Üretilen komutları terminale yazdırır ve istenirse dosyaya kaydeder.
write_output() {
  local command
  printf '\nÜretilen label komutları:\n'
  for command in "${LABEL_COMMANDS[@]}"; do
    printf '%s\n' "$command"
  done
  if [[ -n "$OUTPUT_FILE" ]]; then
    : >"$OUTPUT_FILE"
    for command in "${LABEL_COMMANDS[@]}"; do
      printf '%s\n' "$command" >>"$OUTPUT_FILE"
    done
    printf '\nKomutlar kaydedildi: %s\n' "$OUTPUT_FILE"
  fi
}

# Scriptin ana akışını yönetir: argüman, envanter, kullanıcı seçimleri ve çıktı.
main() {
  parse_args "$@"
  select_ui_tool
  load_inventory

  CLUSTER_NAME="$(ui_input 'Managed cluster adını girin')"
  [[ -n "$CLUSTER_NAME" ]] || die 'Cluster adı boş bırakılamaz.'
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
  write_output
}

main "$@"