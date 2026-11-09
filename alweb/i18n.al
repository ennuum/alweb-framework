# alweb.i18n — internationalisation : catalogues de traductions, choix de la langue de chaque requête, pluriels,
# dates, nombres et montants dans la langue du visiteur.
#
#   use alweb.i18n as i18n
#   i18n.I18n(app, "locales", {"default": "fr"})          # locales/fr.json, locales/en.json… ; pose app.i18n
#
#   locales/en.json :  {"Bonjour {nom}": "Hello {nom}",
#                       "articles": {"one": "{n} article", "other": "{n} articles"},
#                       "compte": {"titre": "Your account"}}           # clé « compte.titre »
#
# Gabarits : {{ _("Bonjour {nom}", {"nom": u.nom}) }}   {{ _n("articles", total) }}   {{ prix | currency("EUR") }}
#            {{ article.cree_le | date("long") }}   {{ cree | reltime }}   <html lang="{{ lang }}" dir="{{ lang_dir }}">
#            {% for l in locales %}<a href="{{ l.url }}">{{ l.name }}</a>{% endfor %}
# Code :     tr := i18n.translator(req)   puis   tr.t("Bonjour {nom}", {"nom": nom}), tr.n("articles", 3),
#            tr.date(t, "long"), tr.number(1234.5), tr.currency(9.9, "EUR"), tr.relative(t)
#
# Langue d'une requête, dans l'ordre (option « detect ») : préfixe d'URL (/en/… si « prefix »), paramètre ?lang=xx
# (retenu ensuite par un cookie), fonction « user » (préférence du compte), session (clé « lang »), cookie
# alweb_lang, en-tête Accept-Language, puis la langue par défaut. Seules les langues proposées sont retenues (les
# fichiers du dossier, ou l'option « locales ») ; « fr-CA » demandé donne « fr » si seul « fr » existe, et « en »
# demandé donne « en-GB » si c'est la seule variante proposée.
#
# Une clé absente est cherchée dans la langue de base (fr-CA -> fr), puis dans la langue par défaut ; à défaut la
# clé elle-même est affichée : écrire les clés dans la langue par défaut (« Bonjour {nom} ») évite d'en faire le
# catalogue. Une clé finissant par « _html » donne du HTML sûr (variables échappées). Pluriels : catégories CLDR
# zero, one, two, few, many, other (français : 0 et 1 au singulier ; russe, polonais, arabe… gérés).

from core use len, type, to_int, to_float, is_callable
from collections use append, keys
use os as _os
use io as _io
use json as _json
use string as _s
use time as _time
use alweb.chain as _chain
use alweb.errors as _err
use alweb.templates as _tpl
use alweb.messages as _msg
use web.http.header_value as _hv
use web.server.request_dispatch as _rd
use web.http.response as _response

const COOKIE := "alweb_lang"
const ERROR_STATUSES := [400, 401, 403, 404, 405, 408, 413, 415, 422, 429, 500, 502, 503]
const PLURAL_CATEGORIES := ["zero", "one", "two", "few", "many", "other"]
const RTL := ["ar", "he", "fa", "ur", "ps", "yi", "dv", "ckb"]

const NAMES := {"fr": "Français", "en": "English", "es": "Español", "de": "Deutsch", "it": "Italiano",
                "pt": "Português", "nl": "Nederlands", "ar": "العربية", "zh": "中文", "ja": "日本語", "ko": "한국어",
                "ru": "Русский", "uk": "Українська", "pl": "Polski", "tr": "Türkçe", "sv": "Svenska", "da": "Dansk",
                "nb": "Norsk bokmål", "fi": "Suomi", "el": "Ελληνικά", "cs": "Čeština", "ro": "Română",
                "hu": "Magyar", "he": "עברית", "hi": "हिन्दी", "sw": "Kiswahili", "wo": "Wolof", "ln": "Lingála",
                "bm": "Bamanankan", "ha": "Hausa", "yo": "Yorùbá", "vi": "Tiếng Việt", "id": "Bahasa Indonesia",
                "fr-CA": "Français (Canada)", "fr-CH": "Français (Suisse)", "fr-BE": "Français (Belgique)",
                "en-GB": "English (UK)", "en-US": "English (US)", "pt-BR": "Português (Brasil)",
                "pt-PT": "Português (Portugal)", "es-MX": "Español (México)", "de-CH": "Deutsch (Schweiz)"}

# ================================================================ codes de langue

# « fr_ca » -> « fr-CA » ; null si le texte n'est pas un code de langue (lettres, chiffres, tirets ; 2 à 20).
func normalize(code):
    if type(code) != "str":
        return null
    c := _s.replace(_s.trim(code), "_", "-")
    if len(c) < 2 or len(c) > 20:
        return null
    for ch in c:
        x := str(ch)
        if not ((x >= "a" and x <= "z") or (x >= "A" and x <= "Z") or (x >= "0" and x <= "9") or x == "-"):
            return null
    parts := _s.split(c, "-")
    out := _s.lower(parts[0])
    if len(out) < 2 or len(out) > 8:
        return null
    i := 1
    while i < len(parts):
        p := parts[i]
        if p == "":
            return null
        if len(p) == 2:
            out = out + "-" + _s.upper(p)
        elif len(p) == 4:
            out = out + "-" + _s.upper(p[0:1]) + _s.lower(p[1:4])
        else:
            out = out + "-" + _s.lower(p)
        i += 1
    return out

# Langue de base : « fr-CA » -> « fr ».
func base(code):
    k := _s.find(code, "-")
    return code if k < 0 else code[0:k]

# Codes de l'en-tête Accept-Language, du préféré au moins voulu (q=0 exclus).
func parse_accept_language(header):
    if header == null or header == "":
        return []
    items := []
    order := 0
    for part in _s.split(header, ","):
        bits := _s.split(part, ";")
        code := _s.trim(bits[0])
        q := 1.0
        j := 1
        while j < len(bits):
            b := _s.trim(bits[j])
            if _s.starts_with(b, "q="):
                q = _to_q(b[2:len(b)])
            j += 1
        if code == "*":
            continue
        c := normalize(code)
        if c != null and q > 0:
            append(items, [q, order, c])
            order += 1
    # tri stable par q décroissant
    i := 1
    while i < len(items):
        x := items[i]
        j := i - 1
        while j >= 0 and items[j][0] < x[0]:
            items[j + 1] = items[j]
            j -= 1
        items[j + 1] = x
        i += 1
    return [it[2] for it in items]

