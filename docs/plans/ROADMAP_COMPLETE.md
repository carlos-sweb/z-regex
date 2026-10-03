# Roadmap completo de z-regex: lo que queda

## Punto de partida

| | |
|---|---|
| **Versión** | v0.8.0 en `main` (`edde4e1`). T0-A cerrado: DFA de ida e inverso, construido en compilación, con tope; en code unit y en code point. |
| **test262** | 3113 de 3136 (99,3 %), en UTF-16 y en WTF-8, desde el fix de la laxitud de `v` (antes 3087/3110; 2994/3017 en 0.8.0). 702 entradas saltadas: 509 del host (377 de ellas de los modificadores) y 193 por `regexp-v-flag` (`scripts/test262/features.json`); las 119 de `v` que pasan corren (`v-subset.json`). |
| **C ABI** | 40 símbolos. |
| **Binario** | ReleaseFast 1.214.560 B y ReleaseSmall 754.152 B (`measure_binary.sh`, x86_64_v3). |
| **Motores** | T0: VM de Pike y DFA, más los caminos rápidos (literal, class run, Shift-And, B). T1: Unicode (`u`/`v`) sobre T0 en modo code point. T2: backtracker con pila explícita, LookLinear y lookbehind hacia atrás. |

**Reglas de diseño** (no se discuten aquí):
- **Linealidad** en T0/T1.
- **Sin JIT de backtracking.**
- **ECMA-262 como referencia;** V8 como oráculo práctico.
- **El freeze** (desde v0.7.0): toda sintaxis válida no implementada es `UnsupportedFeature`. Una versión posterior solo quita casos de error, nunca añade.

**Leyenda.**

| Columna | Qué recoge |
|---|---|
| Destino | **nunca** (con razón), **1.0.0** (antes de cerrar 1.0, sin cambiar la API), **1.x** (aditivo bajo el freeze) o **fase propia** (proyecto con precheck propio) |
| Coste | Medido cuando hay cifra; si no, *est.* (estimación) |
| Riesgo | B (bajo), M (medio) o A (alto): de romper algo, o de que no salga |
| Impacto | **uso** (lo nota un consumidor real) o **compl.** (completitud o conformidad) |
| Dep. | De qué depende |

Sin priorizar hasta la última sección.

---

## 1. Features de ECMA-262 que faltan

