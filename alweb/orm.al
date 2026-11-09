# alweb.orm — tables déclarées, requêtes composées, relations, validation, migrations versionnées ; au-dessus
# de database.async_database (toutes les opérations s'attendent avec await).
#
#   use alweb.orm as orm
#   COMPTES := orm.table("comptes", {"id": orm.pk(), "nom": orm.text(40, unique=true), "mdp": orm.text(),
#                                     "cree_le": orm.timestamp(auto=true)})
#   ARTICLES := orm.table("articles", {"id": orm.pk(), "titre": orm.text(200), "texte": orm.text(),
#                                       "publie": orm.boolean(default=false), "auteur_id": orm.ref("comptes"),
#                                       "tags": orm.json(default=[]), "cree_le": orm.timestamp(auto=true)})
#   MIGRATIONS := [orm.migration(1, "tables initiales", [COMPTES, ARTICLES]),      # CREATE TABLE du dialecte
#                  orm.migration(2, "index", "CREATE INDEX articles_auteur ON articles (auteur_id)")]
#
#   db := alweb.database("sqlite:blog.db")                 # ou postgres://u:mdp@hôte/base, alexdb://u:mdp@hôte/base
#   await orm.migrate(db, MIGRATIONS)                      # applique les migrations manquantes, dans l'ordre
#   id := await ARTICLES.insert(db, {"titre": "Été", "texte": "...", "auteur_id": 1})
#   a := await ARTICLES.get(db, id)                        # dict, ou null
#   liste := await ARTICLES.where("publie", true).where("cree_le", ">", hier).order_by("-cree_le")
#                          .limit(10).offset(20).with_one(COMPTES, "auteur_id", "auteur").all(db)
#   n := await ARTICLES.where("auteur_id", 1).count(db)
#   trouves := await ARTICLES.search(["titre", "texte"], "été").all(db)     # OU, sans tenir compte de la casse
#   await ARTICLES.where("id", id).update(db, {"publie": true})
#   await ARTICLES.where("id", id).delete(db)
#   page := await ARTICLES.query().order_by("-id").paginate(db, 2, 10)     # {items, page, per_page, total, pages}
#
# Lignes : dict ; booléens, JSON et horodatages convertis dans les deux sens. Les noms de colonnes sont vérifiés
# d'après la déclaration (une colonne inconnue est une erreur) et toutes les valeurs passent en paramètres :
# pas d'injection SQL par ce chemin. insert / update valident les valeurs (obligatoires, longueur, type) :
# ValidationError avec le détail. where(col, op, valeur) : = != < > <= >= like in « is null » « is not null ».
# Relations : with_one(table, clé_étrangère, nom) et with_many(table, clé_étrangère_chez_elle, nom) chargent les
# lignes liées en une seule requête supplémentaire (pas de N+1).
# Migrations : table alweb_migrations (version, nom, date) ; chaque migration dans une transaction.

from core use len, type, to_int, to_float
from collections use append, keys
use time as _time
use asyncio as _aio
use json as _json
use string as _s

# ================================================================ colonnes

class Column:
    func init(kind, null_ok=false, default=null, max=null, unique=false, primary=false, auto=false, ref_table=null, has_default=false):
        self.kind = kind                 # integer, real, text, boolean, timestamp, json, pk
        self.null_ok = null_ok
        self.default = default
        self.has_default = has_default or default != null
        self.max = max
        self.unique = unique
        self.primary = primary
        self.auto = auto                 # timestamp : rempli à l'insertion
        self.ref_table = ref_table
        self.name = null

func pk():
    return Column("pk", false, null, null, false, true)

func integer(null_ok=false, default=null, unique=false):
    return Column("integer", null_ok, default, null, unique)

func real(null_ok=false, default=null):
    return Column("real", null_ok, default)

func text(max=null, null_ok=false, default=null, unique=false):
    return Column("text", null_ok, default, max, unique)

func boolean(default=false, null_ok=false):
    return Column("boolean", null_ok, default, null, false, false, false, null, true)

func timestamp(auto=false, null_ok=false):
    return Column("timestamp", null_ok or auto, null, null, false, false, auto)