func _to_q(text):
    try:
        v := to_float(_s.trim(text))
        return 0.0 if v < 0 else (1.0 if v > 1 else v)
    catch e:
        return 0.0

# Meilleure langue proposée pour un code demandé : exacte, puis langue de base, puis une variante de la même base.
func best_match(code, supported):
    c := normalize(code)
    if c == null:
        return null
    for s in supported:
        if _s.lower(s) == _s.lower(c):
            return s
    b := base(c)
    for s in supported:
        if s == b:
            return s
    for s in supported:
        if base(s) == b:
            return s
    return null

# ================================================================ pluriels (règles CLDR, nombres entiers et décimaux)

func plural_category(locale, n):
    b := base(locale)
    x := -n if n < 0 else n
    i := to_int(x)
    whole := x == i
    if b in ["ja", "zh", "ko", "vi", "th", "id", "ms", "my", "lo", "km", "yo", "wo", "bm"]:
        return "other"
    if b in ["fr", "hi", "fa", "bn", "gu", "kn", "zu", "am", "ln", "ff"] or (b == "pt" and locale != "pt-PT"):
        return "one" if i == 0 or i == 1 else "other"
    if b in ["ru", "uk", "be"]:
        if not whole:
            return "other"
        if i % 10 == 1 and i % 100 != 11:
            return "one"
        if i % 10 >= 2 and i % 10 <= 4 and not (i % 100 >= 12 and i % 100 <= 14):
            return "few"
        return "many"
    if b == "pl":
        if not whole:
            return "other"
        if i == 1:
            return "one"
        if i % 10 >= 2 and i % 10 <= 4 and not (i % 100 >= 12 and i % 100 <= 14):
            return "few"
        return "many"
    if b in ["cs", "sk"]:
        if not whole:
            return "many"
        if i == 1:
            return "one"
        return "few" if i >= 2 and i <= 4 else "other"
    if b == "ar":
        if not whole:
            return "other"
        if i == 0:
            return "zero"
        if i == 1:
            return "one"
        if i == 2:
            return "two"
        if i % 100 >= 3 and i % 100 <= 10:
            return "few"
        if i % 100 >= 11:
            return "many"
        return "other"
    if b == "he":
        if whole and i == 1:
            return "one"
        return "two" if whole and i == 2 else "other"
    # anglais, allemand, espagnol, italien, néerlandais, langues scandinaves… : 1 au singulier
    return "one" if whole and i == 1 else "other"

# ================================================================ nombres

# [séparateur décimal, séparateur de milliers, motif monétaire, motif du pourcentage, groupement minimal]
const NUMBERS := {
    "fr": [",", " ", "{n} {s}", "{n} %", 1],
    "fr-CA": [",", " ", "{n} {s}", "{n} %", 1],
    "fr-CH": [",", " ", "{n} {s}", "{n} %", 1],
    "en": [".", ",", "{s}{n}", "{n}%", 1],
    "de": [",", ".", "{n} {s}", "{n} %", 1],
    "de-CH": [".", "’", "{s} {n}", "{n}%", 1],
    "es": [",", ".", "{n} {s}", "{n} %", 2],
    "es-MX": [".", ",", "{s}{n}", "{n} %", 1],
    "it": [",", ".", "{n} {s}", "{n}%", 1],
    "pt": [",", ".", "{s} {n}", "{n}%", 1],
    "pt-PT": [",", " ", "{n} {s}", "{n}%", 2],
    "nl": [",", ".", "{s} {n}", "{n}%", 1],
    "ru": [",", " ", "{n} {s}", "{n} %", 1],
    "uk": [",", " ", "{n} {s}", "{n}%", 1],
    "pl": [",", " ", "{n} {s}", "{n}%", 2],
    "sv": [",", " ", "{n} {s}", "{n} %", 1],
    "tr": [",", ".", "{s}{n}", "%{n}", 1],
    "ar": [".", ",", "{n} {s}", "{n}%", 1],
    "ja": [".", ",", "{s}{n}", "{n}%", 1],
    "zh": [".", ",", "{s}{n}", "{n}%", 1],
    "ko": [".", ",", "{s}{n}", "{n}%", 1],
    "hi": [".", ",", "{s}{n}", "{n}%", 1]}

const CURRENCIES := {"EUR": "€", "USD": "$", "GBP": "£", "JPY": "¥", "CNY": "¥", "XOF": "F CFA",
                     "XAF": "FCFA", "CHF": "CHF", "CAD": "$", "MAD": "MAD", "NGN": "₦", "GHS": "GH₵", "KES": "KSh",
                     "INR": "₹", "BRL": "R$", "KRW": "₩", "RUB": "₽", "UAH": "₴", "PLN": "zł", "TRY": "₺",
                     "SEK": "kr", "NOK": "kr", "DKK": "kr", "MXN": "$", "AUD": "$", "DZD": "DA", "TND": "DT",
                     "XPF": "F CFP", "CDF": "FC", "GNF": "FG", "HTG": "G"}
const NO_DECIMALS := ["JPY", "KRW", "XOF", "XAF", "XPF", "CLP", "VND", "ISK", "UGX", "GNF", "RWF", "KMF", "DJF", "BIF", "PYG"]

func _number_spec(locale):
    if locale in NUMBERS:
        return NUMBERS[locale]
    b := base(locale)
    return NUMBERS[b] if b in NUMBERS else NUMBERS["en"]

func _group(digits, sep, min_grouping):
    n := len(digits)
    if sep == "" or n <= 3 or (min_grouping == 2 and n <= 4):
        return digits
    first := n % 3
    out := digits[0:first] if first > 0 else ""
    i := first
    while i < n:
        out = out + (sep if out != "" else "") + digits[i:i + 3]
        i += 3
    return out