| # | Qué es | Coste | Riesgo | Impacto | Dep. | Destino |
|---|---|---|---|---|---|---|
| 1.1 | **F5c, operandos de `v` (bug B):** carácter suelto o shorthand como operando derecho (`[\p{L}--a]`, `[\w--\d]`, `[a&&b]`) | *est.* 2-3 días | B | compl. (uso bajo: `v` es raro en npm) | — | 1.x |
| 1.2 | **F5c, encadenado:** `[A--B--C]`, `[A&&B&&C]` | *est.* 1-2 días (con 1.1) | B | compl. | 1.1 | 1.x |
| 1.3 | **F5c, unión con clases anidadas:** `[[a][b]]`, `[a[b]]` | *est.* 1-2 días | B | compl. | parser de `v` | 1.x |
| 1.4 | **F5c, `\q{…}`** (cadenas en clases: alternancia de secuencias, la más larga primero) | *est.* 1 semana | M (la clase deja de ser un conjunto de code points: lowering a alternancia) | compl. | 1.1-1.3 | 1.x |
| 1.5 | **F5c, propiedades de strings:** `\p{RGI_Emoji}` y 6 más (`Basic_Emoji`, `Emoji_Keycap_Sequence`, `RGI_Emoji_Flag_Sequence`, …): tablas de secuencias de emoji-sequences.txt y emoji-zwj-sequences.txt | *est.* 1-2 semanas (generador + tablas + lowering como 1.4) | M (tamaño: decenas de KB, *est.*) | compl. (uso: validación de emoji) | 1.4 | 1.x |
| 1.6 | **F5c, `v` con `i` completo:** MaybeSimpleCaseFolding en propiedades, clases negadas y operandos no cerrados (`/\p{Lu}/iv`, `/[^a-z]/iv`, `/[[a-z]--[q]]/iv`); quitar `non_ascii_fold` | *est.* 1-2 semanas | M (semántica de complemento tras el plegado, que V8 hace distinto de `iu`) | compl. | tablas de F5b | 1.x |
| 1.7 | **F5c, laxitud bajo `v`:** **hecho** tras la limpieza pre-1.0. Bajo `v`, un `( ) { } / \|` sin escapar, un doble reservado (`[a!!b]`, `[_^^]`) y un `-` que no es rango ni `--` (`[-a]`, `[a-]`, `[\d-]`) dan `InvalidClassSetOperand`, un nombre que ya existía; los 13 escapes de `ClassSetReservedPunctuator` (`\&`, `\!`, …) compilan. Las 26 de `breaking-change-from-u-to-v` pasan. En el corpus dejan de compilar 105 patrones `v`, todos SyntaxError en V8 | hecho | — | compl. | — | **hecho** |
| 1.8 | **`\p{ASCII}` + K bajo `iv`:** V8 no casa U+212A y nuestra lectura del spec sí. Hoy `UnsupportedFeature`, así que no se ve | *est.* investigación de 1 día | B | compl. | 1.6 | 1.x (con 1.6) |
| 1.9 | **Modificadores ES2025** `(?i:…)`, `(?-m:…)`, `(?i-s:…)`. Ya existe: `ModifierScope` en el HIR, flags por scope en T2, sitios de LookLinear con flags (F7, decisión 4). Falta: parser y early errors, flags por scope en el lowering de T0 (`i` por tramo: el plegado ya es por nodo; `m`/`s` cambian el assert y el `.`) | *est.* 1-2 semanas | M (el DFA ya no puede tener un solo `word_ci` global) | compl. (377 tests saltados como host; Node 22 no los tiene) | Node ≥ 23 para medirlos | **decisión del usuario: pendiente hasta nuevo aviso** |
| 1.10 | **Lookbehind hacia atrás bajo `u`/`v`** (variable, con capturas o backreferences): `/(?<=a+)b/u`. Átomos hacia atrás en modo code point: `decodeBefore` ya existe; falta el plegado `iu` hacia atrás y las clases de propiedades hacia atrás | *est.* 1-2 semanas | M | compl. (2 de test262: `named-groups/lookbehind.js`); uso: medio | arquitectura B de E1 | 1.x |
| 1.11 | **B6: lookaround dentro de un lookbehind hacia atrás:** `(?<=a(?=b)c+)`. Un lookahead dentro de un cuerpo hacia atrás corre hacia delante desde la posición actual, con barreras distintas | *est.* 1 semana | M | compl. (2 de test262: `nested-lookaround.js`; 844 patrones de `lbdiff-v8`) | E1 | 1.x |
| 1.12 | **`RegExp.escape`** (ES2025): **una función de la biblioteca estándar de ECMA-262** (`RegExp.escape(string)`), no sintaxis de patrones ni API del host. Falta en zregex. Sus 40 entradas de test262 se saltan como host porque prueban el built-in de V8, no el matcher. En zregex sería un helper aditivo `zregex.escape(allocator, text)` con el algoritmo del spec (EncodeForRegExpEscape), que un host JS puede usar para implementar el built-in | *est.* 0,5-1 día | B | compl. y uso (hosts JS y no JS) | — | **1.x** (aditivo) |
| 1.13 | **Full case mapping** (`ß` ~ `ss`, `ﬁ` ~ `fi`) | — | — | — | — | **nunca**: ECMA-262 usa el plegado simple (Canonicalize); el completo daría resultados distintos de V8 y del spec |
| 1.14 | **Turco** (`İ`/`ı` según locale) | — | — | — | — | **nunca**: ECMA-262 no depende de locale |
| 1.15 | **Divergencia V8 dentro de un par** bajo `u`/`v` (V8 reporta matches vacíos entre las dos mitades) | — | — | — | — | **nunca**: zregex sigue el spec (LIMITATIONS) |
| 1.16 | **`{n}` con n > 65.536** (D10): `PatternTooLarge` | — | — | — | — | **nunca** (límite documentado); V8 acepta cualquiera |
| 1.17 | **Propuesta TC39 «buffer boundaries»** `\A`, `\z`, `\Z`: hoy `\z` es `InvalidEscape`. Hacerlo válido quita un error, así que el freeze lo permite. Asserts nuevos de borde de texto en T0/DFA (contexto `edge`, que ya existe) | *est.* 2-3 días | B | compl. futura | **estado TC39 a verificar** (stage 2 hasta donde llega mi información) | fase propia cuando llegue a stage 3 |
| 1.18 | **Propuesta TC39 modo `x`** (extended: espacios y comentarios `#`) | *est.* 2-3 días (lexer) | B | uso (legibilidad) | estado a verificar (stage 1-2) | fase propia cuando avance |
| 1.19 | **Propuestas TC39 de átomos y posesivos** `(?>…)`, `*+`: los posesivos ya existen como extensión opt-in (`CompileOptions.possessive`); faltan los grupos atómicos | *est.* 2-3 días en T2; en T0 no hacen falta (sin backtracking) | B | uso (control de backtracking en T2) | estado a verificar (stage 1) | 1.x como extensión opt-in, o cuando avance |
| 1.20 | **Comentarios `(?#…)`** (propuesta TC39 / Annex B de otros motores) | *est.* 0,5 días | B | uso bajo | estado a verificar | con 1.18 |
| 1.21 | **Cualquier ES2026/ES2027 de RegExp ya en borrador:** hasta donde llega mi información (mediados de 2026), ninguna feature de sintaxis RegExp nueva está en stage 4 tras ES2025 (modificadores, nombres duplicados, `RegExp.escape`) | revisar el repo tc39/proposals | — | — | — | revisar en cada release |