func json(default=null, null_ok=true):
    return Column("json", null_ok, default, null, false, false, false, null, default != null)

# Clé étrangère vers table(id).
func ref(table_name, null_ok=false):
    return Column("integer", null_ok, null, null, false, false, false, table_name)

# ================================================================ tables

class Table:
    func init(name, columns):
        _check_ident(name)
        self.name = name
        self.columns = columns
        self.order = []
        self.pk = null
        for c in keys(columns):
            _check_ident(c)
            columns[c].name = c
            append(self.order, c)
            if columns[c].primary:
                self.pk = c
        if self.pk == null:
            raise("ORMError", "table " + name + " : clé primaire requise (orm.pk())")

    # CREATE TABLE pour SQLite (dialect "sqlite"), PostgreSQL ("postgres") ou le serveur ALEX DB ("alexdb").
    func create_sql(dialect="sqlite"):
        parts := []
        for name in self.order:
            c := self.columns[name]
            append(parts, name + " " + _sql_type(c, dialect) + _constraints(c, dialect))
        for name in self.order:
            c := self.columns[name]
            if c.ref_table != null:
                append(parts, "FOREIGN KEY (" + name + ") REFERENCES " + c.ref_table + " (id)")
        return "CREATE TABLE IF NOT EXISTS " + self.name + " (" + _s.join(", ", parts) + ")"

    func query():
        return Query(self)

    func where(col, a, b="\u0000"):
        return Query(self).where(col, a, b)

    func order_by(col):
        return Query(self).order_by(col)

    func search(cols, term):
        return Query(self).search(cols, term)

    func all(db):
        return Query(self).all(db)

    async func get(db, id):
        rows := await Query(self).where(self.pk, id).limit(1).all(db)
        return rows[0] if len(rows) > 0 else null

    # Insère une ligne (validée) ; rend son identifiant.
    async func insert(db, values):
        row := self._prepare(values, true)
        return await db.insert(self.name, row)

    # Valeurs prêtes pour la base : colonnes vérifiées, défauts, conversions, validation.
    func _prepare(values, is_insert):
        errors := []
        out := {}
        for k in keys(values):
            if not (k in self.columns):
                raise("ORMError", "table " + self.name + " : colonne inconnue « " + str(k) + " »")
        for name in self.order:
            c := self.columns[name]
            if c.primary:
                if name in values and values[name] != null:
                    out[name] = values[name]
                continue
            present := name in values
            v := values[name] if present else null
            if is_insert and not present:
                if c.auto:
                    v = _time.time()
                    present = true
                elif c.has_default:
                    v = c.default
                    present = true
            if not present:
                if is_insert and not c.null_ok:
                    append(errors, name + " : valeur requise")
                continue
            msg := _validate(c, v)
            if msg != null:
                append(errors, name + " : " + msg)
                continue
            out[name] = _to_db(c, v)
        if len(errors) > 0:
            raise("ValidationError", "table " + self.name + " : " + _s.join(" ; ", errors))
        return out

    func _from_db(row):
        if row == null:
            return null
        out := {}
        for k in keys(row):
            c := self.columns[k] if k in self.columns else null
            out[k] = _from_db_value(c, row[k]) if c != null else row[k]
        return out

func table(name, columns):
    return Table(name, columns)

# Index déclaré pour une migration : CREATE [UNIQUE] INDEX IF NOT EXISTS dans le dialecte de la base. ALEX DB
# n'indexe qu'une colonne : l'index y porte sur la première (un index composite sert d'abord à elle).
#   orm.migration(2, "index", [orm.index("messages_salon", "messages", ["salon_id", "id"])])
class Index:
    func init(name, table_name, columns, unique=false):
        _check_ident(name)
        _check_ident(table_name)
        cols := columns if type(columns) == "list" else [columns]
        if len(cols) == 0:
            raise("ORMError", "index " + name + " : au moins une colonne")
        for c in cols:
            _check_ident(c)
        self.name = name
        self.table = table_name
        self.columns = cols
        self.unique = unique

    func create_sql(dialect="sqlite"):
        cols := [self.columns[0]] if dialect == "alexdb" else self.columns
        return "CREATE " + ("UNIQUE " if self.unique else "") + "INDEX IF NOT EXISTS " + self.name + " ON " + self.table + " (" + _s.join(", ", cols) + ")"