func _pow10(d):
    f := 1
    i := 0
    while i < d:
        f = f * 10
        i += 1
    return f

# Nombre dans la langue : decimals null -> entier tel quel, décimal à 3 chiffres au plus (zéros finaux retirés) ;
# fixed : garder les zéros finaux (montants).
func format_number(locale, x, decimals=null, fixed=false, grouping=true):
    if x == null:
        return ""
    if type(x) == "str":
        x = to_float(x)
    spec := _number_spec(locale)
    if decimals == null:
        decimals = 0 if type(x) == "int" else 3
    neg := x < 0
    v := -x if neg else x
    f := _pow10(decimals)
    r := to_int(v * f + 0.5) if decimals > 0 or type(v) != "int" else v
    ip := r // f
    fp := r % f
    s := _group(str(ip), spec[1] if grouping else "", spec[4])
    if decimals > 0:
        frac := str(fp)
        while len(frac) < decimals:
            frac = "0" + frac
        if not fixed:
            while len(frac) > 0 and frac[len(frac) - 1:len(frac)] == "0":
                frac = frac[0:len(frac) - 1]
        if frac != "":
            s = s + spec[0] + frac
    if neg and r != 0:
        s = "-" + s
    return s

func currency_symbol(locale, code):
    b := base(locale)
    if code == "USD":
        if locale == "en-US" or locale == "en" or locale == "es-MX":
            return "$"
        return "$US" if b == "fr" else "US$"
    if code == "CAD":
        if locale == "fr-CA" or locale == "en-CA":
            return "$"
        return "$CA" if b == "fr" else "CA$"
    if code == "MXN" and locale != "es-MX":
        return "MX$"
    if code == "AUD" and locale != "en-AU":
        return "$AU" if b == "fr" else "A$"
    return CURRENCIES[code] if code in CURRENCIES else code

func format_currency(locale, x, code, decimals=null):
    if x == null:
        return ""
    if type(x) == "str":
        x = to_float(x)
    c := _s.upper(code)
    d := decimals if decimals != null else (0 if c in NO_DECIMALS else 2)
    spec := _number_spec(locale)
    neg := x < 0
    n := format_number(locale, -x if neg else x, d, true)
    out := _s.replace(_s.replace(spec[2], "{n}", n), "{s}", currency_symbol(locale, c))
    return ("-" + out) if neg and n != format_number(locale, 0, d, true) else out

func format_percent(locale, x, decimals=0):
    if x == null:
        return ""
    return _s.replace(_number_spec(locale)[3], "{n}", format_number(locale, x * 100.0, decimals))

# ================================================================ dates

const DATES := {
    "fr": {"short": "{dd}/{MM}/{yyyy}", "medium": "{d} {MMM} {yyyy}", "long": "{d} {MMMM} {yyyy}",
           "full": "{EEEE} {d} {MMMM} {yyyy}", "time": "{HH}:{mm}", "time_s": "{HH}:{mm}:{ss}",
           "at": "{date} à {time}", "at_short": "{date} {time}"},
    "fr-CA": {"short": "{yyyy}-{MM}-{dd}", "medium": "{d} {MMM} {yyyy}", "long": "{d} {MMMM} {yyyy}",
              "full": "{EEEE} {d} {MMMM} {yyyy}", "time": "{HH} h {mm}", "time_s": "{HH} h {mm} min {ss} s",
              "at": "{date} à {time}", "at_short": "{date} {time}"},
    "en": {"short": "{M}/{d}/{yyyy}", "medium": "{MMM} {d}, {yyyy}", "long": "{MMMM} {d}, {yyyy}",
           "full": "{EEEE}, {MMMM} {d}, {yyyy}", "time": "{h}:{mm} {a}", "time_s": "{h}:{mm}:{ss} {a}",
           "at": "{date} at {time}", "at_short": "{date}, {time}"},
    "en-GB": {"short": "{dd}/{MM}/{yyyy}", "medium": "{d} {MMM} {yyyy}", "long": "{d} {MMMM} {yyyy}",
              "full": "{EEEE} {d} {MMMM} {yyyy}", "time": "{HH}:{mm}", "time_s": "{HH}:{mm}:{ss}",
              "at": "{date} at {time}", "at_short": "{date}, {time}"},
    "de": {"short": "{dd}.{MM}.{yyyy}", "medium": "{dd}.{MM}.{yyyy}", "long": "{d}. {MMMM} {yyyy}",
           "full": "{EEEE}, {d}. {MMMM} {yyyy}", "time": "{HH}:{mm}", "time_s": "{HH}:{mm}:{ss}",
           "at": "{date} um {time}", "at_short": "{date}, {time}"},
    "es": {"short": "{d}/{M}/{yyyy}", "medium": "{d} {MMM} {yyyy}", "long": "{d} de {MMMM} de {yyyy}",
           "full": "{EEEE}, {d} de {MMMM} de {yyyy}", "time": "{H}:{mm}", "time_s": "{H}:{mm}:{ss}",
           "at": "{date}, {time}", "at_short": "{date}, {time}"},
    "it": {"short": "{dd}/{MM}/{yyyy}", "medium": "{d} {MMM} {yyyy}", "long": "{d} {MMMM} {yyyy}",
           "full": "{EEEE} {d} {MMMM} {yyyy}", "time": "{HH}:{mm}", "time_s": "{HH}:{mm}:{ss}",
           "at": "{date} alle ore {time}", "at_short": "{date}, {time}"},
    "pt": {"short": "{dd}/{MM}/{yyyy}", "medium": "{d} de {MMM} de {yyyy}", "long": "{d} de {MMMM} de {yyyy}",
           "full": "{EEEE}, {d} de {MMMM} de {yyyy}", "time": "{HH}:{mm}", "time_s": "{HH}:{mm}:{ss}",
           "at": "{date} às {time}", "at_short": "{date}, {time}"},
    "nl": {"short": "{dd}-{MM}-{yyyy}", "medium": "{d} {MMM} {yyyy}", "long": "{d} {MMMM} {yyyy}",
           "full": "{EEEE} {d} {MMMM} {yyyy}", "time": "{HH}:{mm}", "time_s": "{HH}:{mm}:{ss}",
           "at": "{date} om {time}", "at_short": "{date} {time}"},
    "iso": {"short": "{yyyy}-{MM}-{dd}", "medium": "{yyyy}-{MM}-{dd}", "long": "{yyyy}-{MM}-{dd}",
            "full": "{yyyy}-{MM}-{dd}", "time": "{HH}:{mm}", "time_s": "{HH}:{mm}:{ss}",
            "at": "{date} {time}", "at_short": "{date} {time}"}}