---

## 2. Rendimiento

Cifras de `docs/BENCHMARKS.md` (v0.8.0, `execAt`, mejor de 10 rondas) salvo que se diga otra cosa.

| # | Qué es | Coste | Riesgo | Impacto | Dep. | Destino |
|---|---|---|---|---|---|---|
| 2.1 | **Fase 4 de T0-A: ReverseInner generalizado.** Buscar el literal interno obligatorio y lanzar el DFA inverso desde él (Rust lo hace). Hoy B salta al tramo anterior al literal, solo en code unit y con un literal ASCII | *est.* 1-2 semanas | M | uso: el e-mail ya empata con Rust (1,06×). *est.* +10-20 % en patrones con literal interno | DFA inverso | fase propia |
| 2.2 | **Construcción diferida del DFA** (lazy: estados bajo demanda en la ejecución, con caché en `Scratch`) **o interning más barato** (hash de claves `u32`, arena): npm p50 ~12,3 µs, p99 ~665 µs, máx. ~5,3 ms frente a 3,0 / 42 / 947 µs en 0.7.1 (T0-A-precheck §11-13). En la mediana, el interning es ~20 % y la memoria ~13 % del constructor | lazy: *est.* 2-3 semanas; interning: *est.* 2-4 días | lazy: A (caché por `Scratch` compartido entre `Regex`, invalidación, el tope en la ejecución); interning: B | uso: compilar muchos patrones (validadores, npm) | — | fase propia (lazy) / 1.x (interning) |
| 2.3 | **DFA para los programas sobre el tope** (lazy DFA con caché que se vacía, como Rust): hoy van a la VM. Unos pocos por corpus (npm: 23 por encima de 1.024 estados; `u`/`v`: 5) | con 2.2 lazy | A | uso bajo (cola) | 2.2 | fase propia (con 2.2) |
| 2.4 | **One-pass DFA para grupos** (Rust `onepass`): rellenar grupos sin el pase etiquetado cuando el patrón no es ambiguo. Es lo que queda por detrás de V8: `(\d{3})-(\d{4})` 3,7× disperso y 1,96× denso; `(?:(a)\|b)*c` 1,35×; título del libro 2,9× detrás de Rust | *est.* 2-3 semanas | M | uso: todo patrón con grupos | T0 | fase propia |
| 2.5 | **Coste fijo del VM etiquetado en entradas cortas:** 365-604 ns frente a 75-115 de V8 | *est.* 3-5 días (perfil + arreglos puntuales) | B | uso: validación de campos cortos con grupos | — | 1.x |
| 2.6 | **Saltos y prefiltros en modo code point:** hoy `u`/`v` no tienen `first`/`inner`/literal/class run/Shift-And (son de code unit). Un literal ASCII o una clase ASCII en un patrón `u` podría usarlos | *est.* 3-5 días | M (equivalencia con el modo code point, sustitutos) | uso: patrones `u` con literales | — | 1.x |
| 2.7 | **DFA por bytes UTF-8 para T1** (Rust compila las clases Unicode a autómatas de bytes): sin decodificar ni buscar en los cortes. Hoy `\p{Script=Greek}+` va 1,36× por detrás de Rust y `\p{Lu}` 1,40× | *est.* 3-4 semanas | A (dos alfabetos, UTF-16 aparte, tamaño de tablas) | uso: texto no latino | T0-A | fase propia |
| 2.8 | **Tabla de clases para el BMP bajo** (p. ej. 0x80-0x7FF en un array) en lugar de la búsqueda binaria sobre hasta 2.600 cortes | *est.* 2-3 días | B (memoria por DFA, *est.* ~4-8 KB) | uso: griego, cirílico, latín extendido | — | 1.x |
| 2.9 | **`\d{3}-\d{4}` disperso:** Shift-And recorre todos los bytes (1,67× detrás de V8 y 3,1× de Rust). Un prefiltro (memchr del `-`, o de un byte de la clase) antes de Shift-And | *est.* 2-3 días | B | uso: buscar teléfonos o fechas en texto | C | 1.x |
| 2.10 | **Literales frente a Rust:** 1,43-1,48× por detrás (`hello`, `Darcy`). memchr de byte raro (tabla de frecuencias) y ancho de vector elegido en ejecución | *est.* 1 semana | M (portabilidad, layout) | uso: búsqueda de literales | — | 1.x |
| 2.11 | **`[a-z]+` en entrada corta:** 0,89-0,94× de 0.7.1, +1,05 % de instrucciones (~3 por llamada: la comprobación del DFA en el despacho) | *est.* 1 día | B | uso bajo | — | 1.x |
| 2.12 | **D: despacho optimizado** (informe original de T0): descartado por riesgo de layout (T0-A.md) | *est.* 1 semana | A (layout) | bajo tras A | — | **nunca** salvo que un perfil lo pida |
| 2.13 | **JIT del DFA** (código nativo desde las tablas): no rompe la linealidad, porque un DFA compilado sigue siendo un DFA | *est.* 2-3 meses (x86_64 y aarch64, W^X, tamaño) | A (seguridad de memoria ejecutable, portabilidad, mantenimiento) | uso: ~2-3× en bucles de DFA (*est.*, por analogía con motores con JIT) | — | fase propia (no recomendada: el DFA ya empata o gana a V8 en T0 sin grupos) |
| 2.14 | **JIT de backtracking** | — | — | — | — | **nunca**: es la decisión de diseño (V8/PCRE2 JIT); sin linealidad y con superficie de ataque |
| 2.15 | **T2: prefiltro para lookbehind.** `(?<=\$)\d+` va 14× detrás de V8 y 61× de PCRE2 JIT: el cuerpo hacia atrás corre en todas las posiciones. Saltar a las posiciones tras un `$` (memchr) | *est.* 2-3 días | B | uso: lookbehind con literal | — | 1.x |
| 2.16 | **T2: LookLinear hacia atrás** (delegar cuerpos de lookbehind al VM hacia atrás; E1 lo dejó a 1.x) | *est.* 1-2 semanas | M | uso: lookbehind complejo | VM inverso | 1.x |
| 2.17 | **T2: backreferences** (`<(\w+)>.*?<\/\1>` 6,5× detrás de V8; `\b(\w+) \1\b` 14×): prefiltros de literal y memo por posición | *est.* 1-2 semanas | M | uso: HTML y duplicados | — | 1.x |
| 2.18 | **T2: presupuesto de pasos** (`max_steps` por posición de inicio, D11). Hay margen en pasos por segundo, no en la semántica | — | — | — | — | **nunca** cambiar la semántica (F7 ítem 8); rendimiento por pasos con 2.15-2.17 |
| 2.19 | **`findAll` asigna por match** (`[a-z]+` 186 → 56 MB/s; e-mail 759 → 506). Un bloque para todas las capturas o una arena interna, sin cambiar la API | *est.* 2-3 días | B (F7: una arena midió sin ganancia; mirar las páginas devueltas al SO) | uso: el método de conveniencia | — | 1.x |
| 2.20 | **Contadores grandes en la VM** (`{1000,5000}`): hoy van al backtracker | — | — | — | — | **nunca** (F7, decisión 2: 16 patrones de npm y la dedup por pc) |
| 2.21 | **Memoria de las tablas del DFA:** p50 572 B, p99 33 KB, máx. ~2 MB (npm). Un tope en bytes además del de estados y celdas, o tablas de 16 bits cuando caben | *est.* 2-3 días | B | uso: hosts con muchos patrones | — | 1.x |
| 2.22 | **Grupos en T1** (`u` con capturas): el DFA da los límites y la VM etiquetada rellena; medir y heredar 2.4 | con 2.4 | — | uso | 2.4 | con 2.4 |
| 2.23 | **`v` sobre el backtracker** (`[\p{L}--[a-z]] /v` 1,35× detrás de V8): llevar `v` al VM/DFA (las clases de `v` ya son conjuntos de code points salvo `\q`) | *est.* 3-5 días | M | uso: `v` | F5c parcial | 1.x |

