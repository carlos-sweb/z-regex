# Plan de F5 (T1, Unicode) por etapas

Plan, no implementación. Parte del análisis corregido de F0c
([F0C_ANALYSIS.md](F0C_ANALYSIS.md), [F0C_T1_BREAKDOWN.md](F0C_T1_BREAKDOWN.md)) y del
estado real del código, verificado en el Paso 0 (§1). Las estimaciones están marcadas como
tales y dicen en qué se apoyan.

## 1. Paso 0: estado real (verificado en el código)

| Pregunta | Estado | Dónde |
|---|---|---|
| ¿`CharSet` tiene las operaciones? | **Sí**: `unionWith`, `intersect`, `difference`, `complement`, `contains`, `fromRanges`, `borrowed` (vista sin copia de una tabla generada) | `src/ir/charset.zig` |
| ¿Tablas UCD? | **Sí, generadas** (`scripts/gen_unicode_tables.py`, Unicode 17.0.0 verificado en F0d): General_Category (todas las categorías y subcategorías; `\p{L}` = 684 rangos), 50 propiedades binarias + `ASCII`/`Any`, 174 scripts y Script_Extensions, mapeo simple de mayúsculas/minúsculas (`UnicodeData.txt`). **No** hay tablas de `CaseFolding.txt` ni de emoji-sequences | `src/unicode/{tables,properties,casefold}.zig` |
| ¿`\p` llega al HIR como `CharSet`? | **Sí**: `lowerProperty` / `classMembers` / `propertyTable` producen `char_set` con el `CharSet` de la tabla (prestado, sin copiar) | `src/frontend/lower/lower.zig:318–435` |
| ¿Operaciones de `v`? | **Parcial**: el parser acepta clases anidadas, `--` y `&&`, y el lowering las resuelve a un `CharSet` (`lowerClassSetOp`). **No** hay `\q{}` ni propiedades de strings en el parser | `parser.zig:782–800`, `lower.zig:335` |
| ¿Gramática `u` estricta? | **Sí** desde F1 (early errors, gramática `u` completa). Faltan dos cosas de datos: los alias cortos de propiedades binarias (`\p{Alpha}`, `\p{AHex}`…, 114 entradas / 57 patrones de test262 en `UnknownUnicodeProperty`) y `\p{General_Category=Other}` sin Cn (2 fallos) | `KNOWN_LIMITATIONS.md`, tabla de test262 |
| ¿Folding hoy? | **Parcial y no conforme**: bajo `i`, un literal no ASCII añade su pareja `toUpper`/`toLower` (no la órbita: `k` no incluye U+212A); rangos y propiedades no se pliegan; no se distingue Canonicalize sin `u` (toUppercase) de con `u` (simple case folding) | `lower.zig:395–400`, `KNOWN_LIMITATIONS.md` § Unicode Case Folding |
| ¿La VM de T0 ejecuta T1? | **El ejecutor ya puede; el enrutado no lo deja.** La VM decodifica según `mode` (`code_point` incluido) y `Set.contains` va a la tabla ASCII o a `CharSet.contains` (búsqueda binaria). El dispatcher manda a la VM solo `min_tier == .regular` (`src/compile.zig:191–195`). Los prefiltros se apagan en `code_point` (`pikevm.zig:203`). `tier0.check` rechaza `i` sobre literal no ASCII (`non_ascii_fold`) | `src/tier0/`, `src/compile.zig` |
| ¿test262 de `v`? | 275 entradas (`unicodeSets`, 47 + 228) aparecen como *skipped* en la última tabla. El Node del entorno sí acepta `/[a--b]/v`, así que la causa del skip **no está verificada**: es el primer paso de F5c | `scripts/test262/meta.mjs:104` |
| ¿Hoy dónde corre T1? | En el backtracker (T2), con estas mismas tablas y el mismo HIR | — |

**Consecuencia:** F5a es bastante menos trabajo del que su alcance sugiere. Las tablas y el
lowering existen; lo que falta es enrutar T1 a la VM, verificar el modo `code_point` y
arreglar dos defectos de datos.

## 2. Decisión: F5a primero (opción A)

Datos corregidos, ponderados y sin el paquete atípico: T0 91,7 %, T1 3,9 % (56 paquetes),
T2 4,4 % (75 paquetes).

**Opción A: F5a → F6a → F5b → F5c.** Razones:

1. **Coste frente a uso.** F5a cubre ~56–60 % de T1 (u sin más y `\p` sin `i`), ~2,2 % de
   las ocurrencias, con poco código nuevo (§1). F6a cubre un 4,4 % pero reescribe el
   backtracker con pila explícita. Por unidad de trabajo, F5a gana con claridad.
2. **Cobertura lineal.** Tras F5a, ~94 % de las ocurrencias (91,7 + ~2,2) corren en una VM
   lineal; con la opción B, el 91,7 % hasta que llegue F5a.