_extra_dates := {}
_extra_names := {}

# Ajoute ou remplace les formats d'une langue (mêmes clés que DATES ; les absentes sont prises à l'ISO) et, si
# donnés, les noms des mois et jours (months, months_abbr, days, days_abbr : lundi en premier).
func register_formats(locale, formats, names=null):
    d := {}
    for k in keys(DATES["iso"]):
        d[k] = formats[k] if formats != null and k in formats else DATES["iso"][k]
    _extra_dates[locale] = d
    if names != null:
        _extra_names[locale] = names

func _date_spec(locale):
    if locale in _extra_dates:
        return _extra_dates[locale]
    if locale in DATES:
        return DATES[locale]
    b := base(locale)
    if b in _extra_dates:
        return _extra_dates[b]
    return DATES[b] if b in DATES else DATES["iso"]

func _name(locale, kind, i):
    for k in [locale, base(locale)]:
        if k in _extra_names:
            return _extra_names[k][kind][i]
    b := base(locale)
    if not (b in ["fr", "en", "es", "de", "it", "pt", "nl"]):
        b = "en"
    if kind == "months" or kind == "months_abbr":
        return _time.month_name(i + 1, b, kind == "months_abbr")
    return _time.day_name(i, b, kind == "days_abbr")

func _two(n):
    return ("0" + str(n)) if n < 10 else str(n)

# Champs d'une date : timestamp (secondes, vu avec le décalage offset), texte ISO (« 2026-11-08 », « 2026-11-08
# 14:05:00 » : heure murale telle quelle ; avec « Z » ou « +01:00 » : convertie), ou champs de time.
func date_fields(v, offset=0):
    if v == null:
        return null
    ty := type(v)
    if ty == "int" or ty == "float":
        return _time.fields_at_offset(to_int(v), offset)
    if ty == "str":
        f := _time.parse_iso(_s.trim(v))
        if f["has_time"] and f["utc_offset"] != null:
            return _time.fields_at_offset(_time.timegm(f) - f["utc_offset"], offset)
        return f
    if ty == "dict" and "year" in v:
        return v
    _err.alweb_error("i18n", "date illisible : " + str(v))

func _pattern(pattern, f, locale):
    out := pattern
    if _s.contains(out, "{EEEE}"):
        out = _s.replace(out, "{EEEE}", _name(locale, "days", f["weekday"]))
    if _s.contains(out, "{MMMM}"):
        out = _s.replace(out, "{MMMM}", _name(locale, "months", f["month"] - 1))
    if _s.contains(out, "{MMM}"):
        out = _s.replace(out, "{MMM}", _name(locale, "months_abbr", f["month"] - 1))
    h := f["hour"] if "hour" in f and f["hour"] != null else 0
    h12 := h % 12
    pairs := [["{yyyy}", str(f["year"])], ["{MM}", _two(f["month"])], ["{M}", str(f["month"])], ["{dd}", _two(f["day"])],
              ["{d}", str(f["day"])], ["{HH}", _two(h)], ["{H}", str(h)], ["{h}", str(12 if h12 == 0 else h12)],
              ["{mm}", _two(f["minute"] if "minute" in f else 0)], ["{ss}", _two(f["second"] if "second" in f else 0)],
              ["{a}", "AM" if h < 12 else "PM"]]
    for p in pairs:
        out = _s.replace(out, p[0], p[1])
    return out

const STYLES := ["short", "medium", "long", "full"]

func format_date(locale, v, style="medium", offset=0):
    f := date_fields(v, offset)
    if f == null:
        return ""
    spec := _date_spec(locale)
    return _pattern(spec[style] if style in STYLES else _custom(style), f, locale)

func format_time(locale, v, seconds=false, offset=0):
    f := date_fields(v, offset)
    if f == null:
        return ""
    return _pattern(_date_spec(locale)["time_s" if seconds else "time"], f, locale)

func format_datetime(locale, v, style="medium", offset=0):
    f := date_fields(v, offset)
    if f == null:
        return ""
    spec := _date_spec(locale)
    if not (style in STYLES):
        return _pattern(_custom(style), f, locale)
    d := _pattern(spec[style], f, locale)
    t := _pattern(spec["time"], f, locale)
    joint := spec["at"] if style == "long" or style == "full" else spec["at_short"]
    return _s.replace(_s.replace(joint, "{date}", d), "{time}", t)

# Motif libre : « {d} {MMMM} » … (mêmes jetons que DATES).
func _custom(style):
    if type(style) != "str" or not _s.contains(style, "{"):
        _err.alweb_error("i18n", "style de date inconnu : " + str(style) + " (short, medium, long, full ou motif « {d} {MMMM} »)")
    return style

# ---------------------------------------------------------------- temps relatif