---

## 3. Binario y tamaño

| # | Qué es | Coste | Riesgo | Impacto | Dep. | Destino |
|---|---|---|---|---|---|---|
| 3.1 | **Crecimiento:** +84.480 B ReleaseFast y +38.592 B ReleaseSmall desde 0.7.1 (DFA, asserts, code point, decodificación en línea). Sin acción: es el precio del DFA | — | — | — | — | informativo |
| 3.2 | **Instancias del ejecutor:** VM `search` × 3 saltos (`NoSkip`/`FirstSkip`/`InnerSkip`) × 2 unidades, y `dfaSearch` → `find` × 3 saltos × 2 unidades (`Dfa` y `Ctx`). Compartirlas con salto en tiempo de ejecución ahorraría *est.* 15-30 KB. En B costó layout (hasta 0,77× en C) y se eligió comptime | *est.* 2-3 días + bench | M (layout medido) | tamaño | — | 1.x (solo si un consumidor lo pide) |
| 3.3 | **Tablas de plegado a un módulo aparte** (+138 KB medidos en F5b: 69 KB de clases, 45 KB de deltas de propiedades) | *est.* 2-4 días | B | tamaño para quien no usa `i` con `u` | — | condicionado a un consumidor (F7 ítem 7) |
| 3.4 | **`zregex-t0`:** el módulo sin tablas Unicode; el básico ahorra ~90 KB (17-19 %), el completo 1-2 semanas (F7 decisión 3, ítem 12) | 1-2 semanas | M (dos builds que mantener) | tamaño, embebidos | 3.3 | condicionado a un consumidor |
| 3.5 | **Tablas Unicode comprimidas** (`src/unicode/tables.zig` ~330 KB de fuente): tablas de dos niveles o bitsets | *est.* 1 semana | M | tamaño | — | 1.x |
| 3.6 | **ReleaseSmall por defecto en la `.so`** o una variante `-Doptimize=ReleaseSmall` documentada | *est.* 0,5 días | B | tamaño | — | 1.x (documentación) |

