#!/usr/bin/env bash
# Stáhne roční kurzové lístky ČNB do adresáře zrcadla a přepíše index.json.
#
#   bash .github/scripts/cnb-mirror.sh [--out DIR] [--from-year RRRR]
#
# Bez --from-year stáhne aktuální rok (čas Europe/Prague), v lednu i předchozí rok.
# S --from-year stáhne všechny roky od RRRR do aktuálního (backfill, nejdřív 1991).
#
# Výstup v DIR (výchozí cnb):
#   rok-RRRR.txt  obsah od ČNB bajt po bajtu beze změny (UTF-8, ve skutečnosti ASCII)
#   index.json    { "updated": ISO, "years": [...], "lastDate": "DD.MM.RRRR" }
#
# Soubor se přepíše jen po kontrole: HTTP 200, platné UTF-8, první řádek "Datum|",
# každý datový řádek "DD.MM.RRRR|" s požadovaným rokem, aspoň jeden datový řádek
# a ne méně řádků než stávající soubor. ČNB na neexistující rok vrací aktuální rok
# s HTTP 200, proto se kontroluje rok v každém řádku.
# index.json se přepíše jen při změně dat, "updated" je čas poslední změny.
#
# Exit 0 = hotovo (i beze změny), 1 = selhalo stažení nebo kontrola aspoň jednoho roku.
# Při chybě zůstanou stávající soubory nedotčené.

set -euo pipefail

# CNB_YEAR_URL přepíše zdroj (pro testy); rok se připojí na konec.
CNB_URL="${CNB_YEAR_URL:-https://www.cnb.cz/cs/financni-trhy/devizovy-trh/kurzy-devizoveho-trhu/kurzy-devizoveho-trhu/rok.txt?rok=}"
OUT="cnb"
FROM_YEAR=""