const RELATIVE := {
    "fr": ["il y a {x}", "dans {x}", "à l'instant", {"minute": ["minute", "minutes"], "hour": ["heure", "heures"], "day": ["jour", "jours"], "month": ["mois", "mois"], "year": ["an", "ans"]}],
    "en": ["{x} ago", "in {x}", "just now", {"minute": ["minute", "minutes"], "hour": ["hour", "hours"], "day": ["day", "days"], "month": ["month", "months"], "year": ["year", "years"]}],
    "es": ["hace {x}", "dentro de {x}", "ahora", {"minute": ["minuto", "minutos"], "hour": ["hora", "horas"], "day": ["día", "días"], "month": ["mes", "meses"], "year": ["año", "años"]}],
    "de": ["vor {x}", "in {x}", "gerade eben", {"minute": ["Minute", "Minuten"], "hour": ["Stunde", "Stunden"], "day": ["Tag", "Tagen"], "month": ["Monat", "Monaten"], "year": ["Jahr", "Jahren"]}],
    "it": ["{x} fa", "tra {x}", "proprio ora", {"minute": ["minuto", "minuti"], "hour": ["ora", "ore"], "day": ["giorno", "giorni"], "month": ["mese", "mesi"], "year": ["anno", "anni"]}],
    "pt": ["há {x}", "em {x}", "agora", {"minute": ["minuto", "minutos"], "hour": ["hora", "horas"], "day": ["dia", "dias"], "month": ["mês", "meses"], "year": ["ano", "anos"]}],
    "nl": ["{x} geleden", "over {x}", "zojuist", {"minute": ["minuut", "minuten"], "hour": ["uur", "uur"], "day": ["dag", "dagen"], "month": ["maand", "maanden"], "year": ["jaar", "jaar"]}]}

func _timestamp(v):
    ty := type(v)
    if ty == "int" or ty == "float":
        return to_float(v)
    f := date_fields(v, 0)
    t := _time.timegm(f)
    if ty == "str" and _time.parse_iso(_s.trim(v))["utc_offset"] != null:
        return to_float(t)
    return to_float(t - _time.local_utc_offset())          # heure murale : celle du serveur

# « il y a 3 minutes », « dans 2 jours », « à l'instant » (moins de 45 s).
func format_relative(locale, v, now=null):
    if v == null:
        return ""
    t := _timestamp(v)
    n := now if now != null else _time.time()
    delta := t - n
    future := delta > 0
    s := -delta if delta < 0 else delta
    b := base(locale)
    spec := RELATIVE[b] if b in RELATIVE else RELATIVE["en"]
    if s < 45:
        return spec[2]
    unit := "minute"
    count := to_int(s / 60 + 0.5)
    if s >= 45 * 60:
        unit = "hour"
        count = to_int(s / 3600 + 0.5)
    if s >= 22 * 3600:
        unit = "day"
        count = to_int(s / 86400 + 0.5)
    if s >= 26 * 86400:
        unit = "month"
        count = to_int(s / (30.44 * 86400) + 0.5)
    if s >= 320 * 86400:
        unit = "year"
        count = to_int(s / (365.25 * 86400) + 0.5)
    if count < 1:
        count = 1
    words := spec[3][unit]
    x := str(count) + " " + (words[0] if count == 1 else words[1])
    return _s.replace(spec[1] if future else spec[0], "{x}", x)

# ---------------------------------------------------------------- listes

const LISTS := {"fr": [" et ", " ou "], "en": [" and ", " or "], "es": [" y ", " o "], "de": [" und ", " oder "],
                "it": [" e ", " o "], "pt": [" e ", " ou "], "nl": [" en ", " of "]}

# « a, b et c » (kind "or" : « a, b ou c ») ; en anglais « a, b, and c ».
func format_list(locale, items, kind="and"):
    xs := [str(x) for x in items]
    n := len(xs)
    if n == 0:
        return ""
    if n == 1:
        return xs[0]
    b := base(locale)
    w := LISTS[b] if b in LISTS else LISTS["en"]
    word := w[1] if kind == "or" else w[0]
    if n == 2:
        return xs[0] + word + xs[1]
    head := _s.join(", ", xs[0:n - 1])
    if b == "en":
        return head + "," + word + xs[n - 1]
    return head + word + xs[n - 1]

# ================================================================ catalogues

func _is_plural(d):
    if not ("other" in d):
        return false
    for k in keys(d):
        if not (k in PLURAL_CATEGORIES):
            return false
    return true

# {"a": {"b": "x"}} -> {"a.b": "x"} ; les dicts de pluriel restent des dicts.
func flatten(d, prefix="", out=null):
    if out == null:
        out = {}
    for k in keys(d):
        v := d[k]
        key := prefix + k
        if type(v) == "dict" and not _is_plural(v):
            flatten(v, key + ".", out)
        else:
            out[key] = v
    return out

# Remplace {nom} par vars["nom"] ; `{{` et `}}` donnent `{` et `}`. Les nombres de {n} sont mis en forme dans la langue.
func interpolate(text, vars, locale, html=false):
    if vars == null or not _s.contains(text, "{"):
        return _s.replace(_s.replace(text, "{{", "{"), "}}", "}") if vars != null else text
    out := ""
    i := 0
    n := len(text)
    while i < n:
        c := text[i:i + 1]
        if (c == "{" or c == "}") and i + 1 < n and text[i + 1:i + 2] == c:
            out = out + c
            i += 2
            continue
        if c == "{":
            j := i + 1
            while j < n and text[j:j + 1] != "}" and text[j:j + 1] != "{":
                j += 1
            if j < n and text[j:j + 1] == "}":
                name := text[i + 1:j]
                if name in vars:
                    v := vars[name]
                    s := ""
                    if (name == "n" or name == "count") and (type(v) == "int" or type(v) == "float"):
                        s = format_number(locale, v)
                    elif v != null:
                        s = str(v)
                    out = out + (_tpl.escape(v) if html and not (name == "n" or name == "count") else s)
                    i = j + 1
                    continue
        out = out + c
        i += 1
    return out

# ================================================================ I18n (une par application)