func index(name, table_name, columns, unique=false):
    return Index(name, table_name, columns, unique)

# Colonne ajoutée à une table existante (migration) : ALTER TABLE … ADD COLUMN, sautée si la colonne existe déjà
# (base créée après coup, où CREATE TABLE l'a déjà mise). La colonne vient de la définition de la table :
#   orm.migration(3, "courriel", [orm.add_column(UTILISATEURS, "courriel"), orm.index(..., unique=true)])
# Une colonne NOT NULL doit avoir une valeur par défaut ; pour l'unicité, un index unique (SQLite refuse
# ADD COLUMN … UNIQUE).
class AddColumn:
    func init(table, column):
        if not (column in table.columns):
            raise("ORMError", "add_column : la table " + table.name + " n'a pas de colonne " + column)
        c := table.columns[column]
        if c.primary or c.unique:
            raise("ORMError", "add_column " + column + " : ni clé primaire ni UNIQUE (index unique à part)")
        if not c.null_ok and not c.has_default:
            raise("ORMError", "add_column " + column + " : NOT NULL demande une valeur par défaut")
        self.table = table.name
        self.column = c

    func create_sql(dialect="sqlite"):
        c := self.column
        sql := "ALTER TABLE " + self.table + " ADD COLUMN " + c.name + " " + _sql_type(c, dialect) + _constraints(c, dialect)
        if c.ref_table != null and dialect == "postgres":
            sql = sql + " REFERENCES " + c.ref_table + " (id)"
        return sql

func add_column(table, column):
    return AddColumn(table, column)

# La colonne existe-t-elle ? (requête qui ne lit rien : échoue sinon)
async func _has_column(db, table_name, column):
    try:
        await db.query("SELECT " + column + " FROM " + table_name + " WHERE 1 = 0")
        return true
    catch e:
        return false

# ALEX DB (AQL) : clé INT PRIMARY KEY attribuée par le serveur quand elle est omise (jamais réattribuée) ;
# booléens rangés en INT 0 / 1 comme avec SQLite (les valeurs de l'ORM sont donc les mêmes partout) ;
# horodatages et réels en FLOAT.
func _sql_type(c, dialect):
    if dialect == "alexdb":
        if c.kind == "pk":
            return "INT PRIMARY KEY"
        if c.kind == "integer" or c.kind == "boolean":
            return "INT"
        if c.kind == "real" or c.kind == "timestamp":
            return "FLOAT"
        if c.kind == "text" and c.max != null:
            return "VARCHAR(" + str(c.max) + ")"
        return "TEXT"
    if c.kind == "pk":
        return "INTEGER PRIMARY KEY AUTOINCREMENT" if dialect == "sqlite" else "BIGSERIAL PRIMARY KEY"
    if c.kind == "integer":
        return "INTEGER" if dialect == "sqlite" else "BIGINT"
    if c.kind == "real" or c.kind == "timestamp":
        return "REAL" if dialect == "sqlite" else "DOUBLE PRECISION"
    if c.kind == "boolean":
        return "INTEGER" if dialect == "sqlite" else "BOOLEAN"
    if c.kind == "text" and c.max != null and dialect != "sqlite":
        return "VARCHAR(" + str(c.max) + ")"
    return "TEXT"

func _constraints(c, dialect):
    if c.primary:
        return ""
    out := ""
    if not c.null_ok:
        out = out + " NOT NULL"
    if c.unique:
        out = out + " UNIQUE"
    if c.has_default and c.default != null and c.kind != "json":
        d := c.default
        if c.kind == "boolean":
            d = ("TRUE" if d else "FALSE") if dialect == "postgres" else ("1" if d else "0")
        elif type(d) == "str":
            d = "'" + _s.replace(d, "'", "''") + "'"
        out = out + " DEFAULT " + str(d)
    return out