log()  { printf '[cnb] %s\n' "$*"; }
# Ve GitHub Actions se varování a chyby zobrazí jako anotace běhu.
warn() { if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::warning::%s\n' "$*"; else printf '[cnb] VAROVÁNÍ: %s\n' "$*" >&2; fi; }
err()  { if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::error::%s\n' "$*"; else printf '[cnb] CHYBA: %s\n' "$*" >&2; fi; }
die()  { err "$*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out)       [ $# -ge 2 ] || die "--out chce adresář"; OUT="$2"; shift ;;
    --from-year) [ $# -ge 2 ] || die "--from-year chce rok"; FROM_YEAR="$2"; shift ;;
    -h|--help)   sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "neznámá volba: $1" ;;
  esac
  shift
done

for cmd in curl iconv python3; do
  command -v "$cmd" >/dev/null || die "chybí $cmd"
done

CUR_YEAR="$(TZ=Europe/Prague date +%Y)"
CUR_MONTH="$(TZ=Europe/Prague date +%-m)"

if [ -n "$FROM_YEAR" ]; then
  [[ "$FROM_YEAR" =~ ^[0-9]{4}$ ]] || die "--from-year musí být rok RRRR, ne '$FROM_YEAR'"
  [ "$FROM_YEAR" -ge 1991 ] || die "ČNB má roční lístky od 1991, ne od $FROM_YEAR"
  [ "$FROM_YEAR" -le "$CUR_YEAR" ] || die "--from-year $FROM_YEAR je v budoucnosti (aktuální rok $CUR_YEAR)"
  YEARS=($(seq "$FROM_YEAR" "$CUR_YEAR"))
elif [ "$CUR_MONTH" -eq 1 ]; then
  # V lednu dotáhnout i konec předchozího roku (poslední prosincový lístek).
  YEARS=("$((CUR_YEAR - 1))" "$CUR_YEAR")
else
  YEARS=("$CUR_YEAR")
fi

mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Počet datových řádků (bez hlaviček Datum|...).
data_rows() { grep -vc '^Datum|' "$1" || true; }

# Stáhne a zkontroluje jeden rok. Návrat: 0 = uloženo nebo beze změny,
# 1 = chyba, 2 = ČNB pro aktuální rok ještě nemá data (začátek ledna).
fetch_year() {
  local year="$1" tmp="$TMP/rok-$1.txt" dest="$OUT/rok-$1.txt" code first bad rows old_rows
  code="$(curl -sS --retry 3 --retry-delay 15 --retry-all-errors --connect-timeout 20 --max-time 90 \
    -A 'procuppa-toolbox cnb-mirror (+https://github.com/Erozaxx/procuppa-toolbox)' \
    -o "$tmp" -w '%{http_code}' "${CNB_URL}${year}")" || { err "rok $year: stažení selhalo (curl)"; return 1; }
  [ "$code" = "200" ] || { err "rok $year: HTTP $code"; return 1; }
  [ -s "$tmp" ] || { err "rok $year: prázdná odpověď"; return 1; }
  iconv -f UTF-8 -t UTF-8 "$tmp" >/dev/null 2>&1 || { err "rok $year: odpověď není platné UTF-8"; return 1; }

  first="$(head -n 1 "$tmp")"
  [[ "$first" == Datum\|* ]] || { err "rok $year: první řádek nezačíná 'Datum|': ${first:0:80}"; return 1; }

  rows="$(grep -c "^[0-3][0-9]\.[01][0-9]\.${year}|" "$tmp" || true)"
  bad="$(grep -v '^Datum|' "$tmp" | grep -v "^[0-3][0-9]\.[01][0-9]\.${year}|" | head -n 1 || true)"
  if [ "$rows" -eq 0 ]; then
    if [ "$year" = "$CUR_YEAR" ]; then
      warn "rok $year: ČNB zatím nemá žádný lístek (vrací jiný rok), přeskakuji"
      return 2
    fi
    err "rok $year: odpověď neobsahuje žádný řádek roku $year (první datový řádek: ${bad:0:40})"
    return 1
  fi
  [ -z "$bad" ] || { err "rok $year: neočekávaný řádek: ${bad:0:80}"; return 1; }

  if [ -f "$dest" ]; then
    if cmp -s "$tmp" "$dest"; then
      log "rok $year: beze změny ($rows lístků)"
      return 0
    fi
    old_rows="$(data_rows "$dest")"
    if [ "$rows" -lt "$old_rows" ]; then
      err "rok $year: nová verze má $rows lístků, uložená $old_rows; nepřepisuji"
      return 1
    fi
  fi
  mv "$tmp" "$dest"
  log "rok $year: uloženo $dest ($rows lístků, poslední $(tail -n 1 "$dest" | cut -d'|' -f1))"
}

FAILED=0
for year in "${YEARS[@]}"; do
  rc=0
  fetch_year "$year" || rc=$?
  if [ "$rc" -eq 1 ]; then FAILED=1; fi
  # Backfill: mezi roky krátká pauza, ať ČNB nedostane salvu požadavků.
  if [ "${#YEARS[@]}" -gt 2 ]; then sleep 2; fi
done

# index.json z toho, co v zrcadle opravdu je. "updated" se mění jen se změnou years/lastDate.
python3 -I - "$OUT" <<'PY'
import json, os, re, sys
from datetime import datetime, timezone

out = sys.argv[1]
years = sorted(int(m.group(1)) for f in os.listdir(out)
               if (m := re.fullmatch(r"rok-(\d{4})\.txt", f)))
last_date = None
if years:
    with open(os.path.join(out, f"rok-{years[-1]}.txt"), encoding="utf-8") as fh:
        rows = [l.split("|", 1)[0] for l in fh.read().splitlines()
                if l and not l.startswith("Datum|")]
    last_date = rows[-1] if rows else None

path = os.path.join(out, "index.json")
old = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as fh:
            old = json.load(fh)
    except (OSError, ValueError):
        old = {}
if old.get("years") == years and old.get("lastDate") == last_date and old.get("updated"):
    print(f"[cnb] index.json beze změny (lastDate {last_date})")
    sys.exit(0)

index = {
    "updated": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "years": years,
    "lastDate": last_date,
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(index, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.replace(tmp, path)
print(f"[cnb] index.json: roky {years[0] if years else '-'}..{years[-1] if years else '-'}, lastDate {last_date}")
PY

[ "$FAILED" -eq 0 ] || die "aspoň jeden rok se nepodařilo stáhnout nebo neprošel kontrolou"
log "hotovo"