class I18n:
    # app : alweb.App (ou null : hors application) ; directory : dossier des catalogues <langue>.json (ou null) ;
    # options : default ("fr"), locales (langues proposées ; défaut : celles du dossier), detect, cookie, param,
    # prefix (true : /en/… dans les URL), prefix_default (préfixer aussi la langue par défaut), user (fn(req) ->
    # code), timezone ("local", "UTC", décalage en secondes ou « +01:00 »), currency (défaut de |currency).
    func init(app=null, directory=null, options=null):
        o := options if options != null else {}
        self.app = app
        self.directory = directory
        self.default = normalize(o["default"] if "default" in o else "fr")
        if self.default == null:
            _err.alweb_error("i18n", "langue par défaut invalide : " + str(o["default"]))
        self.detect = o["detect"] if "detect" in o else ["prefix", "param", "user", "session", "cookie", "header"]
        self.cookie = o["cookie"] if "cookie" in o else COOKIE
        self.param = o["param"] if "param" in o else "lang"
        self.prefix = o["prefix"] == true if "prefix" in o else false
        self.prefix_default = o["prefix_default"] == true if "prefix_default" in o else false
        self.user = o["user"] if "user" in o else null
        self.currency = o["currency"] if "currency" in o else null
        self.timezone = o["timezone"] if "timezone" in o else "local"
        self.catalogs = {}               # langue -> {clé: texte ou dict de pluriel}
        self.missing = {}                # langue -> {clé: true} : traductions manquantes vues
        self.debug = app != null and app.debug
        self._stamps = {}
        self._checked = 0.0
        if directory != null:
            self.load()
        given := o["locales"] if "locales" in o else null
        if given != null:
            self.locales = []
            for c in given:
                nc := normalize(c)
                if nc == null:
                    _err.alweb_error("i18n", "code de langue invalide : " + str(c))
                append(self.locales, nc)
        else:
            self.locales = [self.default]
            for c in keys(self.catalogs):
                if not (c in self.locales):
                    append(self.locales, c)
        if not (self.default in self.locales):
            self.locales = [self.default] + self.locales
        if app != null:
            app.i18n = self
            app.middleware(_chain.Hook((req) => _before(self, req), (req, r) => _after(self, req, r)))
            app.context_processor((req) => self.context(self.for_request(req), req))
            # pages d'erreur dans la langue du visiteur (sauf statuts déjà pris par app.error_handler)
            for st in ERROR_STATUSES:
                if not (st in app.router.error_handlers):
                    app.router.on_error(st, (req, status, message) => error_page(req, status, message))

    # (Re)lit les fichiers <langue>.json du dossier.
    func load():
        if self.directory == null or not _os.exists(self.directory):
            return self
        for name in _os.list_dir(self.directory):
            if _s.ends_with(name, ".json"):
                code := normalize(name[0:len(name) - 5])
                if code == null:
                    continue
                path := _os.join(self.directory, name)
                data := null
                try:
                    data = _json.parse(_io.read_file(path))
                catch e:
                    _err.alweb_error("i18n", path + " : JSON invalide : " + str(e.message))
                if type(data) != "dict":
                    _err.alweb_error("i18n", path + " : un objet JSON est attendu")
                self.catalogs[code] = flatten(data)
                self._stamps[path] = _os.mtime(path)
        return self

    # Mode debug : catalogues relus quand un fichier change (au plus une vérification par seconde).
    func _refresh():
        now := _time.monotonic()
        if now - self._checked < 1.0:
            return
        self._checked = now
        for path in keys(self._stamps):
            if _os.exists(path) and _os.mtime(path) != self._stamps[path]:
                self.load()
                return

    # Ajoute des traductions (dict, imbriqué ou non) à une langue.
    func add(locale, entries):
        code := normalize(locale)
        if not (code in self.catalogs):
            self.catalogs[code] = {}
        flat := flatten(entries)
        for k in keys(flat):
            self.catalogs[code][k] = flat[k]
        if not (code in self.locales):
            append(self.locales, code)
        return self

    # Langues à consulter pour une langue : elle, sa base, la langue par défaut, sa base.
    func chain(locale):
        out := []
        for c in [locale, base(locale), self.default, base(self.default)]:
            if not (c in out):
                append(out, c)
        return out

    # Texte d'une clé : catalogues de l'application (langue, base, défaut), puis ceux des paquets
    # (register_messages), puis ceux d'alweb (alweb.messages).
    func lookup(locale, key):
        ch := self.chain(locale)
        for c in ch:
            if c in self.catalogs and key in self.catalogs[c]:
                v := self.catalogs[c][key]
                if v != null and v != "":
                    return v
        for p in _PACKAGES:
            for c in ch:
                if c in p and key in p[c]:
                    return p[c][key]
        for c in ch:
            if c in _msg.CATALOGS and key in _msg.CATALOGS[c]:
                return _msg.CATALOGS[c][key]
        return null

    # La clé est-elle traduite dans cette langue (ou sa base), par l'application ou par alweb ?
    func has_own(locale, key):
        for c in [locale, base(locale)]:
            if c in self.catalogs and key in self.catalogs[c] and self.catalogs[c][key] != null and self.catalogs[c][key] != "":
                return true
            if c in _msg.CATALOGS and key in _msg.CATALOGS[c]:
                return true
            for p in _PACKAGES:
                if c in p and key in p[c]:
                    return true
        return false

    func _note_missing(locale, key):
        if locale == self.default and not (locale in self.catalogs):
            return                       # clés écrites dans la langue par défaut, sans catalogue : rien ne manque
        if not (locale in self.missing):
            self.missing[locale] = {}
        if not (key in self.missing[locale]):
            self.missing[locale][key] = true
            if self.debug:
                print("[i18n] traduction manquante (" + locale + ") : " + key)

    func offset():
        tz := self.timezone
        if tz == null or tz == "local":
            return _time.local_utc_offset()
        if tz == "UTC" or tz == "utc" or tz == "Z":
            return 0
        if type(tz) == "int":
            return tz
        if type(tz) == "str" and len(tz) == 6 and (tz[0:1] == "+" or tz[0:1] == "-"):
            v := to_int(tz[1:3]) * 3600 + to_int(tz[4:6]) * 60
            return v if tz[0:1] == "+" else -v
        _err.alweb_error("i18n", "fuseau invalide : " + str(tz) + " (\"local\", \"UTC\", secondes ou « +01:00 »)")

    # Traducteur d'une langue (courriels, tâches de fond, scripts).
    func translator(locale=null):
        if self.debug:
            self._refresh()
        c := self.default if locale == null else best_match(locale, self.locales)
        return Translator(self, c if c != null else self.default)

    # Langue d'une requête (sans la retenir) : [code, a lu Accept-Language].
    func negotiate(req):
        for way in self.detect:
            c := null
            if way == "prefix":
                c = req.state["i18n_prefix"] if "i18n_prefix" in req.state else null
            elif way == "param":
                c = req.state["i18n_set"] if "i18n_set" in req.state else null
            elif way == "user":
                if self.user != null:
                    c = self.user(req)
            elif way == "session":
                if "session" in req.state:
                    c = req.state["session"].get("lang")
            elif way == "cookie":
                c = req.cookie(self.cookie)
            elif way == "header":
                for want in parse_accept_language(req.header("Accept-Language")):
                    m := best_match(want, self.locales)
                    if m != null:
                        return [m, true]
                return [self.default, true]
            if c != null:
                m := best_match(c, self.locales)
                if m != null:
                    return [m, false]
        return [self.default, false]

    # Traducteur de la requête (choisi une fois, gardé dans req.state["i18n"]).
    func for_request(req):
        if "i18n" in req.state:
            return req.state["i18n"]
        if self.debug:
            self._refresh()
        r := self.negotiate(req)
        tr := Translator(self, r[0])
        tr.from_header = r[1]
        req.state["i18n"] = tr
        return tr

    # Préfixe d'URL d'une langue ("" pour la langue par défaut, sauf prefix_default).
    func url_prefix(locale):
        if not self.prefix or (locale == self.default and not self.prefix_default):
            return ""
        return "/" + locale

    # Même page dans une autre langue : /en/articles avec le préfixe, sinon /articles?lang=en.
    func switch_url(req, locale):
        path := req.path()
        if self.prefix:
            return self.url_prefix(locale) + path
        q := req.query_string()
        rest := ""
        if q != null and q != "":
            for part in _s.split(q, "&"):
                if part != "" and not _s.starts_with(part, self.param + "="):
                    rest = rest + "&" + part
        return path + "?" + self.param + "=" + locale + rest

    # Variables de gabarit : _, _n, i18n, lang, lang_dir, locales, _filters (et url_for préfixé).
    func context(tr, req=null):
        ctx := {"_": (key, vars=null) => tr.markup(key, vars), "_n": (key, n, vars=null) => tr.markup_n(key, n, vars),
                "i18n": tr, "lang": tr.locale, "lang_dir": tr.dir(), "_filters": tr.filters()}
        if req != null:
            ls := []
            for c in self.locales:
                append(ls, {"code": c, "name": tr.locale_name(c), "current": c == tr.locale, "url": self.switch_url(req, c)})
            ctx["locales"] = ls
            if self.prefix and self.app != null:
                p := self.url_prefix(tr.locale)
                if p != "":
                    ctx["url_for"] = (name, values=null) => p + self.app.router.url_for(name, values)
        return ctx