3. **F6a con menos superficie.** Lo que sale del backtracker en F5a (T1 sin folding) no
   tiene que reescribirse ni verificarse en F6a.
4. **No bloquea a T2.** F6a va justo después; T2 no espera a F5b/F5c.

Contra A: T2 está en más paquetes (75 frente a 56) y pesa algo más (4,4 % frente a 3,9 %).
Por eso F6a va **inmediatamente después** de F5a, y F5b/F5c detrás de F6a.

**La decisión es mía como recomendación; queda para que el usuario la confirme**, y se
registra en `REGEX_TIERS_PLAN.md` cuando se apruebe.

## 3. F5a: modo `u` y `\p` en la VM de T0

**Alcance.**
- Enrutar a la VM (F4a/F4b) los patrones T1 cuyas razones son solo `unicode_mode`,
  `property_escape` y, si el Paso 0 de F5c no lo impide, `unicode_sets_mode` /
  `class_set_operation` **sin `i`** (sus conjuntos ya son `CharSet`). Siguen en el
  backtracker: `ignore_case_unicode` (F5b), `\q{}`/strings (F5c), `large_counted_repeat`.
- El predicado de elegibilidad vive en `tier1` (puede importar `tier0`, nunca `tier2`); el
  dispatcher lo consulta cuando `min_tier == .unicode`.
- Alias cortos de propiedades binarias (datos de `PropertyValueAliases.txt`/`PropertyAliases.txt`
  en el generador) y `General_Category=Other` con Cn.
- Opcional, solo si el bench lo pide: prefiltros en `code_point` (hoy apagados).

**Archivos.** `src/tier1/root.zig` (+ `route.zig`), `src/compile.zig` (una rama del
dispatcher), `scripts/gen_unicode_tables.py` → `src/unicode/tables.zig` (regenerado),
`src/unicode/properties.zig` (alias), tests en `tests/`.

**API pública.** Ninguna firma cambia. `force_tier = .regular` sigue exigiendo T0; hace falta
decidir si `force_tier` acepta `.unicode` para forzar la VM en T1 (propuesta: sí, para el
diferencial y el bench).

**Tablas y `CharSet`.** Sin cambio: `CharSet.borrowed` sobre las tablas. `Program.Set.init`
clona el `CharSet` (`\p{L}`: 684 rangos × 8 B ≈ 5,5 KiB por `\p{L}` y compilación): se mide.

**Compilación (límite 2× de §7.2).** Riesgo: el clon de conjuntos grandes y el `Program`.
Se mide `\p{L}+`, `\p{Script=Greek}+`, `[\p{L}\p{N}_]+` contra `.expert`. Si pasa de 2×,
`Program.Set` pasa a tomar prestadas las tablas estáticas (sin clon).

**Binario.** Las tablas ya se enlazan hoy (las usa el backtracker): crecimiento esperado
~0 salvo los alias. Se mide en ReleaseFast y ReleaseSmall antes y después (la `.so` de
`zig-out` es Debug, 19,9 MB, y no sirve de referencia).

**Verificación y gate.**
- Diferencial interno VM (`code_point`) contra backtracker, todos los slots, en WTF-8 y
  UTF-16 (con surrogates sueltos y astrales): corpus de F2c, corpus npm de F0c, fuzz. 0
  discrepancias, o arbitradas con V8 como en F4b(2).
- test262 UTF-16 y WTF-8: sin regresiones; `property-escapes/generated` pasa de 766/882 a
  ~880/882 (los 114 de alias + los 2 de Cn). Aviso heredado: ese grupo ejecutará por
  primera vez el bucle por símbolo en ~114 entradas y puede tardar mucho más.
- `differential-v8` contra `diff-F4b.json`: sin divergencias nuevas.
- 0 asignaciones con Scratch caliente en los casos T1; `check-layers`.
- Bench: `t1_pL`, `t1_greek`, `t1_lu`, `t1_vset` (hoy 24–32 MB/s en el backtracker) no
  pueden empeorar; overhead de §7.2 (≤ 1,5× corto, ≤ 1,2× largo).

**Estimación.** 3–6 días de trabajo, en 3–4 commits (enrutado + diferencial, alias y Cn,
bench y cierre). *Base:* el ejecutor, las tablas y el lowering existen; el trabajo es de
enrutado y verificación, como F4a(3). Menos que las 1–2 semanas del prompt, que suponían
generar las tablas.

## 4. F5b: case folding

**Alcance.**
- Tablas desde `CaseFolding.txt` (estados C y S) y toUppercase simple para Canonicalize
  sin `u`; ambas como **órbitas** (clases de equivalencia: `k`/`K`/U+212A, `s`/`S`/U+017F,
  `σ`/`ς`/`Σ`), en formato de rangos con delta para no listar code point a code point.