func _validate(c, v):
    if v == null:
        return null if c.null_ok else "valeur requise"
    t := type(v)
    if c.kind == "integer" and t != "int":
        return "entier attendu"
    if (c.kind == "real" or c.kind == "timestamp") and t != "int" and t != "float":
        return "nombre attendu"
    if c.kind == "boolean" and t != "bool":
        return "booléen attendu"
    if c.kind == "text":
        if t != "str":
            return "texte attendu"
        if c.max != null and len(v) > c.max:
            return str(c.max) + " caractères au plus"
    return null

func _to_db(c, v):
    if v == null:
        return null
    if c.kind == "boolean":
        return 1 if v else 0
    if c.kind == "json":
        return _json.stringify(v)
    return v

func _from_db_value(c, v):
    if v == null:
        return null
    if c.kind == "boolean":
        return v == 1 or v == true
    if c.kind == "json":
        try:
            return _json.parse(v) if type(v) == "str" else v
        catch e:
            return v
    if c.kind == "real" or c.kind == "timestamp":
        return to_float(v) if type(v) == "int" else v
    return v

func _check_ident(name):
    if type(name) != "str" or len(name) == 0 or len(name) > 63:
        raise("ORMError", "identifiant SQL invalide : " + str(name))
    i := 0
    for ch in name:
        c := str(ch)
        ok := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" or (i > 0 and c >= "0" and c <= "9")
        if not ok:
            raise("ORMError", "identifiant SQL invalide : " + name)
        i += 1

# ================================================================ requêtes

const OPS := ["=", "!=", "<", ">", "<=", ">=", "like", "in", "is null", "is not null"]