# ---------------------------------------------------------------- intergiciel

func _before(o, req):
    if o.prefix:
        path := req.path()
        segs := _s.split(path, "/")
        if len(segs) >= 2 and segs[1] != "":
            m := null
            for c in o.locales:
                if _s.lower(c) == _s.lower(segs[1]):
                    m = c
            if m != null:
                rest := path[len(segs[1]) + 1:len(path)]
                if rest == "":
                    rest = "/"
                q := req.query_string()
                req.state["i18n_prefix"] = m
                req.state["i18n_original_path"] = path
                req.target = rest + ("?" + q if q != null and q != "" else "")
                req._target = null
                req._query = null
    if o.param != null and o.param != "":
        v := req.query_param(o.param)
        if v != null:
            m := best_match(v, o.locales)
            if m != null:
                req.state["i18n_set"] = m
                if "session" in req.state:
                    req.state["session"].set("lang", m)
    return null

func _after(o, req, r):
    if "i18n_set" in req.state:
        r.set_cookie(o.cookie, req.state["i18n_set"], 31536000, "/", null, req.secure, true, "Lax")
    if "i18n" in req.state:
        tr := req.state["i18n"]
        if r.headers.get("Content-Language") == null:
            r.headers.set("Content-Language", tr.locale)
        if tr.from_header:
            v := r.headers.get("Vary")
            if v == null or v == "":
                r.headers.set("Vary", "Accept-Language")
            elif not _s.contains(_s.lower(v), "accept-language"):
                r.headers.set("Vary", v + ", Accept-Language")
    return r

_default := [null]

# Traducteur français sans catalogue de l'application (textes d'alweb quand l'application n'a pas d'I18n).
# Catalogues fournis par des paquets (ex. une marketplace de thèmes) : {"en": {clé: texte}, "es": {...}}, clés =
# texte français comme pour alweb.messages. Consultés après ceux de l'application (qui peuvent les remplacer dans
# locales/<langue>.json) et avant ceux d'alweb. Un même dict n'est enregistré qu'une fois.
_PACKAGES := []

func register_messages(catalogs):
    if type(catalogs) != "dict":
        raise("AlwebError", "i18n.register_messages : {langue: {clé: texte}} attendu")
    for p in _PACKAGES:
        if p == catalogs:
            return false
    append(_PACKAGES, catalogs)
    return true

func default_translator():
    if _default[0] == null:
        _default[0] = I18n(null, null, {"default": "fr"})
    return _default[0].translator("fr")

# Traducteur de la requête si l'application a une I18n, sinon le français d'alweb (formulaires, administration).
func translator_for(req):
    app := req.state["app"] if req != null and "app" in req.state else null
    if app != null and app.i18n != null:
        return app.i18n.for_request(req)
    return default_translator()

# ---------------------------------------------------------------- pages d'erreur

func _wants_html(req):
    accept := req.headers.get("accept", null, true)
    if accept == null:
        return false
    best := _hv.best_match(accept, ["text/html", "application/json", "text/plain"])
    return best == "text/html" and _hv.quality_of(accept, "text/html") > 0.0 and _s.contains(accept, "html")