---

## 4. API y C ABI

| # | Qué es | Coste | Riesgo | Impacto | Dep. | Destino |
|---|---|---|---|---|---|---|
| 4.1 | **Cabecera C** (`zregex.h`) generada o escrita a mano, con un test que la compile contra la `.so` (hoy no hay: cada consumidor declara las funciones desde `src/c_api.zig`, LIMITATIONS y API.md) | *est.* 1-2 días | B (aditivo: no cambia el ABI) | uso: consumidores C/FFI | — | **1.0.0** |
| 4.2 | **`docs/API.md` dice `version` = "0.7.1"** (no se actualizó en v0.8.0) | minutos | B | doc | — | **hecho** (limpieza pre-1.0: "0.8.0") |
| 4.3 | **Campos de diagnóstico de `CompileOptions`** (`force_tier`, `tier_diagnostic`, `t0_prefilters`, `t2_look_linear`): API.md ya los deja fuera del contrato. Decidir antes de 1.0 si se mueven a `internal` (un cambio de API) o se quedan documentados como inestables | decisión | B | API | — | **1.0.0** (decisión) |
| 4.4 | **Nombres de grupo para `execAt`/`iterator` y la C ABI:** hoy `getNamedCapture` es de `MatchResult` (la fachada). Un `groupIndex(name)` o `groupNames()` estable (a verificar qué expone la C ABI) | *est.* 1 día | B (aditivo) | uso: hosts JS (`groups` del resultado de `exec`) | — | 1.x |
| 4.5 | **`Subject` Latin-1** (cadenas de un byte de V8/JSC): un host JS como z-interpreter evita convertir a UTF-16. Es una variante más de `Unit` en T0 (bytes ≤ 0xFF sin decodificar) | *est.* 1 semana | M (una instancia más del ejecutor: tamaño) | uso: z-interpreter | consumidor | 1.x (si z-interpreter lo pide) |
| 4.6 | **Ejemplos del README** y `examples/` (se compilan con `zig build examples`): revisar que muestran `execAt`/`iterator`/`Scratch`, no solo la fachada | *est.* 0,5 días | B | doc | — | 1.0.0 |
| 4.7 | **Timeout por llamada** (además de `max_steps`): un presupuesto de tiempo o un callback de cancelación | *est.* 2-3 días | M (coste en el bucle caliente) | uso: hosts con entradas no confiables | — | 1.x (opcional) |
| 4.8 | **Serialización del bytecode** (compilar una vez y cargar) | — | — | — | — | **nunca** sin consumidor (F7 ítem 17) |
| 4.9 | **Telemetría de tiers para el host** | — | — | — | — | **nunca** sin consumidor (F7 ítem 18) |
| 4.10 | **`split`, reemplazo con callback, `matchAll` con grupos con nombre** en la fachada | *est.* 1-2 días cada uno | B (aditivos) | uso: consumidores Zig | — | 1.x (a demanda) |

---

## 5. Documentación

| # | Qué es | Coste | Riesgo | Impacto | Dep. | Destino |
|---|---|---|---|---|---|---|
| 5.1 | **`ARCHITECTURE.md` y `PROJECT_STRUCTURE.md` sin el DFA:** 0 apariciones de «DFA», sin `dfa.zig` ni `shiftand.zig`; el diagrama dice «Pike VM (plain or tagged)» | *est.* 0,5-1 día | B | doc | — | **hecho** (limpieza pre-1.0: DFA, Shift-And y `dfadiff` en ARCHITECTURE; `dfa.zig`, `shiftand.zig` en PROJECT_STRUCTURE) |
| 5.2 | **README, la línea de T0** («A Pike VM without captures and a tagged VM…»): falta el DFA | minutos | B | doc | — | **hecho** (limpieza pre-1.0) |
| 5.3 | **`BENCHMARKS.md` con titular primero** y razón de dos celdas (el brief citado en el encargo): hoy las tablas van antes que el análisis | *est.* 0,5-1 día | B | doc | — | **hecho** (limpieza pre-1.0: titular primero, método en medio, tablas al final) |
| 5.4 | **`docs/archive/README.es.md`:** archivado y desactualizado. Actualizarlo (traducción del README de 0.8.0) o decir en el archivo que no se mantiene | *est.* 0,5 días / minutos | B | doc | — | decisión |
| 5.5 | **`HISTORY.md`:** su cabecera ya llega a 0.8.0, pero el cuerpo acaba en F7c (0.7.1 y 0.8.0 viven en `plans/T0-*.md` y las release notes). Añadir un resumen por versión | *est.* 0,5 días | B | doc | — | **hecho** (limpieza pre-1.0: sección final con punteros a 0.7.0, 0.7.1, 0.8.0) |
| 5.6 | **`REGEX_TIERS_PLAN.md`:** 1 mención del DFA; revisar §6.1 (módulos `zregex-t0`/`t1`, corregido en F7c) y la descripción de T0 | *est.* 0,5 días | B | doc | — | **hecho** (limpieza pre-1.0: nota de documento histórico) |
| 5.7 | **Planes en español, docs públicas en inglés:** mantener la convención y decirla en CONTRIBUTING | minutos | B | doc | — | 1.0.0 |
| 5.8 | **`KNOWN_LIMITATIONS.md`** se mantiene solo como puntero (F7c-5): quitarlo cuando no lo cite nada en `src/` y `scripts/` | *est.* 0,5 días | B | limpieza | — | 1.x |