class Query:
    func init(t):
        self.table = t
        self.conds = []                  # [col, op, valeur]
        self.orders = []
        self.lim = null
        self.off = null
        self.relations = []              # ["one" | "many", table, clé, nom]

    func _copy():
        q := Query(self.table)
        q.conds = self.conds + []
        q.orders = self.orders + []
        q.lim = self.lim
        q.off = self.off
        q.relations = self.relations + []
        return q

    func _col(col):
        if not (col in self.table.columns):
            raise("ORMError", "table " + self.table.name + " : colonne inconnue « " + str(col) + " »")
        return col

    # where(col, valeur) : égalité ; where(col, op, valeur).
    func where(col, a, b="\u0000"):
        q := self._copy()
        op := "="
        v := a
        if b != "\u0000":
            op = _s.lower(a)
            v = b
        elif type(a) == "str" and (_s.lower(a) == "is null" or _s.lower(a) == "is not null"):
            op = _s.lower(a)
            v = null
        if not (op in OPS):
            raise("ORMError", "opérateur inconnu « " + str(op) + " »")
        c := self.table.columns[q._col(col)]
        append(q.conds, [col, op, v if op == "in" or op == "like" or op == "is null" or op == "is not null" else _to_db(c, v)])
        return q

    # Recherche : au moins une des colonnes contient term, sans tenir compte de la casse
    # (LOWER(a) LIKE ? OR LOWER(b) LIKE ?). % et _ dans term gardent leur sens de LIKE. term vide : sans effet.
    func search(cols, term):
        q := self._copy()
        names := cols if type(cols) == "list" else [cols]
        if len(names) == 0:
            raise("ORMError", "search : au moins une colonne")
        for c in names:
            q._col(c)
        if term == null or _s.trim(str(term)) == "":
            return q
        append(q.conds, [names, "search", "%" + _s.lower(_s.trim(str(term))) + "%"])
        return q

    # order_by("col") croissant, order_by("-col") décroissant ; appels cumulables.
    func order_by(col):
        q := self._copy()
        desc := _s.starts_with(col, "-")
        name := col[1:len(col)] if desc else col
        append(q.orders, name + (" DESC" if desc else " ASC"))
        q._col(name)
        return q

    func limit(n):
        q := self._copy()
        q.lim = to_int(n)
        return q

    func offset(n):
        q := self._copy()
        q.off = to_int(n)
        return q

    # Charge la ligne liée (clé étrangère locale) sous row[nom].
    func with_one(other, fk, name):
        q := self._copy()
        q._col(fk)
        append(q.relations, ["one", other, fk, name])
        return q

    # Charge les lignes liées (clé étrangère chez l'autre table) sous row[nom] (liste).
    func with_many(other, fk, name, order=null):
        q := self._copy()
        if not (fk in other.columns):
            raise("ORMError", "table " + other.name + " : colonne inconnue « " + fk + " »")
        append(q.relations, ["many", other, fk, name, order, self.table.pk])
        return q

    func _where_sql(params):
        if len(self.conds) == 0:
            return ""
        parts := []
        for c in self.conds:
            if c[1] == "search":
                ors := []
                for col in c[0]:
                    append(ors, "LOWER(" + col + ") LIKE ?")
                    append(params, c[2])
                append(parts, "(" + _s.join(" OR ", ors) + ")")
            elif c[1] == "is null" or c[1] == "is not null":
                append(parts, c[0] + " " + _s.upper(c[1]))
            elif c[1] == "in":
                vals := c[2]
                if len(vals) == 0:
                    append(parts, "1 = 0")
                else:
                    marks := []
                    for v in vals:
                        append(marks, "?")
                        append(params, _to_db(self.table.columns[c[0]], v))
                    append(parts, c[0] + " IN (" + _s.join(", ", marks) + ")")
            else:
                append(parts, c[0] + " " + (_s.upper(c[1]) if c[1] == "like" else c[1]) + " ?")
                append(params, c[2])
        return " WHERE " + _s.join(" AND ", parts)

    func sql():
        params := []
        q := "SELECT * FROM " + self.table.name + self._where_sql(params)
        if len(self.orders) > 0:
            q = q + " ORDER BY " + _s.join(", ", self.orders)
        if self.lim != null:
            q = q + " LIMIT " + str(self.lim)
        if self.off != null:
            q = q + (" LIMIT 9223372036854775807" if self.lim == null else "") + " OFFSET " + str(self.off)
        return [q, params]

    async func all(db):
        s := self.sql()
        rows := []
        for r in await db.query(s[0], s[1]):
            append(rows, self.table._from_db(r))
        for rel in self.relations:
            await _load_relation(db, rows, rel)
        return rows

    async func first(db):
        rows := await self.limit(1).all(db)
        return rows[0] if len(rows) > 0 else null

    async func count(db):
        params := []
        return await db.scalar("SELECT COUNT(*) FROM " + self.table.name + self._where_sql(params), params)

    async func exists(db):
        return (await self.limit(1).count(db)) > 0

    async func update(db, values):
        row := self.table._prepare(values, false)
        if len(row) == 0:
            return 0
        sets := []
        params := []
        for k in keys(row):
            append(sets, k + " = ?")
            append(params, row[k])
        r := await db.execute("UPDATE " + self.table.name + " SET " + _s.join(", ", sets) + self._where_sql(params), params)
        return r["rowcount"]

    async func delete(db):
        params := []
        r := await db.execute("DELETE FROM " + self.table.name + self._where_sql(params), params)
        return r["rowcount"]

    # Page n (à partir de 1) de per_page lignes : {items, page, per_page, total, pages}.
    async func paginate(db, page=1, per_page=20):
        p := page if page >= 1 else 1
        total := await self.count(db)
        items := await self.limit(per_page).offset((p - 1) * per_page).all(db)
        pages := (total + per_page - 1) // per_page
        return {"items": items, "page": p, "per_page": per_page, "total": total, "pages": pages, "has_prev": p > 1, "has_next": p < pages}

async func _load_relation(db, rows, rel):
    if len(rows) == 0:
        return
    kind := rel[0]
    other := rel[1]
    fk := rel[2]
    name := rel[3]
    if kind == "one":
        ids := []
        for r in rows:
            if r[fk] != null and not (r[fk] in ids):
                append(ids, r[fk])
        found := {}
        if len(ids) > 0:
            for o in await other.where(other.pk, "in", ids).all(db):
                found[o[other.pk]] = o
        for r in rows:
            r[name] = found[r[fk]] if r[fk] in found else null
        return
    owner_pk := rel[5]
    ids := []
    for r in rows:
        append(ids, r[owner_pk])
    q := other.where(fk, "in", ids)
    if len(rel) > 4 and rel[4] != null:
        q = q.order_by(rel[4])
    groups := {}
    for o in await q.all(db):
        key := o[fk]
        if not (key in groups):
            groups[key] = []
        append(groups[key], o)
    for r in rows:
        r[name] = groups[r[owner_pk]] if r[owner_pk] in groups else []

