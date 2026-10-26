# Procuppa Toolbox – náhled

Náhledová verze kalkulaček Procuppa Toolbox: https://erozaxx.github.io/procuppa-toolbox/

Zdrojem je privátní repo `procuppa_apps` (`apps/toolbox-*.html`, rozcestník a tento README v `deploy/pages/`). Soubory se sem kopírují skriptem `deploy/deploy-pages.sh`, needitujte je tady, při dalším nasazení se přepíšou.

Stránky mají `noindex, nofollow`, vyhledávače je nemají indexovat. Výpočty běží jen v prohlížeči a zadané hodnoty se nikam neodesílají. Ven jde jen načtení fontu, Chart.js z CDN a kurzů ČNB v toolboxu 1.

## Zrcadlo kurzů ČNB

ČNB neposílá CORS hlavičky, takže prohlížeč nemůže kurzy číst přímo z cnb.cz. Proto je tady zrcadlo ročních kurzových lístků ČNB (kurzy devizového trhu) v adresáři `cnb/`:

- `https://erozaxx.github.io/procuppa-toolbox/cnb/rok-RRRR.txt`, například [rok-2026.txt](https://erozaxx.github.io/procuppa-toolbox/cnb/rok-2026.txt), od roku 2020
- `https://erozaxx.github.io/procuppa-toolbox/cnb/index.json` se seznamem roků, datem posledního lístku (`lastDate`) a časem poslední změny (`updated`)

Soubory jsou bajt po bajtu stejné jako `rok.txt?rok=RRRR` na cnb.cz: hlavička `Datum|1 AUD|…|100 JPY|…`, řádky `DD.MM.RRRR|kurz|…`, desetinná čárka, kurz se vztahuje k počtu jednotek z hlavičky. Hlavička se může v průběhu roku opakovat se změněným seznamem měn (například 2022). Zdroj: [Česká národní banka](https://www.cnb.cz/cs/financni-trhy/devizovy-trh/kurzy-devizoveho-trhu/kurzy-devizoveho-trhu/).

Aktualizuje je workflow `.github/workflows/cnb-mirror.yml` v pracovní dny ve 13:45 a 15:45 UTC (ČNB vyhlašuje kurzy po 14:30 pražského času). Commituje jen při změně dat. Stažený soubor uloží jen tehdy, když začíná `Datum|`, všechny řádky patří k požadovanému roku a nemá méně lístků než uložená verze, jinak běh skončí chybou a zrcadlo zůstane, jak bylo. Starší roky jde dotáhnout ručně přes Actions, Run workflow s `from_year`. `cnb/` plní jen workflow, nasazovací skript na něj nesahá.