# Page d'erreur dans la langue de la requête : gabarit errors/<statut>.html ou errors/error.html de l'application
# s'il existe (variables status, title, hint, message, home), sinon une page simple. JSON et texte : comme
# web.server (les API gardent leurs réponses).
func error_page(req, status, message=null):
    if not _wants_html(req):
        return _rd.error_response(req, status, message)
    app := req.state["app"] if "app" in req.state else null
    tr := translator_for(req)
    key := "alweb.error." + str(status)
    title := tr.t(key) if tr.owner.lookup(tr.locale, key) != null else tr.t("alweb.error.other", {"status": status})
    hk := "alweb.error.hint." + str(status)
    hint := tr.t(hk) if tr.owner.lookup(tr.locale, hk) != null else null
    home := "/"
    if app != null and app.i18n != null:
        home = app.i18n.url_prefix(tr.locale) + "/"
    if app != null and app.templates != null:
        for name in ["errors/" + str(status) + ".html", "errors/error.html"]:
            if _template_exists(app.templates, name):
                return app.render(req, name, {"status": status, "title": title, "hint": hint, "message": message, "home": home}, status)
    e := (v) => _tpl.escape(v)
    page := "<!DOCTYPE html>\n<html lang=\"" + e(tr.locale) + "\" dir=\"" + tr.dir() + "\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>" + e(title) + "</title>\n<style>body{margin:0;font:16px/1.5 system-ui,sans-serif;background:#f6f7f9;color:#1d2330}main{max-width:36rem;margin:12vh auto;padding:0 20px}.code{font-size:14px;color:#5b6475;letter-spacing:.08em}h1{font-size:28px;margin:4px 0 12px}a{color:#2f5bd3}@media (prefers-color-scheme:dark){body{background:#14171c;color:#e6e9ef}.code{color:#9aa3b2}a{color:#7b9cff}}</style>\n</head>\n<body><main>\n<p class=\"code\">" + str(status) + "</p>\n<h1>" + e(title) + "</h1>\n"
    if hint != null:
        page = page + "<p>" + e(hint) + "</p>\n"
    if message != null and message != "":
        page = page + "<p><small>" + e(message) + "</small></p>\n"
    page = page + "<p><a href=\"" + e(home) + "\">" + e(tr.t("alweb.error.home")) + "</a></p>\n</main></body>\n</html>\n"
    return _response.html(page, status)

func _template_exists(env, name):
    try:
        env.get(name)
        return true
    catch e:
        return false

# Traducteur de la requête : i18n.translator(req).t("…"). Sans I18n dans l'application : erreur explicite.
func translator(req):
    app := req.state["app"] if "app" in req.state else null
    if app == null or app.i18n == null:
        _err.alweb_error("i18n", "aucune internationalisation : créer i18n.I18n(app, dossier)")
    return app.i18n.for_request(req)

# ================================================================ Translator (une langue)

class Translator:
    func init(owner, locale):
        self.owner = owner
        self.locale = locale
        self.from_header = false
        self.offset = owner.offset()

    # Texte traduit, variables {nom} remplacées.
    func t(key, vars=null):
        return self._text(key, vars, null, false)

    # Pluriel : catégorie choisie par n (variable {n} fournie, mise en forme dans la langue).
    func n(key, count, vars=null):
        return self._text(key, vars, count, false)

    # Pour les gabarits : clés « _html » en HTML sûr, les autres échappées à l'affichage.
    func markup(key, vars=null):
        return self._text(key, vars, null, _s.ends_with(key, "_html"))

    func markup_n(key, count, vars=null):
        return self._text(key, vars, count, _s.ends_with(key, "_html"))

    func has(key):
        return self.owner.lookup(self.locale, key) != null

    func _text(key, vars, count, html):
        v := self.owner.lookup(self.locale, key)
        if v == null:
            self.owner._note_missing(self.locale, key)
            v = key
        elif self.locale != self.owner.default and not self.owner.has_own(self.locale, key):
            self.owner._note_missing(self.locale, key)
        all := {}
        if vars != null:
            for k in keys(vars):
                all[k] = vars[k]
        if count != null:
            all["n"] = count
        if type(v) == "dict":
            cat := plural_category(self.locale, count if count != null else (all["n"] if "n" in all else 0))
            v = v[cat] if cat in v and v[cat] != null else v["other"]
        out := interpolate(v, all if len(keys(all)) > 0 else null, self.locale, html)
        return _tpl.markup(out) if html else out

    func dir():
        return "rtl" if base(self.locale) in RTL else "ltr"

    func locale_name(code=null):
        c := code if code != null else self.locale
        if c in NAMES:
            return NAMES[c]
        return NAMES[base(c)] if base(c) in NAMES else c

    func number(x, decimals=null):
        return format_number(self.locale, x, decimals)

    func currency(x, code=null, decimals=null):
        c := code if code != null else self.owner.currency
        if c == null:
            _err.alweb_error("i18n", "devise non précisée : currency(montant, \"EUR\") ou option « currency »")
        return format_currency(self.locale, x, c, decimals)

    func percent(x, decimals=0):
        return format_percent(self.locale, x, decimals)

    func date(v, style="medium"):
        return format_date(self.locale, v, style, self.offset)

    func time(v, seconds=false):
        return format_time(self.locale, v, seconds, self.offset)

    func datetime(v, style="medium"):
        return format_datetime(self.locale, v, style, self.offset)

    func relative(v, now=null):
        return format_relative(self.locale, v, now)

    func list(items, kind="and"):
        return format_list(self.locale, items, kind)

    func month(m, abbr=false):
        return _name(self.locale, "months_abbr" if abbr else "months", m - 1)

    func weekday(d, abbr=false):
        return _name(self.locale, "days_abbr" if abbr else "days", d)

    # Filtres de gabarit dans cette langue : t, number, currency, percent, date, time, datetime, reltime, list.
    func filters():
        return {"t": (v, vars=null) => self.markup(str(v), vars), "number": (v, d=null) => self.number(v, d),
                "currency": (v, c=null, d=null) => self.currency(v, c, d), "percent": (v, d=0) => self.percent(v, d),
                "date": (v, s="medium") => self.date(v, s), "time": (v, s=false) => self.time(v, s),
                "datetime": (v, s="medium") => self.datetime(v, s), "reltime": (v) => self.relative(v),
                "list": (v, k="and") => self.list(v, k)}