- Folding en compilación: todo `char_set` y literal bajo `i` se reemplaza por su clausura
  (`CharSet` ∪ órbitas de sus miembros), con las reglas de Canonicalize del spec (sin `u`,
  no mapear no-ASCII a ASCII).
- `\w`, `\W`, `\b`, `\B` bajo `ui`/`vi` (U+017F y U+212A son word chars).
- Quitar `non_ascii_fold` de `tier0.check`; el folding deja de existir en ejecución.
- Retroreferencias bajo `i` (T2) usan la misma Canonicalize: se comparte la tabla.

**Archivos.** `scripts/gen_unicode_tables.py`, `src/unicode/casefold.zig` (órbitas),
`src/frontend/lower/lower.zig` (clausura), `src/tier0/compile.zig`, `src/tier1/`.

**API pública.** Sin cambios.

**Compilación.** Es el riesgo principal: la clausura sobre `\p{L}` (684 rangos) o
`[^a]` bajo `i`. Mitigación: clausura por rangos con la tabla de órbitas ordenada, y
cache por tabla estática (`\p{L}` plegado se calcula una vez). Gate: ≤ 2× `.expert` en los
casos de §3 bajo `i`, y un caso patológico (`[^\p{L}]` con `iu`) reportado aparte.

**Binario.** Crece por las tablas de órbitas (el tamaño de `CaseFolding.txt` C+S no se
midió aquí; en rangos con delta se espera pequeño). Se mide.

**Verificación.** Tests exhaustivos por fuerza bruta de Canonicalize con y sin `u` sobre
0..0x10FFFF contra una referencia (V8 vía Node, o la tabla leída directamente); el flag
`i` de test262 en verde; diferencial VM contra backtracker y contra V8 en el corpus; los
casos de `KNOWN_LIMITATIONS` § Unicode Case Folding pasan a ✅.

**Estimación.** 2–3 semanas (*base:* tablas nuevas, un algoritmo de clausura nuevo y una
verificación exhaustiva nueva; sin precedente directo en el repo).

## 5. F5c: `v` completo y `\q{}`

**Alcance.** Paso 0: averiguar por qué los 275 tests de `unicodeSets` se saltan. `\q{…}`
en el parser; propiedades de strings (`RGI_Emoji` y las demás de ECMA-262) con datos de
`emoji-sequences.txt` y `emoji-zwj-sequences.txt`; early errors restantes de `v`.

**Representación.** Una clase con strings no cabe en `CharSet`. Diseño (descripción de T1 en
`REGEX_TIERS_PLAN.md`): la clase se baja a `alt` de literales (los más largos primero) más un `char_set`
con los miembros de un code point. Es un cambio en el lowering, no en `CharSet`; las
operaciones `--`/`&&` con strings necesitan un tipo intermedio (conjunto de strings +
`CharSet`) solo durante el lowering.

**Verificación.** test262 `unicodeSets` (275 entradas) y `property-escapes` de strings;
diferencial contra V8.

**Estimación.** 3–5 semanas (*base:* cambio de representación y datos nuevos). Uso medido
en npm: cero; su justificación es la conformidad.

## 6. Contadores grandes: fuera de F5

16 regex del corpus con `n` o `m` > 100; 2 superan el presupuesto de desenrollado. Un
contador en la Pike VM rompe la dedup por pc. Se mantiene el desenrollado con
`PatternTooLarge`; se difiere a F7 o indefinidamente.

## 7. Gate de cierre de F5

| Chequeo | Esperado |
|---|---|
| `zig build test` Debug y ReleaseSafe, `check-layers` | pasa |
| test262 UTF-16 y WTF-8 | sin regresiones; `property-escapes`, flag `i` y `unicodeSets` en verde salvo lo documentado |
| `differential-v8` | sin divergencias nuevas contra la referencia vigente; las que desaparezcan, clasificadas; nueva referencia `diff-F5.json` |
| Diferencial interno VM contra backtracker (T1 enrutado, todos los slots, dos encodings) | 0 discrepancias |
| Canonicalize por fuerza bruta (con y sin `u`) | 0 diferencias |
| 0 asignaciones con Scratch caliente, 0 fallbacks de D5 | pasa |
| Bench (10 rondas intercaladas) | casos T1 no peores que en el backtracker; overhead y compilación dentro de §7.2 |
| Binario (ReleaseFast/ReleaseSmall) | medido y reportado |

## 8. Lo que no se pudo verificar aquí

- La causa del skip de `unicodeSets` en test262 (§5, Paso 0 de F5c).
- El coste real de compilar con clones de `\p{L}` y de la clausura de folding: se mide en
  F5a/F5b, no se estima.
- El tamaño del binario en release: la `.so` disponible es Debug.