---

## 6. Testing y verificación

| # | Qué es | Coste | Riesgo | Impacto | Dep. | Destino |
|---|---|---|---|---|---|---|
| 6.1 | **test262: 4 de lookbehind** (`nested-lookaround.js` ×2 = B6; `named-groups/lookbehind.js` ×2 = hacia atrás bajo `u`) | con 1.10 y 1.11 | — | compl. | 1.10, 1.11 | 1.x |
| 6.2 | **test262: 4 fails del host** (`S7.8.5_A1.5_T1/T3`, `A2.5_T1/T3`: `\` + LineTerminator, que es error del lexer de JS; zregex coincide con V8) | — | — | — | — | **nunca**: son del host (F7 ítem 19) |
| 6.3 | **test262: 15 `unextracted`** (literales que el extractor del harness no saca: LineTerminator en el literal, flags con escapes unicode) | — | — | — | — | **nunca** para el motor; mejorar el extractor es opcional (*est.* 1 día) |
| 6.4 | **test262 con `v`:** **hecho** en la limpieza pre-1.0. De las 314 entradas con `regexp-v-flag`: 121 pasan (119 de la suite del motor, activadas en `scripts/test262/v-subset.json`, y 2 de la suite del host; 26 de ellas desde el fix de 1.7); 192 `UnsupportedFeature` (F5c); 1 del host. Ningún resultado incorrecto. Al cerrar F5c: volver a medir con `run.mjs --with-feature regexp-v-flag` y ampliar la lista | hecho | — | compl. | — | **hecho** |
| 6.5 | **test262: 377 de modificadores** saltadas como host (Node 22): medirlas con Node ≥ 23 aunque fallen | *est.* 0,5 días | B | información | Node | con 1.9 |
| 6.6 | **Diferencial `u`/`v` contra V8 en ejecución** (no solo compilación): `differential-v8` usa 4.000 patrones; añadir sujetos con astrales, sustitutos y LS/PS en modo `u` | *est.* 1-2 días | B | corrección del DFA en code point | — | 1.0.0 |
| 6.7 | **Diferencial propio del DFA en el repo:** **hecho** (`tools/dfadiff.zig`, en el gate). T0 tal como se enruta (caminos rápidos y DFA, code unit y code point) frente a la VM pura, todos los slots, en cada índice, con y sin `sticky`, en WTF-8 y UTF-16: 28.556 programas (21.301 DFAs en code unit y 4.349 en code point), 73,8 M de ejecuciones comparadas, 0 diferencias. Con dos mutaciones del DFA en una copia (decodificar en code unit; `\b` sin palabra extendida), da diferencias o falla | hecho | — | regresiones del DFA | — | **hecho** |
| 6.8 | **Fuzz:** hoy corre en los dos modos del gate. Añadir un fuzz diferencial DFA frente a VM con patrones generados (no solo de corpus) | *est.* 2-3 días | B | corrección | 6.7 | 1.x |
| 6.9 | **Corpus para F5c y modificadores** (`ivdiff` ya cubre `i`+`v` en compilación): patrones de `v` con operaciones y `\q` de los tests de V8 | *est.* 1 día | B | 1.1-1.9 | — | con F5c |
| 6.10 | **Casos límite sin test explícito:** DFA justo en el tope (1.024 estados / 32.768 celdas, con asserts y en code point); entradas > 4 GiB (índices `usize`, ids `u32` de las tablas); OOM en `execAt` con `Scratch` frío; patrones con 65.535 grupos en el DFA | *est.* 2-3 días | B | robustez | — | 1.0.0 |
| 6.11 | **Rendimiento en CI:** callgrind sobre un subconjunto fijo como guardia de regresiones (el bench de 10 rondas no es reproducible en CI compartido) | *est.* 2 días | B | regresiones | — | 1.x |

---

## 7. Deuda técnica anotada

Origen: búsqueda de «1.x», «deferred», «pending», «deuda», «nunca» en LIMITATIONS, README, `plans/*.md` y las release notes.

| # | Deuda | Origen | Coste | Destino |
|---|---|---|---|---|
| 7.1 | Construcción diferida del DFA / interning | `T0-A-precheck.md` §13-14, `RELEASE_NOTES_v0.8.0.md` | ver 2.2 | fase propia / 1.x |
| 7.2 | Fase 4 (ReverseInner) | `T0-A.md` §6, notas de 0.8.0 | ver 2.1 | fase propia |
| 7.3 | `[a-z]+` corto 0,89-0,94× | `T0-A-precheck.md` §11 | ver 2.11 | 1.x |
| 7.4 | F5c completo (bug B, encadenado, unión, `\q`, strings, `v`+`i`, `non_ascii_fold`) | `LIMITATIONS.md`, `F7.md` ítem 21, `ROADMAP_1.0.md` 1.1+ | ver 1.1-1.8 | 1.x |
| 7.5 | Lookbehind hacia atrás bajo `u`/`v` | `LIMITATIONS.md`, `ROADMAP_1.0.md` | ver 1.10 | 1.x |
| 7.6 | B6 (lookaround en un lookbehind hacia atrás) | `LIMITATIONS.md`, `E1.md`, notas de 0.6.0 | ver 1.11 | 1.x |
| 7.7 | LookLinear hacia atrás | `ROADMAP_1.0.md` (E1), notas de 0.6.0 | ver 2.16 | 1.x |
| 7.8 | Laxitud de sintaxis bajo `v` | `ROADMAP_1.0.md` | ver 1.7 (hecho) | hecho |
| 7.9 | Tablas de plegado a módulo aparte | `F7.md` ítem 7, `HISTORY.md` (F5b) | ver 3.3 | condicionado |
| 7.10 | `zregex-t0` | `F7.md` ítem 12 y decisión 3, `F7c.md` §6 | ver 3.4 | condicionado |
| 7.11 | Serialización, telemetría | `F7.md` ítems 17-18 | — | nunca sin consumidor |
| 7.12 | Modificadores | `F7.md` decisión 4, `ROADMAP_1.0.md` | ver 1.9 | pendiente de decisión |
| 7.13 | `\p{ASCII}` + K bajo `iv` | `LIMITATIONS.md` («`v` with `i`») | ver 1.8 | con F5c |
| 7.14 | Grupos: «acelerar el pase etiquetado sería otro proyecto» | `T0-A.md` §7 | ver 2.4 | fase propia |
| 7.15 | Producción de 1-3 meses antes de 1.0 | `ROADMAP_1.0.md` | calendario | 1.0.0 |

---

## 8. Fuera del plan

### 8.1 Decisiones sin cerrar

| Decisión | Estado | Qué la desbloquea |
|---|---|---|
| Modificadores ES2025 | «pendiente hasta nuevo aviso» (2026-09-29) | un consumidor, o Node del harness ≥ 23 para medirlos |
| ¿Corregir la laxitud bajo `v` (1.7) añadiendo errores? | **decidido:** sí, con un nombre existente (`InvalidClassSetOperand`); no se añaden nombres a RegexError | — |
| `zregex-t0` / tablas aparte | condicionado a un consumidor | un consumidor embebido |
| Campos de diagnóstico de `CompileOptions` | fuera del contrato, pero en la raíz | decidir antes de 1.0 (4.3) |
| Criterio de salida de la producción | «1-3 meses sin cambios de API» | definir qué consumidores cuentan (z-interpreter, …) y qué cifra |
| `Subject` Latin-1 | no planteado | z-interpreter |
| `README.es.md` | archivado | 5.4 |

### 8.2 Inconsistencias entre documentos

- ~~`docs/API.md`: `version` = "0.7.1" (4.2).~~ Corregido.
- ~~`ARCHITECTURE.md`, `PROJECT_STRUCTURE.md`: sin DFA ni Shift-And (5.1).~~ Corregido.
- ~~README: la línea de T0 sin DFA (5.2).~~ Corregido.
- ~~`ROADMAP_1.0.md`: la tabla de etapas acaba en F7c → producción; no recoge T0 (J+C+B, v0.7.1) ni T0-A (v0.8.0).~~ Corregido.
- Corregidos en la limpieza pre-1.0, además: `CONTRIBUTING.md` describía módulos que no existen (`src/core/`, `src/compiler/`, `src/executor/`, `src/bytecode/`); `src/unicode/README.md` citaba `src/bytecode/opcodes.zig`; `REGEX_TIERS_PLAN.md`, `ECMASCRIPT_COMPATIBILITY_PLAN.md` y `F6A_PRECHECK.md` citan rutas de su época y ahora lo dicen en una nota; el README trataba `RegExp.escape` como función del host.
- `bench/results.json`: dice que el harness es 0.7.1 (está anotado: compilado antes del cambio de versión).

### 8.3 Huecos de tests

Ver 6.6, 6.7 y 6.10. Además:
- el DFA no tiene un diferencial permanente en el gate: sus pruebas fuertes vivieron en el scratchpad;
- la C ABI tiene el harness de test262 como único consumidor de verdad; sin cabecera no se comprueba la ABI desde C.

### 8.4 Features de otros motores

| Feature | Motor | Veredicto |
|---|---|---|
| Conjuntos de patrones (multi-match de N regex en una pasada) | RE2 `Set`, Rust `RegexSet` | **posible, fase propia** (*est.* 3-4 semanas): un DFA producto con marcas por patrón. Uso: routers, filtros. Extensión de API aditiva |
| Match parcial (¿podría casar si llega más texto?) | PCRE2 `PARTIAL` | posible en T0/DFA (*est.* 1-2 semanas): el DFA sabe si el estado al final está vivo. Uso: streaming |
| Entrada por trozos (streaming) | Hyperscan, RE2 parcial | fase propia (*est.* 1-2 meses): T0/DFA sí; T2 no (backtracking sobre texto pasado) |
| `\X` (grapheme cluster), `\b{wb}` | PCRE2, ICU | **nunca** como sintaxis (no es ECMA-262; `\X` es SyntaxError bajo `u`); como API aparte, fuera del motor |
| Grupos atómicos `(?>…)` | PCRE2, .NET, Oniguruma | ver 1.19: extensión opt-in como `possessive` |
| Condicionales `(?(1)…\|…)`, recursión `(?R)` | PCRE2, .NET | **nunca**: fuera de ECMA-262 y sin linealidad |
| `\K` (reinicio del match) | PCRE2 | **nunca**: no es ECMA-262; el lookbehind lo cubre |
| Callouts | PCRE2 | **nunca**: código del usuario en el bucle de búsqueda |
| Balancing groups | .NET | **nunca**: no regular, no ECMA-262 |
| Timeout por llamada | .NET `MatchTimeout` | ver 4.7 |
| `split`, reemplazo con callback | todos | ver 4.10 |
| Literal byte-sets y SIMD Teddy para varios literales | Hyperscan, Rust | posible (*est.* 2-3 semanas): prefiltro para alternancias de literales (`foo\|bar\|baz`); hoy B y `first` cubren un literal |

---

## Qué haría yo

Estimaciones, no compromisos. Ordenadas por la relación entre lo que gana un consumidor real y el riesgo, dentro de las reglas del proyecto.

### Con 1 mes (cierre de 1.0)
1. **Inconsistencias y documentación de 1.0:** 4.2, 5.1, 5.2, 5.3, 5.6, 5.7. *est.* 3 días.
2. **Cabecera C con test** (4.1). *est.* 2 días.
3. **Medir lo que no se mide:** activar las 312 de `v` en test262 (6.4) y pasar el diferencial del DFA al gate (6.7). **Hecho** en la limpieza pre-1.0.
4. **Casos límite del DFA** (6.10) y diferencial `u`/`v` en ejecución contra V8 (6.6). *est.* 4 días.
5. **Decidir** los campos de diagnóstico (4.3). La laxitud de `v` (1.7): **hecho**.
6. **Interning más barato del DFA** (2.2, la parte barata), para bajar el coste de compilación de npm sin cambiar la arquitectura. *est.* 4 días.
7. **El resto del mes:** la producción con z-interpreter, arreglando lo que salga.

### Con 3 meses
Lo de 1 mes, más:
1. **F5c por partes,** en el orden 1.1 → 1.2 → 1.3 → 1.6 → 1.4 → 1.5. Lo barato primero: bug B, encadenado y unión, *est.* 1 semana; después `v`+`i`, `\q` y las propiedades de strings, *est.* 4 semanas.
2. **One-pass DFA para grupos** (2.4): el mayor hueco frente a V8 en T0. *est.* 3 semanas.
3. **Prefiltro de lookbehind** (2.15) y **prefiltro del Shift-And disperso** (2.9). *est.* 1 semana.
4. **v1.0.0** al final de la producción, si la API no cambió.

### Con 6 meses
Lo de 3 meses, más:
1. **Lookbehind hacia atrás bajo `u`/`v` y B6** (1.10, 1.11): test262 llegaría a 3117/3136 (los 19 restantes son del host o del extractor).
2. **Construcción diferida del DFA y DFA sobre el tope** (2.2 lazy y 2.3). *est.* 4 semanas.
3. **Fase 4 (ReverseInner)** (2.1) y **saltos en modo code point** (2.6).
4. **Conjuntos de patrones** (8.4) si un consumidor los pide; si no, **DFA por bytes para T1** (2.7).
5. **Modificadores** (1.9), si se levanta la decisión: la infraestructura ya existe.

No haría:
- **el JIT del DFA** (2.13), salvo un consumidor con requisitos de rendimiento extremos;
- **compartir las instancias del ejecutor** (3.2), sin un consumidor que pida tamaño.