# ================================================================ migrations

# Dialecte SQL d'une base (database.async_database ou URL) : "postgres", "alexdb" (serveur ALEX DB, alexdb://)
# ou "sqlite" (SQLite, et le moteur embarqué memory: / alexdb:fichier.json).
func dialect(db):
    url := db if type(db) == "str" else db.url
    if _s.starts_with(url, "postgres://") or _s.starts_with(url, "postgresql://"):
        return "postgres"
    if _s.starts_with(url, "alexdb://"):
        return "alexdb"
    return "sqlite"

# Type SQL d'un réel (horodatages) dans le dialecte d'une base.
func float_type(db):
    d := dialect(db)
    return "REAL" if d == "sqlite" else ("FLOAT" if d == "alexdb" else "DOUBLE PRECISION")

# Migration : version (entier croissant), nom, instruction SQL, table (son CREATE TABLE dans le dialecte de la
# base), index (orm.index) ou liste de ces éléments.
func migration(version, name, statements):
    return {"version": version, "name": name, "statements": statements if type(statements) == "list" else [statements]}

const MIGRATIONS_TABLE := "alweb_migrations"

async func _ensure_table(db):
    await db.script("CREATE TABLE IF NOT EXISTS " + MIGRATIONS_TABLE + " (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at " + float_type(db) + " NOT NULL)")

# Versions déjà appliquées (liste croissante).
async func applied(db):
    await _ensure_table(db)
    out := []
    for r in await db.query("SELECT version FROM " + MIGRATIONS_TABLE + " ORDER BY version"):
        append(out, r["version"])
    return out

# Applique dans l'ordre les migrations dont la version n'est pas encore enregistrée ; chacune dans une
# transaction (avec son enregistrement). Rend la liste des versions appliquées par cet appel. Sûr quand plusieurs
# processus migrent ensemble : une version appliquée entre-temps par un autre est sautée.
async func migrate(db, migrations):
    done := await applied(db)
    last := -1
    for m in migrations:
        if m["version"] <= last:
            raise("ORMError", "migrations : versions strictement croissantes attendues (" + str(m["version"]) + ")")
        last = m["version"]
    new := []
    for m in migrations:
        if m["version"] in done:
            continue
        stmts := []
        for s in m["statements"]:
            if isinstance(s, AddColumn):
                if await _has_column(db, s.table, s.column.name):
                    continue
                append(stmts, [s.create_sql(dialect(db)), []])
                continue
            append(stmts, [s.create_sql(dialect(db)) if isinstance(s, Table) or isinstance(s, Index) else s, []])
        append(stmts, ["INSERT INTO " + MIGRATIONS_TABLE + " (version, name, applied_at) VALUES (?, ?, ?)", [m["version"], m["name"], _time.time()]])
        try:
            await db.transaction(stmts)
        catch e:
            # plusieurs processus (ouvriers) migrent au démarrage : si un autre vient d'appliquer cette version,
            # notre transaction a échoué sur son enregistrement (ou sur ses tables) et a été annulée
            if await _applied_elsewhere(db, m["version"]):
                continue
            raise("ORMError", "migration " + str(m["version"]) + " (" + m["name"] + ") en échec : " + str(e.message))
        append(new, m["version"])
    return new

# Vrai si la version est enregistrée par un autre processus (relue quelques fois : sa transaction peut finir
# juste après la nôtre).
async func _applied_elsewhere(db, version):
    essais := 0
    while essais < 10:
        try:
            if version in (await applied(db)):
                return true
        catch e:
            ignored := e
        await _aio.sleep(0.1 * (essais + 1))
        essais += 1
    return false
