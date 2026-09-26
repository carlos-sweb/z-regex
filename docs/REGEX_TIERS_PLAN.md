# z-regex — Arquitectura por Tiers para ECMA-262 RegExp

> Documento de diseño y plan de implementación. No contiene código final: las firmas Zig son ilustrativas.
> Estado: propuesta. Fecha: 2026-09-25. Rama de origen: `claude/trusting-ride-po3bt8`.

---

## 0. Decisiones cerradas

| # | Decisión | Estado |
|---|---|---|
| DC1 | **Semántica objetivo: ECMA-262 2025 (16ª edición)**, incluyendo duplicate named groups, modificadores `(?ims-ims:…)`, flag `v` y `RegExp.escape` (este último, del host). | Cerrada |
| DC2 | **ECMA-262 estricto por defecto.** `{,5}` no es cuantificador: sin `u`/`v` (Annex B) es texto literal; con `u`/`v` es SyntaxError. Todo lo no-ECMA (posesivos, `{,n}`) solo como extensión opt-in, apagada por defecto. | Cerrada |
| DC3 | **Entrada abstracta WTF-8 + UTF-16**; los índices se expresan en unidades del `Subject`. | Cerrada |
| DC4 | **Unicode 17.0.0**, confirmado por regeneración byte a byte desde `unicode-org/unicodetools` (F0d): las tablas commiteadas salen idénticas de la UCD 17.0.0. La implementación (que `scripts/gen_unicode_tables.py` fije 17.0.0 en lugar de `latest`) se hace en F5; la decisión queda cerrada. | Cerrada (antes pregunta abierta P1) |
| DC5 | No se sabe con certeza qué cambios de RegExp trae ES2026; su adopción es **pregunta abierta P2**, no un supuesto. | Abierta |

---

## Contexto

`z-regex` (paquete Zig `zregex`, Zig 0.16) es un motor de regex tipo ECMAScript consumido por otros paquetes de un ecosistema de motor JS (los commits `85afd1f`, `f12de31` y `7d36074` mencionan `z-string` y `z-lexer`). Hoy tiene **un único ejecutor de backtracking recursivo** para todas las regex. El objetivo es reorganizarlo en **3 niveles de capacidad (Tiers)** con **una sola semántica** ECMA-262, detección automática del Tier mínimo y delegación de Tiers superiores a inferiores, de modo que los patrones simples corran por un camino lineal, barato y sin riesgo de ReDoS, y la complejidad y el riesgo queden aislados en el Tier superior.

El repo debe seguir siendo agnóstico al motor JS: no depende de APIs internas del motor y expone una interfaz limpia, reusable y testeable.

---

## 1. Resumen ejecutivo

1. **Los Tiers son de ejecución, no de sintaxis.** Hay un solo lexer/parser completo (toda la gramática ECMA-262 + Annex B + early errors) que siempre corre, así que los `SyntaxError` son idénticos en todos los Tiers. El Tier solo decide qué backend ejecuta un patrón ya validado.
2. **Tres Tiers, dos ejecutores:**
   - **T0 · Regular**: NFA con prioridades (Pike VM) de tiempo lineal, con capturas y sin tablas Unicode.
   - **T1 · Unicode**: el mismo ejecutor lineal de T0 más capas de datos (`u`/`v`, `\p{…}`, case folding completo, conjuntos, `\q{…}`). No tiene ejecutor propio.
   - **T2 · Experto**: backtracker con pila explícita en heap y presupuesto; delega en la VM de T0 los lookarounds sin capturas y usa sus prefiltros.
3. **Auto-consumo:** un clasificador estático (patrón + flags, nunca la entrada) calcula `min_tier`. La promoción es automática y determinista. Las dependencias van solo hacia abajo (T2→T1→T0) y el build lo hace cumplir.
4. **El veredicto de semántica es test262 real desde F0.** El diferencial entre Tiers es señal hasta que T2 esté reescrito (F6a/F6b), y veredicto después.
5. **Primero se mide, después se decide.** F0 entrega un prototipo de `analyze()` y mide la hipótesis 70/20/10 sobre corpus reales. El orden de F5 y F6 lo decide ese dato.
6. **Hay desviaciones reales del spec (D1–D12, §2.3)** que se corrigen en el parser/IR compartido (F1) antes de separar los Tiers.

---

## 2. Análisis del estado actual del repo

### 2.1 Estructura (verificada)

| Ruta | Rol | Notas |
|---|---|---|
| `build.zig`, `build.zig.zon` | Módulo público `zregex` (`src/main.zig`), shared lib FFI (`src/c_api.zig`), pasos `test`, `test-unit`, `test-integration`, `test-conformance`, `examples` | Sin dependencias. `build.zig.zon` todavía lista `include/` (ya no existe) y la descripción menciona "C/C++ bindings" (obsoleto). |
| `src/core/config.zig` | 2 flags comptime (`enable_execution_trace`, `panic_on_internal_error`) | Punto natural para feature flags comptime. |
| `src/parser/{lexer,parser,ast}.zig` | Lexer con modos (`unicode_mode`, `v_mode`, `in_char_class`), parser recursivo, AST de `Node` con `NodeType` (38 variantes) | `group_index: u8`; `MAX_ALTERNATION_DEPTH = 32` (`parser.zig:99`). |
| `src/codegen/{compiler,generator,optimizer}.zig` | AST → bytecode; `CompileOptions` (flags); optimizador | `optimizer.zig:55` es un `TODO`. `{n,m}` se desenrolla en codegen (`MAX_REPEAT_UNROLL = 1<<16`, `lexer.zig:532`); un `min` mayor se recorta. |
| `src/bytecode/*` | ~50 opcodes (`opcodes.zig:66-346`); clases con máximo 8 rangos (`MAX_CLASS_RANGES`, `opcodes.zig:18`) y 4 propiedades por clase | `LOOP` reservado y sin uso. |
| `src/executor/recursive_matcher.zig` | **Único ejecutor**: backtracking recursivo (`matchFrom` recursivo por instrucción), `max_steps`/`max_recursion_depth` | `MAX_CAPTURE_GROUPS = 16` (`:22`) frente a `thread.zig` `MAX_CAPTURES = 32` (inconsistente). Lookbehind con ventana de 100 (`:1375`). |
| `src/executor/matcher.zig` | `Matcher.find/findAt/findAll/matchFull` | `find` avanza byte a byte y crea un `RecursiveMatcher` por posición (`:131-168`); copia fija de 16 capturas por match (`:143`). |
| `src/regex.zig` | Fachada `Regex` (`compile`, `find`, `findAt`, `findAll`, `replace`, `replaceAll`, `expandReplacement`) + tests | No expone `ExecOptions`. `README.md:228-238` muestra `max_recursion_depth` en `CompileOptions`, pero ese campo no existe (`codegen/compiler.zig:47-94`). |
| `src/unicode/{tables,properties,casefold}.zig` | Tablas UCD generadas (~21k líneas): General_Category, 50 binarias, Script/Script_Extensions, case mapping simple | `docs/ARCHITECTURE.md` y `docs/PROJECT_STRUCTURE.md` todavía dicen "design only, not implemented" (desactualizado). |
| `src/utils/*` | bitset, dynbuf, pool, debug | Reutilizables en T0 (bitset de 256 para clases ASCII). |
| `tests/` | `integration_tests.zig`, `test262_conformance.zig` + `test262_data.zig` (168 casos extraídos heurísticamente) | El README dice 402 tests. |
| `scripts/` | `gen_unicode_tables.py`, `extract_test262.py`, `gen_test262_data.py` | Tooling de datos reutilizable (CaseFolding.txt, emoji-sequences). |
| `docs/` | `ECMASCRIPT_COMPATIBILITY_PLAN.md` (fases 0–8), `KNOWN_LIMITATIONS.md` (verificado por ejecución), `ARCHITECTURE.md`, `CONCEPTS.md`, `ROADMAP.md` | Antes de este documento no había diseño de Tiers ni de un motor lineal. |
| GitHub | 0 issues, 0 PRs (a la fecha de este documento) | Sin discusión previa registrada. |

### 2.2 Pipeline actual

```
pattern []u8 ─► Lexer(unicode_mode,v_mode) ─► Parser ─► AST(Node) ─► CodeGenerator ─► bytecode ─► Optimizer (no-op)
                                                                                              │
input []u8 (UTF-8/WTF-8) ─────────────────────────────────────────► Matcher.find ─► RecursiveMatcher (backtracking recursivo)
```

Qué se reutiliza: lexer, parser y AST (con correcciones); tablas y resolución Unicode (`properties.zig`); `casefold.zig`; decodificación WTF-8 (`utf8SeqLenAt`/`decodeCodepointAt` en `recursive_matcher.zig`, commit `7d36074`); `expandReplacement`; bitsets; harness test262.

### 2.3 Desviaciones de ECMA-262 (verificadas en el código)

| # | Desviación | Evidencia | Qué dice el spec | Dónde se corrige |
|---|---|---|---|---|
| D1 | `{,5}` se acepta como `{0,5}` | `lexer.zig` `parseRepeat` | Annex B: `{` es literal si no forma `{n}`/`{n,}`/`{n,m}`; con `u`/`v` es SyntaxError | Parser (F1) |
| D2 | `a{` y `}` sueltos dan `error.InvalidRepeat` | `parseRepeat` | Annex B: `ExtendedPatternCharacter` literal | Parser (F1) |
| D3 | `[]` se rechaza (`error.EmptyCharClass`) | `parser.zig:863` | `/[]/` es válido y nunca matchea | Parser + CharSet vacío (F1) |
| D4 | `\s` solo ASCII `[\t-\r ]` | `parser.zig:38` | WhiteSpace + LineTerminator (U+00A0, U+FEFF, Zs, U+2028/9) incluso sin `u` | Mini-tabla fija en T0 (F1) |
| D5 | `^`/`$` con `m` y `.` solo consideran `\n` | `recursive_matcher.zig:523-541`, `:616-625` | LineTerminator = `\n`, `\r`, U+2028, U+2029 | T0 (F1) |
| D6 | Sin `u` se decodifican code points (`.` consume 😀 entero) | doc de `CompileOptions.unicode` (`compiler.zig:61-73`), `matchAnyChar` | Sin `u` se opera sobre code units UTF-16; `/^.$/.test("😀")` es `false` | Subject (F3) |
| D7 | Lookbehind con ventana de 100 bytes, probando longitudes hacia adelante | `recursive_matcher.zig:1375-1384` | Matching hacia atrás (direction −1), sin límite, capturas de derecha a izquierda | T2 (F6b) |
| D8 | Posesivos `*+ ++ ?+` activos por defecto | `lexer.zig:49-51` | `/a*+/` es SyntaxError | Extensión opt-in (F1) |
| D9 | Máximo 16 capturas, backrefs `\1`–`\9`, `group_index: u8` | `recursive_matcher.zig:22`, `lexer.zig:34`, `ast.zig` | Sin límite práctico; `\10`+ válido si hay ≥ 10 grupos (si no, Annex B octal/identity) | Parser y slots dinámicos (F1) |
| D10 | Un `{n}` con n > 65536 se recorta en silencio | `lexer.zig:517-532` | Conteo exacto | `PatternTooLarge` explícito o contadores (F5) |
| D11 | Los límites contra ReDoS no se pueden configurar vía `Regex` | `regex.zig` no usa `ExecOptions`; `README.md:228-238` desactualizado | — | API pública (F6a) |
| D12 | `find` avanza de a 1 byte y puede arrancar a mitad de una secuencia UTF-8 | `matcher.zig:162-168` | `lastIndex` avanza por code unit (o code point con `u`) | Subject (F3). **Inferido del código, no verificado ejecutándolo.** **Parcialmente corregida en F1a:** `find`, `findAll` y `zregex_search_n` avanzan por secuencia UTF-8/WTF-8 completa (`RecursiveMatcher.nextSearchStart`), porque 2 de los 5 tests de D13 fallaban solo por esto; `lastIndex` por code unit UTF-16 sigue en F3. |
| D13 | Con `u`, un par surrogate escrito con escapes (`\ud834\udf06`) no se combina en un solo code point: cada `\uXXXX` queda como un surrogate suelto | test262 `built-ins/RegExp/prototype/source/value-u.js` (F0b) | Con `u`, `\uLead\uTrail` forma un solo code point (RegExpUnicodeEscapeSequence) | Parser, gramática `u` (F1) |
| D14 | El matcher recursivo acota la **profundidad** de recursión (1000), no los **bytes** de pila nativa: su corrección depende de la pila que le dé el llamador. Medido en F0d: con 1 MiB de pila, los adversariales `(a+)+b`/`(a\|aa)*c` sobre 41 bytes hacen segfault; con 8 MiB devuelven `StepLimitExceeded` en 44–48 ms (bench, ReleaseFast). **La pila del llamador es el límite entre responder y crashear.** | test262 (F0b): `S15.10.2.8_A3_T17/T32/T33`, `S15.10.6.2_A12`, `S15.10.6.2_A1_T6` crashean con 1 MiB y pasan con 8 MiB | Una regex no debería crashear según la pila del host | T2: pila explícita en heap con límite de bytes (F6a) |
| D15 | El contador de recursión (`max_recursion_depth = 1000`) **protege contra la profundidad, no contra los bytes de pila**, y está calibrado para una pila que ningún llamador tiene. En la cadena `matchFrom` → `matchBackRef` → `matchFrom` cada nivel cuesta **≈ 25,3 KiB en ReleaseSafe y ≈ 75,5 KiB en Debug** (medido en F0d con la pila mínima para `()\1{N}`, N = 100/200/400: crecimiento exactamente lineal), así que llegar al límite de 1000 exige **≈ 25 MiB (≈ 75 MiB en Debug)**. Con 8 MiB el crash llega antes que el límite, desde ~320 repeticiones (~105 en Debug). El contador sí cubre la ruta: con 64 MiB, `()\1{1000}` devuelve `RecursionLimitExceeded` con profundidad máxima 1000 en ReleaseSafe (Debug necesita > 64 MiB). A diferencia de D14 (el resultado depende de la pila del llamador), aquí **ninguna pila por defecto** (8 MiB en el hilo principal, menos en hilos) alcanza el límite: la protección nominal no protege nada. | Fuzz del parser (F0d), reducido desde `\2{9007199254740991}\[*`; test `skip` en `tests/regression_tests.zig` | Un límite de recursión que nunca se alcanza antes del crash no es un límite | T2: pila explícita en heap con límite de bytes (F6a) |
| D16 | El contador de grupos capturantes del parser es `u8` (`group_counter += 1`, `parser.zig:529`): **256 grupos capturantes secuenciales** (`(a)(a)…`) hacen panic por desbordamiento de entero en ReleaseSafe/Debug, y en ReleaseFast **desbordan en silencio a 0**, de modo que el grupo 256 escribe la captura 0 (el match completo). No lo frena el límite de anidamiento (los grupos no están anidados), y el fuzz no llega (patrones de ≤ 16 tokens). Es un bug de seguridad del código actual, medido en el Paso 0 de F1 | Paso 0 de F1: `(a)`×255 compila; ×256 y ×300, panic (ReleaseSafe) o compila con el índice desbordado (ReleaseFast) | El índice de captura no puede desbordar; un patrón válido con muchos grupos no puede crashear ni corromper el grupo 0 | F1c(a): índices u16 y `error.TooManyCaptures` explícito, con un test de regresión de 256 grupos y el alfabeto del fuzz ampliado con construcciones de muchos grupos; bloquea D9(b) |

También falta: modificadores `(?i:…)`; `v` con más de una operación por clase; `\q{}`; propiedades de strings; case folding de rangos no-ASCII (`KNOWN_LIMITATIONS.md`, "Genuinely unimplemented"). Los duplicate named groups ya están soportados.

---

## 3. Características ECMA-262 y su Tier

**Regla de asignación:** el Tier de una feature es el modelo de ejecución mínimo que la implementa correctamente, no su popularidad.
- **T0**: lenguaje regular sin datos Unicode (code units, case-insensitive solo ASCII).
- **T1**: lenguaje regular con datos Unicode, conjuntos grandes o contadores.
- **T2**: no regular, o dependiente de capturas o de aserciones con capturas (backrefs, lookaround).

El parser siempre soporta todo. La columna "Tier" es el backend mínimo requerido. La dificultad (1–10) mide el esfuerzo y el riesgo de implementarlo bien en esta arquitectura, partiendo del repo actual.

### 3.1 Tier 0 — Regular

| Característica | Sintaxis / ejemplo | Tier | Dif. | Por qué esa dificultad | Dependencias | Riesgos | Tests |
|---|---|---|---|---|---|---|---|
| Literales y escapes de sintaxis | `abc`, `\.` | 0 | 1 | Ya existe; comparación directa. | Parser | — | unit |
| Escapes de control/caracter | `\t`, `\cJ`, `\0`, `\x41`, `A` | 0 | 2 | Ya existe (Phase 0); faltan casos Annex B de `\c`. | Parser | `\c` inválido → literal `\c` | unit, test262 |
| Léxico Annex B | `\07`, `\8`, `{`, `}`, `]` literales, identity escapes | 0 | 4 | La ambigüedad octal/backref depende del número total de grupos, así que el parser necesita 2 pasadas. | Parser | Compatibilidad web | test262 `annexB` |
| `.` y flag `s` | `a.c`, `/a.c/s` | 0 | 2 | Solo falta el conjunto correcto de terminadores de línea. | Subject | D5, D6 | unit por encoding |
| Clases, rangos, negación | `[abc]`, `[^a-z]`, `[^]`, `[]` | 0 | 3 | CharSet dinámico sin el límite de 8 rangos; `[z-a]` es SyntaxError; `[\d-a]` es Annex B. | CharSet | D3 | unit, property (set ops vs fuerza bruta) |
| `\d \D \w \W \s \S` | | 0 | 2 | `\s` necesita una mini-tabla Unicode fija, no la UCD. | CharSet | D4 | unit |
| Anclas `^ $`, flag `m` | | 0 | 2 | Terminadores completos. | Subject | D5 | unit |
| `\b \B` | | 0 | 2 | Existe; con `u`+`i` cambia el conjunto de caracteres de palabra (→T1). | IsWordChar | — | unit |
| Alternancia | `a\|b\|` | 0 | 2 | Prioridad izquierda→derecha, que se expresa como el orden de `Split`. | IR | Prioridad | diferencial |
| Grupos no capturantes | `(?:ab)` | 0 | 2 | Solo agrupan, sin estado. | IR | — | unit |
| **Grupos capturantes en la Pike VM** | `(a)(b)?` | 0 | **9** | Reproducir el leftmost-first del backtracking con capturas exige un tagged NFA: slots por hilo, lista de hilos ordenada por prioridad, y dedup por `pc` que conserve el hilo de mayor prioridad. Un error en el orden de inserción cambia las capturas sin cambiar el match. | Slots copy-on-write, sparse set | Capturas incorrectas aunque el match sea correcto (bug silencioso) | diferencial + test262 |
| **Cuantificadores greedy/lazy** | `* + ? {n,m}`, `*?` | 0 | **8** | Greedy/lazy es el orden de ramas de `Split`, pero combinado con desenrollado, cuerpos que pueden matchear vacío y capturas anidadas, el orden de prioridad se rompe con facilidad. El repo ya tuvo 3 bugs de este tipo (`KNOWN_LIMITATIONS.md`, Phase 6). | Grupos capturantes | Orden de prioridad | diferencial masivo, fuzz |
| **Regla de iteración vacía** | `(a*)*`, `(?:)*` | 0 | **7** | RepeatMatcher: si ya se alcanzó `min` y la iteración no avanzó, esa iteración falla. En la VM hay que guardar la posición de entrada al bucle por hilo, y el dedup solo por `pc` deja de ser correcto (dos hilos en el mismo `pc` con distinta posición de entrada tienen futuros distintos): hay que ampliar la clave de dedup o reescribir el IR. Existe literatura sobre JS lineal (Barrière & Pit-Claudel, PLDI 2024); **está por verificar qué técnica aplica aquí**. | Cuantificadores | Divergencias con V8 en patrones anulables; el repo ya tuvo un stack overflow por esto (`ce885bf`) | test262 (casos anulables) + fuzz dirigido |
| **Reset de capturas en cada iteración** | `/(?:(a)\|b)+/` sobre `"ab"` → `$1 = undefined` | 0 | **8** | RepeatMatcher, paso 4: limpiar las capturas internas al inicio de cada iteración. En la VM es `ClearSlots(rango)` por hilo, O(k) por iteración con copy-on-write. Deduplicar ignorando las capturas solo es correcto porque T0 no tiene backrefs; por eso las backrefs van a T2. | Grupos capturantes, cuantificadores | Capturas de una iteración anterior que quedan pegadas (bug ya visto en el repo, Phase 6) | test262 + diferencial |
| Grupos con nombre (+ duplicados ES2025) | `(?<y>\d{4})`, `(?<x>a)\|(?<x>b)` | 0 | 3 | Son metadatos; ya existen. | Tabla de nombres | Nombres con escapes `\u` | unit |
| `i` sin `u`, contenido ASCII | `/abc/i`, `/[a-z]/i` | 0 | 3 | Por la regla del spec, un caracter ≥ 128 nunca canonicaliza a < 128, así que con un patrón ASCII no hacen falta tablas. | Canonicalize ASCII | — | unit, diferencial |
| Modificadores (ES2025) | `(?i:a)`, `(?-m:^)` | 0* | 5 | Parser, early errors (`(?ii:)`, `(?-:)`) y Canonicalize por nodo. *Es T0 si el contenido cumple las reglas de T0; si no, T1. | Parser | Early errors | unit, test262 |
| Flags `g`, `y`, `d` | `lastIndex`, sticky, `indices` | 0 | 2 | La semántica de `lastIndex` es del host; la lib ofrece `execAt(index)` + `advanceIndex()`. | API | AdvanceStringIndex con `u` | unit |
| Prefiltros / fast paths | literal puro, prefijo literal, conjunto del primer caracter, patrón anclado | 0 | 4 | Es optimización, no feature; también la usan T1 y T2. | Análisis del IR | Corrección con `i`/`m`/`y` | diferencial, bench |

### 3.2 Tier 1 — Unicode

| Característica | Sintaxis / ejemplo | Tier | Dif. | Por qué esa dificultad | Dependencias | Riesgos | Tests |
|---|---|---|---|---|---|---|---|
| Modo `u` | `/😀/u`, `\u{1F600}`, `😀` como par | 1 | 5 | Decodificar pares surrogate para dos tipos de Subject (WTF-8 y UTF-16); los surrogates sueltos son code points válidos; `lastIndex` puede caer en medio de un par. La gramática estricta es del parser (F1). | Subject, parser | Surrogates sueltos, índices | unit por encoding, test262 |
| Propiedades Unicode | `\p{L}`, `\P{Script=Greek}`, `\p{scx=Latn}` | 1 | 4 | Tablas, resolución y alias ya existen y pasan los tests (`properties.zig`). Queda migrar a CharSet dinámico (quitar el límite de 4 por clase) y fijar la versión (DC4). No hay algoritmo nuevo. | `unicode/`, CharSet | Versión de UCD sin fijar | test262 `property-escapes/generated` |
| `i` con `u`/`v` (simple case folding) | `/K/iu` matchea `k` | 1 | 6 | Tablas nuevas (CaseFolding.txt, estados C+S) y clases de equivalencia (k/K/K). `\w` y `\b` cambian bajo `ui`. | CharSet, generador | Clausura incompleta | fuerza bruta 0..0x10FFFF |
| `i` sin `u` con contenido no-ASCII | `/é/i` | 1 | 6 | Canonicalize con `toUppercase` simple más las excepciones del spec (se ignoran mapeos multi-caracter y un caracter ≥ 128 nunca pasa a < 128). Reglas distintas a las de `u`, camino de código propio. | casefold | Confundirlo con el folding de `u` | fuerza bruta |
| Case folding de clases, rangos y propiedades | `/[\p{Lu}]/iu`, `/[À-Ö]/i` | 1 | 7 | La clausura por code point sobre conjuntos grandes (`\p{L}` tiene ~140k code points) es cara en compilación: hacen falta tablas de folding por rangos y un algoritmo sobre rangos. | CharSet + tablas de fold | Tiempo de compilación, corrección | fuerza bruta vs rangos |
| `v`: operaciones de conjuntos anidadas | `[\p{L}--[a-z]]`, `[[a-z]&&[^x]]` | 1 | 6 | Con CharSet dinámico, el álgebra de rangos es trivial. Lo difícil es la gramática `v` (no mezclar operadores en un mismo nivel, puntuadores dobles reservados, early errors). El repo ya tuvo 4 bugs de parser con una sola operación (Phase 5c). | Parser, CharSet | Bugs de modo del lexer | test262 `unicodeSets` |
| `v`: `\q{…}` y propiedades de strings | `[\q{abc\|d}]`, `\p{RGI_Emoji}` | 1 | 8 | Las clases pasan a contener strings: álgebra de conjuntos mixtos, alternancia con las strings más largas primero, folding por string con `i`, prohibición de complemento si la clase puede contener strings, y datos nuevos (emoji-sequences). | CharSet mixto, generador | Orden de alternativas, datos | test262 `unicodeSets`, `property-escapes` |
| Repeticiones contadas grandes (contadores en la VM) | `a{1000,5000}` | 1 | 7 — **revisar con datos de F0c** | Un contador rompe el modelo "estado = pc" de la Pike VM: el dedup tiene que incluir el valor del contador y los estados se multiplican. **No se sabe si hace falta**: depende de la frecuencia real de `{n}` grandes. Con desenrollado hasta un presupuesto + `PatternTooLarge`, la dificultad baja a ~3. | VM de T0 | Pérdida de linealidad | bench, fuzz |

### 3.3 Tier 2 — Experto

| Característica | Sintaxis / ejemplo | Tier | Dif. | Por qué esa dificultad | Dependencias | Riesgos | Tests |
|---|---|---|---|---|---|---|---|
| Backreferences numéricas | `(a)\1`, `\10` | 2 | 6 | Con el trail (§4.4) el opcode es una comparación de substrings; lo difícil es Annex B (`\10` es backref u octal según el número de grupos) y las referencias adelantadas o a grupos que no participaron (matchean vacío). **No sube a 7 por "hacer público el presupuesto y testearlo":** el presupuesto es un mecanismo común a todo T2 (F6a), que se aplica igual a lookarounds y cuantificadores ambiguos; sumarlo aquí lo contaría dos veces. | Slots dinámicos, parser de 2 pasadas | ReDoS (lo acota el presupuesto) | test262, diferencial contra V8 |
| Backrefs con nombre (+ duplicados) | `\k<x>` con `(?<x>a)\|(?<x>b)` | 2 | 5 | Como mucho participa uno de los duplicados (están en ramas excluyentes); basta con elegir el slot válido en ejecución. La tabla de nombres ya existe. | Tabla de nombres | Elegir mal el slot | test262 `named-groups` |
| Backrefs con `i` | `/(a)\1/i` | 2 | 6 | Sin `u` se comparan code units canonicalizadas, y sobre un Subject WTF-8 eso exige transcodificar a unidades UTF-16; con `u`, code points. Dos caminos por encoding. | Canonicalize, Subject | Sutilezas entre encodings | fuerza bruta por pares |
| Lookahead | `(?=x)`, `(?!x)` | 2 | 7 | Es atómico (corta choicepoints), conserva capturas solo en positivo exitoso, necesita la decisión de delegación y la corrección de la memo. El repo ya tuvo una fuga de capturas en el negativo (Phase 6). | Trail, VM de T0 | Fuga de capturas | test262, diferencial |
| Lookbehind | `(?<=\$)\d+`, `(?<!a)b` | 2 | 10 | Es la única feature que duplica la superficie de instrucciones: cada instrucción que consume (caracter, `RunSet`, backref) necesita versión hacia atrás, para 2 encodings y con decodificación `u`/no-`u`; un lookahead dentro de un lookbehind (y al revés) cambia de dirección; la delegación exige programas lineales invertidos. Hoy no hay nada reutilizable (D7). | Trail, IR invertido, VM | Dirección mal propagada, surrogates hacia atrás | test262 `lookBehind`, diferencial contra V8 |
| Asserts cuantificados (Annex B) | `/(?=a)*/` sin `u` | 2 | 5 | No introduce mecanismo nuevo: es la regla de iteración vacía aplicada a algo que no consume. Solo es raro. | Parser Annex B | Semántica rara | test262 `annexB` |
| Capturas de lookaround usadas por backrefs | `/(?=(a+))a*b\1/` | 2 | 8 | Sin mecanismo nuevo, pero es donde se cruzan trail, atomicidad y backrefs; ahí se concentraron los bugs históricos (Phase 6). La dificultad está en validarlo. | Todo lo anterior | Bugs de rollback | diferencial + fuzz dirigido |

### 3.4 Excluido o no soportado

| Elemento | Decisión | Motivo |
|---|---|---|
| `{,n}` como `{0,n}` | Eliminado del modo por defecto; como mucho, extensión opt-in (`Extensions.min_omitted_repeat`). | DC2, D1. |
| Posesivos `*+ ++ ?+`, grupos atómicos, condicionales `(?(c)…)`, recursión `(?R)` | Fuera del núcleo; los posesivos solo como extensión opt-in (T2). | No son ECMA-262 (D8). El README los lista como "Future"; se recomienda no hacerlos. |
| Flag `x` y comentarios | No. | Es una propuesta, no ECMA-262 publicado. |
| Normalización Unicode, folding por locale, full case folding multi-caracter | No. | El spec usa simple case folding. |
| JIT | No, por ahora. | Fuera del alcance de seguridad y claridad. |
| **Del host (no se implementa en z-regex):** objeto `RegExp`, `lastIndex` como propiedad, `Symbol.match`, `Symbol.replace`, `Symbol.split`, **`Symbol.matchAll` / `String.prototype.matchAll` y su iterador `RegExpStringIterator`**, species, `RegExp.$1` legacy, getters `flags`/`source` | La lib ofrece solo primitivas puras: `execAt`, `advanceIndex`, `expandReplacement` (GetSubstitution), `escapePatternSource` (EscapeRegExpPattern) y `RegExp.escape` puro. **`matchAll` se construye en el host con un bucle de `execAt` + `advanceIndex`; no debe implementarse dentro de la lib.** | Agnosticismo respecto al motor. |

---

## 4. Interfaces entre Tiers

### 4.1 Artefactos compartidos (una sola fuente de verdad)

```
Syntax     : Lexer + Parser + EarlyErrors  →  AST (toda la gramática, Annex B incluida)
Analysis   : FeatureSet + min_tier + GroupInfo + CostEstimate  (paso puro sobre el AST/HIR)
IR (HIR)   : Empty, CharSet, Seq, Alt, Repeat{min,max,greedy}, Capture{idx}, Assert{kind},
             BackRef{idx|name}, Look{dir, neg, body}
             + atributos por nodo: tier, has_captures, nullable, min/max_len
CharSet    : conjunto de rangos u32 inmutable + álgebra (∪ ∩ − complemento) + clausura de fold
Canonicalize(ch, flags) : ASCII (T0) | toUppercase no-u / simple fold u (T1)
Subject    : abstracción de entrada (unidad = u8 WTF-8 | u16), decodificación según u/no-u
```

- **T0** compila HIR → `Program` lineal (`Char`, `Set`, `Split(prio)`, `Jmp`, `Save`, `ClearSlots`, `Assert`, `Match`, `EmptyCheck`).
- **T1** no tiene ejecutor: aporta CharSets grandes (desde `unicode/`), Canonicalize Unicode, expansión de `\q{}` y de propiedades de strings a `Alt`, y contadores. Produce el mismo `Program`, que ejecuta la VM de T0 decodificando code points según el `Subject`.
- **T2** compila HIR → `T2Program` (§4.4). Comparte funciones de caracter y de conjunto con T0/T1, no sus intérpretes.

### 4.2 API pública (firmas ilustrativas)

```zig
pub const Flags = packed struct { d: bool, g: bool, i: bool, m: bool, s: bool, u: bool, v: bool, y: bool };
pub const Tier  = enum(u2) { regular = 0, unicode = 1, expert = 2 };

pub const Source  = union(enum) { utf8: []const u8, utf16: []const u16 };   // texto del patrón
pub const Subject = union(enum) { wtf8: []const u8, utf16: []const u16 };   // entrada; índices en SUS unidades

pub const CompileOptions = struct {
    max_tier: Tier = .expert,          // techo; para patrones no confiables el host puede usar .unicode
    force_tier: ?Tier = null,          // SOLO tests/diagnóstico; debe ser >= min_tier
    extensions: Extensions = .{},      // posesivos, {,n}…; todo false por defecto
    limits: CompileLimits = .{},       // tamaño de programa, unroll, anidamiento, max_memo_bytes
};
pub const ExecLimits = struct { max_steps: u64, max_backtrack_stack_bytes: usize };

pub fn analyze(gpa, src: Source, flags: Flags) SyntaxError!Analysis;
pub fn compile(gpa, src: Source, flags: Flags, opts: CompileOptions) CompileError!Regex;

pub const Regex = struct {
    pub fn tier(self) Tier;
    pub fn analysis(self) *const Analysis;         // features, razones de promoción, group_count, nombres
    pub fn groupCount(self) u32;
    pub fn groupNames(self) []const NamedGroup;
    /// Primitiva RegExpBuiltinExec sin estado: sticky desde `index`, o búsqueda.
    pub fn execAt(self, subject: Subject, index: usize, scratch: *Scratch,
                  out: *MatchSlots, limits: ExecLimits) ExecError!bool;
    pub fn advanceIndex(self, subject: Subject, index: usize) usize;  // AdvanceStringIndex(u)
};
pub const Scratch = struct { /* listas de hilos de la VM, pila del backtracker, trail, memo */ };
pub const MatchSlots = struct { slots: []?usize };  // 2*(group_count+1); el host decide cómo materializar
pub const SyntaxError = struct { kind: SyntaxErrorKind, offset: usize };
pub const ExecError = error{ StepLimitExceeded, BacktrackStackExhausted, OutOfMemory };
```

- La fachada actual (`Regex.compile/find/findAll/replace`) se mantiene como capa de conveniencia sobre `execAt`, para no romper a `z-string`.
- No hay callbacks al motor JS ni tipos del motor: solo slices, enteros y allocators.

**Concurrencia:**
- **`Regex` es inmutable después de `compile`** y se puede compartir entre hilos sin sincronización. Regla de diseño: `Regex` no tiene cachés perezosas mutables. Todo el estado mutable (listas de hilos de la VM, pila del backtracker, trail, memo de lookarounds) vive en `Scratch`.
- **`Scratch` no es thread-safe ni reentrante.** Un host multi-hilo usa un `Scratch` por hilo (thread-local) o un pool con préstamo exclusivo.
- Si el host vuelve a ejecutar una regex dentro de un callback (por ejemplo, un `replace` con función), usa otro `Scratch`.
- En builds Debug, `Scratch` tiene un flag `in_use` que hace panic si se usa dos veces a la vez.

### 4.3 Qué pasa si una feature no está soportada en el Tier actual

1. **Nunca** se degrada la semántica en silencio.
2. Si `min_tier <= max_tier`, se promueve automáticamente (comportamiento por defecto).
3. Si `min_tier > max_tier`, devuelve `error.TierExceeded` con `Analysis.reasons` (por ejemplo, "backreference at offset 7 requires tier expert"). Es un error de política del consumidor, distinto de `SyntaxError`.
4. Si `force_tier < min_tier`, es un error de uso (solo tests).
5. Si se supera un límite de implementación, devuelve `error.PatternTooLarge` de forma explícita.
6. Si un Tier está deshabilitado en el build y el patrón lo requiere, devuelve `error.TierUnavailable`.

### 4.4 Interfaz T2 ↔ T0/T1

**D-A. Dos programas coordinados, no un programa híbrido.**
- El backtracker tiene un solo cursor y una pila de choicepoints; la VM tiene listas de hilos. Son modelos de estado incompatibles: en un solo flujo de instrucciones, cada intérprete tendría que conocer las instrucciones del otro, y T0 dejaría de poder compilarse y probarse solo.
- Con programas separados, `t0.Program` no cambia, T0 no importa nada de T2 (lo verifica el build) y la coordinación se reduce a una instrucción.
- Se comparten **funciones**, no intérpretes: `CharSet.contains`, `canonicalize`, `Subject.decodeAt`/`decodeBefore`.

```zig
pub const T2Program = struct {
    bt: []const BtInst,
    linear: []const t0.Program,   // un programa por cada sitio de lookaround delegado
    memo_count: u16,              // == linear.len
};

pub const LookLinear = struct {
    prog: u16,          // índice en T2Program.linear
    dir: t0.Direction,  // forward (lookahead) | backward (lookbehind; linear[prog] ya está invertido)
    negated: bool,      // se aplica DESPUÉS de consultar la VM o la memo
    memo: u16,          // índice de la tabla de memo en Scratch; en este diseño memo == prog
};

pub const BtInst = union(enum) {
    // ... Lit, RunSet, Split, Save, ClearSlots, BackRef, LookBegin/End, ...
    look_linear: LookLinear,
};
```

- **No se deduplican programas lineales idénticos.** Un mismo cuerpo textual puede tener semántica distinta según los modificadores en contexto (`(?i:(?=a))` frente a `(?=a)`). Deduplicarlo de forma segura exigiría un hash estructural del HIR normalizado con los flags efectivos, una complejidad que hoy no se justifica. **No hay datos de que existan cuerpos repetidos** en patrones reales; se puede revisar con F0c.
- **La memo guarda el resultado sin la negación**, así que no depende de `negated`.
- **Codificación de la memo (2 bits por posición):**

| Bits | Significado |
|---|---|
| `00` | no evaluado |
| `01` | evaluado: no existe match anclado en esta posición |
| `10` | evaluado: existe match anclado en esta posición |
| `11` | **no se usa**; es inválido (`unreachable` en Debug) |

- Cada tabla se reserva la primera vez que se usa el sitio y ocupa `⌈(n+1)·2/8⌉` bytes (n = longitud del Subject en unidades). Si supera `limits.max_memo_bytes`, **ese sitio funciona sin memo** y cada evaluación se descuenta del presupuesto de pasos. No es un error.

**D-B. Firma de la delegación de un lookaround sin capturas:**

```zig
// tier0/pikevm.zig — T0 no sabe que lo llama T2
pub const Direction = enum { forward, backward };
pub fn existsAnchoredMatch(
    prog: *const Program,        // compilado desde el cuerpo (invertido si es backward)
    subject: Subject,
    pos: usize,                  // posición actual del cursor del backtracker
    dir: Direction,
    scratch: *VmScratch,         // sub-scratch dentro del Scratch de T2, reutilizado
    budget: *Budget,             // el MISMO presupuesto de pasos del backtracker
) ExecError!bool;                // true = existe al menos un match anclado en `pos`
```

- Devuelve solo `bool`, sin posición final ni capturas: un lookaround no consume y, sin capturas, solo importa si existe. La VM puede cortar en el primer `Match`, sin buscar leftmost-first.
- **Condición para delegar:** el cuerpo es ≤ T1, no tiene capturas ni lookarounds anidados (si los tuviera, sería T2). Por eso la VM nunca se reentra y basta un único `VmScratch`.

**D-C. ¿La VM de T0 puede escribir en el trail del backtracker? No.**
- Por construcción, los cuerpos delegados no tienen capturas, así que no hay nada que registrar.
- La firma lo impone: `existsAnchoredMatch` no recibe slots ni el trail.
- Permitirlo haría que T0 dependiera de un tipo de T2, lo que rompe la regla de dependencias.

**D-D. Trail (undo-log de capturas):**
- **Es global al backtracker, uno por ejecución**, y vive en `Scratch`. El backtracker no tiene hilos, así que un trail por hilo no tiene sentido.
- Estructura: una pila de pares `(slot, valor_anterior)`. Cada choicepoint guarda `trail_height`; al backtrackear se deshace hasta esa altura. `ClearSlots` también escribe en el trail.
- **Lookahead positivo exitoso:** se recorta la pila de choicepoints a la altura de entrada (es atómico), **pero se conservan las entradas del trail**, para que un backtracking posterior por delante del lookahead deshaga sus capturas.
- **Lookahead o lookbehind negativo:** siempre se deshace el trail hasta la altura de entrada.
- **Lookbehind + backrefs:**
  - El cuerpo se emite **invertido**: la secuencia en orden inverso y `SaveEnd` antes de `SaveStart`, ejecutado con `dir = backward`.
  - En modo backward, `BackRef` compara `Input[pos-len .. pos]` y retrocede, como el BackreferenceMatcher del spec con dirección −1.
  - Un grupo que está más a la derecha en el texto fuente se matchea primero, así que `(?<=\1(a))` funciona como en JS sin reglas especiales.
  - El trail es independiente de la dirección.

**D-E. Tramos lineales dentro del backtracker: bucles especializados, no el bucle de la Pike VM.**
- Se usan las instrucciones `Lit{units}` y `RunSet{set, min, max, greedy}`. `RunSet` avanza mientras `set.contains` sea cierto y empuja **un solo choicepoint de rango** `(pos_min, pos_actual)` en lugar de uno por caracter. Es la idea del `matchStarGreedy` actual, llevada a la pila explícita.
- La Pike VM solo se invoca para cuerpos completos de lookarounds delegados, donde el coste de la llamada se amortiza sobre todo el cuerpo y además hay memo.
- Invocar la VM caracter a caracter dentro del backtracker pagaría la gestión de listas de hilos con un único camino vivo. Con este diseño no hay overhead del intérprete de hilos en contexto recursivo, porque ese caso no existe.

---

## 5. Arquitectura de auto-consumo

### 5.1 Diagrama de capas

```
                         ┌──────────────────────────────────────────────┐
  Host (motor JS, z-string, CLI…) → solo usa api/ (Source, Subject, Flags, execAt)
                         └───────────────┬──────────────────────────────┘
                                         │
 ┌───────────────────────────────────────▼───────────────────────────────────────┐
 │ api/        compile(): parse → analyze → select tier → lower → backend        │
 └───┬───────────────────┬───────────────────────┬───────────────────────────────┘
     │                   │                       │
 ┌───▼────────┐   ┌──────▼────────┐        ┌─────▼──────────────────────────────┐
 │ syntax/    │──►│ analysis/     │──tier─►│ Dispatcher (estático, determinista)│
 │ parser     │   │ features,     │        └──┬──────────────┬──────────────┬───┘
 │ completo   │   │ min_tier,cost │           │T0            │T1            │T2
 └───┬────────┘   └───────────────┘           ▼              ▼              ▼
     │ AST
 ┌───▼─────────────────────────────────────────────────────────────────────────┐
 │ ir/  HIR + CharSet + Canonicalize(ascii)          ← compartido por todos    │
 └───┬───────────────────────────────┬─────────────────────────────┬───────────┘
 ┌───▼──────────────────┐   ┌────────▼─────────────┐   ┌───────────▼─────────────────┐
 │ T0 tier0/            │◄──│ T1 tier1/            │◄──│ T2 tier2/                   │
 │ Pike VM lineal       │   │ unicode/ tablas,     │   │ Backtracker con pila        │
 │ + prefiltros         │   │ fold, conjuntos v,   │   │ explícita, trail, budget,   │
 │ (sin unicode/)       │   │ \q{}, contadores →   │   │ dirección ±1; usa CharSet/  │
 │                      │   │ emite Program de T0  │   │ Canonicalize y llama a la   │
 │                      │   │                      │   │ VM de T0 (LookLinear)       │
 └──────────────────────┘   └──────────────────────┘   └─────────────────────────────┘
        ◄ = "usa"; solo hacia abajo. Un Tier inferior nunca importa a uno superior.
```

### 5.2 ¿Quién decide el Tier mínimo?

Un **clasificador de features** (`analysis/`) que recorre el árbol una vez, después del parser y de las early errors:
- Cada nodo aporta un `Feature` (enum), y `tier_of(feature, flags)` es una tabla constante en comptime.
- Reglas que dependen de los flags o del contenido:
  - `u` o `v` ⇒ al menos T1.
  - `i` con cualquier caracter o CharSet no-ASCII ⇒ al menos T1.
  - `BackRef` o cualquier `Look*` ⇒ T2.
  - Un desenrollado que supera `limits.unroll_budget` ⇒ al menos T1.
- `min_tier` es el máximo sobre todo el árbol. Cada nodo guarda su `subtree_tier`, lo que permite la delegación parcial.
- El resultado es inspeccionable (`Analysis.reasons`), útil para telemetría del host y para medir la hipótesis 70/20/10.
- No lo decide el parser (que se mantiene puro) ni la entrada: la misma regex da siempre el mismo Tier, así que el host puede cachear la decisión.

**Tabla de clasificación de ejemplo** (es la base de los tests de F0a). En F0a también son `unclassifiable` los patrones con posesivos (D8) o con un `{n}` mayor que 65536 (D10), por el mismo criterio que D1; ver `src/analysis/classify.zig`.

| Patrón | Flags | Resultado en F0a | Resultado desde F1 | Motivo |
|---|---|---|---|---|
| `[0-9]{,5}` | — | `unclassifiable`, razón `known_deviation(.D1)` | T0 | Hoy el lexer lo compila como `{0,5}` (D1); F0a no clasifica sobre una semántica que se sabe incorrecta. Desde F1 es Annex B: un dígito seguido del texto literal `{,5}`. |
| `[0-9]{,5}` | `u` | `unclassifiable`, `known_deviation(.D1)` | SyntaxError | Hoy `parseRepeat` no consulta `unicode_mode` y también lo acepta. |
| `\d{3}-\d{4}` | — | T0 | T0 | |
| `^[\w.+-]+@[\w-]+\.[\w.]+$` | — | T0 | T0 | |
| `(?<year>\d{4})-(?<month>\d{2})` | `g` | T0 | T0 | Los nombres son metadatos. |
| `\bfoo\b` | `i` | T0 | T0 | Contenido ASCII. |
| `café` | `i` | T1 | T1 | Contenido no-ASCII bajo `i`. |
| `k` | `iu` | T1 | T1 | Con `u`+`i`, K (U+212A) se pliega a `k`. |
| `\p{L}+` | `u` | T1 | T1 | |
| `[\p{L}--[a-z]]` | `v` | T1 | T1 | |
| `<(\w+)>.*?<\/\1>` | — | T2 | T2 | Backreference. |
| `(?<=\$)\d+(?:\.\d{2})?` | — | T2 (lookbehind delegable) | T2 | El cuerpo es ≤ T1 y no tiene capturas. |
| `^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).{8,}$` | — | T2 (3 lookaheads delegables) | T2 | |

### 5.3 Fallback y delegación

- **Promoción (hacia arriba):** es estática y ocurre en `compile`. No hay fallback dinámico de T0 a T2 durante la ejecución, porque T0 cubre por completo su subconjunto.
- **Delegación (hacia abajo), en T2:**
  1. **Prefiltro:** T2 usa el prefiltro de T0 (prefijo literal o conjunto del primer caracter) para saltar posiciones de inicio imposibles.
  2. **Lookarounds sin capturas ni backrefs** (`(?=\d{3})`, `(?<!foo)`): el cuerpo es ≤ T1 y se evalúa con `LookLinear` (§4.4). Es correcto porque, sin capturas, solo importa si existe un match, y el lookaround es atómico por spec.
  3. **Segmentos deterministas:** `RunSet` y `Lit` (D-E).
- **En T1:** T1 es un compilador de datos que alimenta la VM de T0; no reimplementa el matching.

### 5.4 Evitar T2 cuando no hace falta y medir costos

- El Tier depende de las features, no de la complejidad percibida: `(a|b)*c` o `\d{3}-\d{4}` nunca llegan a T2.
- Reescrituras semánticamente probadas antes de clasificar (por ejemplo, `x(?=$)` → `x$`). Se empieza con **cero** reescrituras; cada una se agrega con su propio test diferencial.
- `CostEstimate` estático: tamaño del programa, número de estados, altura de estrellas anidadas y ambigüedad (patrones del tipo `(a+)+`).
  - En T2 se usa para fijar el presupuesto por defecto y emitir advertencias.
  - En T0/T1 hay garantía de memoria O(estados) y tiempo O(n·estados).
- Contadores de ejecución (pasos, pico de pila) en modo debug y en benchmarks, para calibrar.

### 5.5 Cómo se verifica que la semántica no cambia

1. **El veredicto es test262 real, desde F0b.** Se ejecuta con Node y el shim FFI sobre `src/c_api.zig` (que ya existe para este uso, según `build.zig`) y cubre `built-ins/RegExp`, `language/literals/regexp` y `annexB`. Es una puerta de CI, no un informe.
2. **El diferencial entre Tiers (`force_tier`) es señal, no veredicto, mientras T2 no esté reescrito.** T2 hereda los bugs del backtracker actual, así que usarlo como oráculo sería circular. Las discrepancias se registran pero no bloquean merges.
3. **Política ante una discrepancia:**
   - Si T0 ≠ T2 y test262 da la razón a T0 → **es un bug de T2 y se corrige T2**, no T0. Se agrega un test de regresión.
   - Si test262 da la razón a T2 → es un bug de T0.
   - Si test262 no cubre el caso → desempata el diferencial contra V8, y el caso se incorpora como regresión.
4. **El diferencial pasa a bloquear merges** para los patrones sin lookbehind al cerrar F6a, y para los patrones con lookbehind al cerrar F6b (o nunca, si aplica el plan B de F6b).
5. **Tests de clasificación** (§5.2), para que cualquier cambio del clasificador sea visible en la review.
6. **Invariante de build:** T0 se compila como módulo aislado sin `unicode/`; una importación hacia arriba no compila.

### 5.6 La hipótesis 70/20/10

La hipótesis no es un supuesto: **se mide en F0c** y se reporta como histograma. Se reportan por separado el conteo por patrón único y el ponderado por ocurrencias; test262 va aparte porque está sesgado hacia casos borde. Advertencia: la frecuencia estática en un corpus no es la frecuencia de ejecución, y sin telemetría del host eso no se puede saber.

Lo que no cambia: **T0 va primero, porque es la base de T1** (T1 no tiene ejecutor propio).

- **Si el resultado es 50/40/10:** T1 pesa el doble de lo supuesto.
  - F5 arranca en paralelo con F4b en lugar de esperarla.
  - El fast path ASCII para CharSets Unicode (bitmap de 128 bits antes de la búsqueda binaria) pasa a ser criterio de salida de F5.
- **Si el resultado es 60/20/20:** T2 concentra el doble de tráfico y el backtracker actual (recursivo, con D7, D9 y D11) queda expuesto más tiempo.
  - **F6a se adelanta antes de F5**, inmediatamente después de F4a (la delegación necesita la VM sin capturas de F4a, no la de F4b).
  - La memo de lookarounds y los límites públicos (D11) suben de prioridad.
- **Regla de decisión:** si T2 ponderado ≥ 15 %, F6a va antes de F5; si no, después. **D14 refuerza la prioridad de F6a** con independencia del histograma: mientras el matcher sea recursivo, cualquier consumidor con poca pila (FFI, hilos) puede crashear en patrones anidados que hoy pasan con 8 MiB, y con D15 algunos (`()\1{1000}`) crashean incluso con 8 MiB, porque el límite de recursión exige ≈ 25 MiB para llegar a disparar. F6b siempre va después de F6a. El umbral es una convención de este plan, no un dato.

---

## 6. Estrategia de implementación incremental en Zig

### 6.1 Módulos

```
src/
  api/         regex.zig (fachada nueva + la actual como wrapper), options.zig, errors.zig
  syntax/      lexer.zig, parser.zig, ast.zig, early_errors.zig   (desde src/parser/)
  analysis/    features.zig, classify.zig, cost.zig
  ir/          hir.zig, lower.zig, charset.zig, canonicalize_ascii.zig
  subject/     subject.zig (Unit = u8 | u16; decode u/no-u; surrogates WTF-8)
  tier0/       program.zig, compile.zig, pikevm.zig, prefilter.zig
  tier1/       unicode_sets.zig, fold.zig, class_strings.zig, counters.zig  (usa src/unicode/)
  tier2/       compile.zig, backtrack.zig (pila explícita), trail.zig, memo.zig
  unicode/     (existente) tables.zig, properties.zig, casefold.zig (+ CaseFolding.txt)
```

Módulos en `build.zig`:
- `zregex-t0`: syntax + analysis + ir + subject + tier0.
- `zregex-t1`: lo anterior + unicode + tier1.
- `zregex`: todo.

Un consumidor que solo necesite T0 puede importar `zregex-t0` y no enlaza las ~330 KB de tablas.

### 6.2 Comptime vs runtime

- **Comptime:** el tipo de unidad del `Subject` (`fn VM(comptime Unit: type)`), los Tiers habilitados en el build (`-Dtiers=0,1,2`, expuestos en `core/config.zig`), las extensiones no-ECMA y el trazado.
- **Runtime:** los flags de la regex, `max_tier`, los límites y `force_tier`.
- Si un Tier está deshabilitado en el build y el patrón lo requiere, devuelve `error.TierUnavailable`; la semántica nunca se degrada.

### 6.3 Roadmap por fases

**Decisión de F0a sobre D1–D3:** F0a **no** corrige D1–D3. Marca como `unclassifiable` los patrones afectados, y el contrato `Analysis` de F0a no cubre esos casos hasta F1.
- **Motivo:** corregir D1–D3 cambia lo que se compila para los consumidores actuales (`z-string`), es decir, rompe semántica. Un cambio así pasa por la puerta de test262, que no existe hasta F0b. Mezclarlo en F0a le quitaría a F0a la cualidad de ser mergeable sin riesgo.
- **D2 y D3** ya los rechaza el parser actual (`InvalidRepeat`, `EmptyCharClass`), así que salen como `unclassifiable(.parse_error)` sin trabajo adicional.
- **D1** lo acepta mal, así que F0a incluye un **detector léxico** (no una corrección): busca `{` fuera de una clase que no forme `{n}`, `{n,}` o `{n,m}` según la gramática del spec.
  - **Implementado (F0a):** en lugar de un escáner que replique al lexer, el propio lexer registra la desviación cuando `parseRepeat` acepta un `{…}` con mínimo vacío (D1) o un mínimo recortado (D10), y el parser descarta ese registro al rebobinar un token especulativo (`Lexer.rewindTo`). No cambia la tokenización. Así se evitó reimplementar el seguimiento de clases y escapes, que era el riesgo que alargaba la estimación a 1–2 semanas. F0a también marca D8 (posesivos) como `unclassifiable`, por el mismo criterio.

**Duración de F0a: 1 a 2 semanas, no 1.**
- Una semana alcanza para el clasificador sobre el AST y los tests de la tabla de §5.2.
- El detector de D1 tiene que replicar el seguimiento de clases (incluidas las clases anidadas de `v`) y de escapes que hoy hace el lexer con modos, y el repo ya tuvo bugs precisamente en ese seguimiento (Phase 5c). Con sus propios tests, eso agrega del orden de días.
- No se conoce la dedicación ni la velocidad del equipo, así que la estimación es de esfuerzo, no de calendario.

| Fase | Contenido | Criterio de salida |
|---|---|---|
| **F0a — Prototipo de `analyze()` (1–2 semanas, mergeable) — hecho** | `src/analysis/classify.zig`: tabla feature→tier en código, sobre el AST actual (`NodeType` + `char_value` + flags). `analyze()` pública. Detección de D1 (sin corregirlo). Los patrones afectados devuelven `min_tier = null` y `unclassifiable = known_deviation(D1 | D8 | D10)` o `parse_error`. Sin cambios en la semántica del compilador ni backends nuevos. | Las filas de §5.2 están implementadas como tests y pasan, incluidas las de `{,5}` como `unclassifiable`. **Lista de no clasificables (ampliada al implementar):** D1, D8 y D10 detectados, más `parse_error`, que incluye D2/D3 y los SyntaxError reales. `Analysis{features, min_tier: ?Tier, reasons}` queda congelado como contrato, **que no cubre D1–D3 hasta F1**. Esas filas tienen su test post-F1 escrito y marcado como `skip`. |
| **F0b — test262 real — hecho** | Harness con Node + FFI (`c_api.zig`) sobre `built-ins/RegExp`, `language/literals/regexp` y `annexB`; baseline del porcentaje por directorio. | Corre en CI; baseline registrada; es la puerta de todas las fases siguientes. **Hecho:** `scripts/test262/` + `zig build test262`; baseline en `scripts/test262/baseline.json` (3033 entradas del motor, 2729 pass, 90,0 %; 86,6 % de las que ejercitan zregex); detalle y causas raíz en `docs/KNOWN_LIMITATIONS.md` § "test262 baseline (F0b)". |
| **F0c — Medición de 70/20/10** | `analyze()` sobre un corpus: test262 (aparte), regex extraídas de paquetes npm con un script offline en `scripts/`, y un corpus público de regex de investigación si existe y su licencia lo permite (**disponibilidad y licencia por verificar**). | Histograma publicado (único y ponderado); orden de F5/F6a decidido con la regla de §5.6. **Sensibilidad de `UNROLL_BUDGET`**: cuántos patrones del corpus cambian de Tier con 500, 1000 y 5000; si se mueven mucho entre 500 y 1000, el umbral está en zona inestable y se fija con más cuidado. |
| **F0d — Baseline y red de seguridad** ✅ **Cerrada** | **Hecho:** bench (`zig build bench`, §7.2), `test-conformance` con aserción y sin stderr en éxito, `zig fmt` + generador de tablas (Unicode 17.0.0 verificado). **Cierre (hecho):** (1) **bugs históricos como tests permanentes** (`tests/regression_tests.zig`: Phase 0/2/6, `ce885bf`, `a30acf8`, `7d36074`, la fuga de F0a y D14; el de D14 con 1 MiB queda `skip` hasta F6a); (2) **límite explícito de anidamiento del parser**: `nesting_depth`/`error.NestingTooDeep` para grupos, lookarounds y clases anidadas de `v` (los cuantificadores no anidan por sí mismos). Es un contador distinto de `MAX_ALTERNATION_DEPTH` (capacidad del arreglo de rastreo de nombres duplicados, que hoy corta de hecho en 31 grupos). **`MAX_NESTING_DEPTH = 256`, fijado por medición** (pila mínima de `compile()` a profundidad 1/10/20/30, crecimiento exactamente lineal): **ReleaseSafe ≈ 1,2 KB por nivel** (256 niveles ≈ 318 KB ≤ 1 MiB / 2; máximo seguro ≈ 420); **Debug ≈ 15,5 KB por nivel** (256 niveles ≈ 4 MiB). `NestingTooDeep` no depende del build (mismo error en ambos), **pero cuántos niveles caben antes de crashear sí**: en Debug, 200 niveles sobre 1 MiB crashean en lugar de dar `NestingTooDeep`. Es coherente (Debug no es para producción) y F2 lo corrige. El test "256 niveles en 1 MiB" corre solo en builds Release (en Debug hace `skip`); en todos los modos, un test con el límite bajado a 30 compila 30 niveles en 1 MiB y da `NestingTooDeep` en 31. El límite es un campo del `Parser` para poder testearlo por debajo de 31. **F0d añade el mecanismo; F1 sube la capacidad de `MAX_ALTERNATION_DEPTH` a `MAX_NESTING_DEPTH` (≥ 200) y entonces `nesting_depth` pasa a ser el límite efectivo. Hasta F1, T15/T16 siguen fallando igual (`AlternationTooDeep`).** (3) **fuzz del parser** (`tests/fuzz_parser.zig`): `std.testing.fuzz` sobre `compile()` (sin flags, `u`, `v`), `analyze()` y `find` sobre sujetos cortos (corpus: los *patrones* de `tests/test262_data.zig`) + estrés determinista de 20.000 patrones con semilla fija en `zig build test`; crash o fuga con `std.testing.allocator` = test fallido. **Resultado, separado por alcance:** (a) **Fuzz sobre parser/`analyze`: cobertura completa**, sin crash ni fuga (20.000 patrones × 3 modos; 1,5 M con otra semilla en ReleaseSafe, 5 min, sin commitear). (b) **Fuzz sobre el motor: parcial hasta F6a.** Los patrones T2, y los que `analyze` no clasifica, se compilan pero **no se ejecutan**: **1.757 de 6.537** combinaciones patrón×modo que compilan (1.159 T2, 598 no clasificables); se ejecutan 4.780. Motivo: D15 (`()\1{1000}`, reducido desde `\2{9007199254740991}\[*`), reportado y no arreglado, con test `skip` hasta F6a. **Cierre: los patrones T0/T1 no tienen crashes en el fuzz; T2 no está cubierto por el fuzz hasta F6a** (no se afirma que el motor actual no tenga más crashes). Estructura: el corpus corre en `zig build test` (≈ 0,4 s); el estrés, en `zig build test-fuzz-stress` (≈ 16 s en Debug, 4 s en ReleaseSafe), a mano o en CI semanal. `zig build test --fuzz` no compila en Zig 0.16.0 (bug de `test_runner.zig` de la std), así que el modo continuo queda pendiente (§8.2). `docs/ARCHITECTURE.md` y `docs/PROJECT_STRUCTURE.md` pasan a F7. | Números base registrados; `test-conformance` en verde y capaz de fallar; `zig fmt --check src/` limpio; tests de regresión, límite de anidamiento y corpus del fuzz en `zig build test`; estrés en `zig build test-fuzz-stress`; cobertura del fuzz declarada (motor: solo T0/T1 hasta F6a); `zig build test262` sin regresiones. |
| **F1 — Semántica compartida correcta** | D1, D2, D3, D4, D5, D8 (posesivos a opt-in), D9 (slots dinámicos, `\10`+ con reglas Annex B), D13 y D16; gramática `u` estricta completa; early errors. **Los modificadores salen de F1** y son una fase propia, con su plan después de F1. Sub-fases, cada una con reporte y parada: **F1a** (léxico y tablas, sin cambio de AST: early errors y gramática `u`, `\xFF`, D13, D4, D5), **F1b** (pre-escaneo de grupos y nombres, D1/D2/D3, escapes de Annex B, D8, clasificador sin D1/D8), **F1c** (D9 en dos commits: (a) índices y operandos u16 con `TooManyCaptures`, que corrige D16; (b) slots dinámicos, `\10`+ y el límite de anidamiento; más nombres Unicode y referencias hacia adelante). Se activan los tests de F0a marcados `skip`. **Requisito de F1c(1), medido en el Paso 0 de F1:** subir el tamaño de los arrays fijos no sirve. `parseAtom` tiene como local un `GroupNameEntry` con `branch_path: [MAX_ALTERNATION_DEPTH]BranchStep`, y con el límite en 257 el parser pasa de ≈ 1,6 KiB a ≈ 4,9 KiB por nivel en ReleaseSafe (de ≈ 15,6 a ≈ 64,6 KiB en Debug), de modo que 256 niveles ya no caben en 1 MiB. `branch_path` y `branch_stack` pasan a memoria dinámica acotada por `nesting_depth` (o el parser a iterativo), y entonces `nesting_depth` es el límite efectivo. **D16 bloquea F1c(a):** no se llega a D9(b) sin corregirlo. **Avance: F1a hecha** (2794/3017 en la baseline: 59 entradas del objetivo, más 2 de bonus de D5; 0 misses). Además cerró dos bugs previos a F1 que encontraron sus tests: una doble liberación en `parseCharClass` cuando falla una asignación (`[a-]`), y `[\D]`/`[\W]`/`[\S]` dentro de una clase, que no cubrían nada por encima de U+00FF. `MAX_CLASS_RANGES` pasa de 8 a 30, con fusión de rangos en el codegen. **T15 (200 grupos *capturantes* anidados) queda pendiente de F6a:** parser, codegen y `deinit` caben en 8 MiB, pero el matcher gasta ≈ 49 KiB por grupo capturante anidado (dos frames de `matchFrom`, D15), así que 200 niveles necesitan ≈ 9,8 MiB. T16 (`(?:`, sin frame por nivel en el matcher) sí es alcanzable. | test262 `syntax` y `annexB` en verde (salvo lookbehind); tests post-F1 de F0a en verde. **Objetivo numérico sobre la baseline de F0b (2733/3017, 90,6 %): ≥ 2838 pass (≥ 94,1 %) y 0 regresiones.** `scripts/test262/categorize.mjs` asigna a F1 111 no-pass alcanzables: Annex B 20, gramática `u`/early errors 41, nombres de grupo 18, D13 10, D9 8, D3 6, D4 6, `\xFF` 2. Las 4 `S7.8.5_A1.5/A2.5` se reatribuyen al lexer de JS (host): `\` + salto de línea es inválido en un *literal*, pero válido como patrón, y zregex coincide con V8. Sin T15, el máximo es 2842 y el objetivo deja **4 misses acumulados en toda F1**, cada uno documentado al gastarlo; T15 se documenta en `KNOWN_LIMITATIONS.md` como pendiente de F6a. D5 desbloquea además 2 entradas atribuidas antes a F3 (`dotall/without-dotall-unicode`), que son un bonus fuera del objetivo. La baseline se actualiza por sub-fase con `--update-baseline-improvements`, que solo registra mejoras y se niega a escribir si hay una regresión. |
| **F2 — IR + Analysis** | HIR, CharSet dinámico (elimina `MAX_CLASS_RANGES` y el límite de 4 propiedades por clase); `analyze()` migra al HIR; el backtracker actual consume el HIR (una sola ruta, todavía sin Tiers); módulos de build separados por Tier. **Objetivo explícito (de F0d): hacer el parser iterativo, o reducir la pila por nivel de anidamiento a ≤ 2 KB en Debug** (hoy ≈ 15,5 KB; ≈ 1,2 KB en ReleaseSafe). Cualquiera de las dos; al cumplirse, `MAX_NESTING_DEPTH` funciona igual en Debug y Release y se activa el test de Debug. **Medición previa, reportada antes de decidir el enfoque:** `@sizeOf` del estado del parser y de `Token` en la firma de las funciones recursivas. Si el frame del parser es > 1 KB, el problema es estructural y lo resuelve el parser iterativo; si es < 500 B, algo más consume pila (cadenas de `catch`/`errdefer`, `std.debug` en algún camino). | Tests de clasificación sin cambios salvo los documentados; sin regresiones en test262. |
| **F3 — Subject abstracto** | `Subject` WTF-8/UTF-16; semántica de code unit (sin `u`) frente a code point (con `u`) (D6); `advanceIndex`; `execAt` con `Scratch`; corregir D12. | Los mismos tests en ambos encodings. |
| **F4a — VM lineal sin capturas** | Caracteres, clases, anclas, alternancia, cuantificadores sin capturas internas; prefiltros (incluida la búsqueda de literal con `std.mem.indexOfScalar`); fast path de clase única; `existsAnchoredMatch`. Los patrones con capturas siguen yendo al backtracker. | Diferencial contra el backtracker con 0 discrepancias en patrones sin capturas (corpus + fuzz); sin regresiones en test262; objetivos de §7 para T0 sin capturas; overhead dentro de los límites de §7 (si no, aplica la regla de §7). |
| **F4b — Capturas y semántica fina** | Capturas etiquetadas, prioridad greedy/lazy, regla de iteración vacía, `ClearSlots`. | Diferencial completo sin discrepancias, o con discrepancias atribuidas a T2 y confirmadas por test262 (§5.5); sin regresiones en test262; overhead dentro de §7. |
| **F5 — Tier 1** | Tablas desde CaseFolding.txt; Canonicalize con y sin `u`; clausura de folding sobre conjuntos; `v` completo (anidado, `\q{}`, propiedades de strings, con datos de `emoji-sequences.txt` y `emoji-zwj-sequences.txt`); `PatternTooLarge` (D10); contadores solo si F0c los justifica; versión de Unicode fijada (DC4); corregir las tablas para que `General_Category=Other` incluya Cn (hallado en F0b); aceptar los alias cortos de propiedades binarias (`UnknownUnicodeProperty`, ~114 entradas de test262; su primera corrida ejecutará el bucle por símbolo de `testPropertyEscapes` y puede tardar más o tener timeouts). | test262 `property-escapes`, `unicodeSets` y flag `i` en verde; **tests exhaustivos de Canonicalize y folding por fuerza bruta sobre 0..0x10FFFF en verde**. |
| **F6a — Tier 2 sin lookbehind** | Backtracker con pila explícita en heap (sin recursión nativa); trail; backrefs numéricas, con nombre y con `i`; lookahead (atomicidad, capturas); asserts cuantificados Annex B; `LookLinear` forward con memo; `ExecLimits` públicos (D11). Los patrones con lookbehind siguen en el backtracker actual. **T15 refuerza F6a** (Paso 0 de F1): con 200 grupos capturantes anidados, el matcher recursivo necesita ≈ 9,8 MiB de pila en ReleaseSafe (≈ 49 KiB por nivel; en Debug ≈ 147 KiB por nivel, ≈ 29 MiB); con 8 MiB crashea y con 16 MiB hace match. Además necesita las capturas dinámicas de D9(b). **D15 refuerza F6a:** el límite de recursión del matcher actual (1000) exige ≈ 25 MiB de pila para dispararse (≈ 25 KiB por nivel), así que en cualquier pila por defecto crashea antes; solo una pila explícita con límite en bytes lo resuelve. | test262 de backrefs, `named-groups` y lookahead en verde; ningún patrón T2 sin lookbehind pasa por `recursive_matcher.zig`; `(a+)+b` y similares cumplen la cota de §7; **el diferencial entre Tiers pasa a bloquear merges para patrones sin lookbehind**; el fuzz del parser ejecuta también los patrones T2 y se quitan los `skip` de D14 y D15 (el de D15 tiene que dar match vacío). |
| **F6b — Lookbehind** | Matching hacia atrás (D7): IR invertido, instrucciones de consumo en dirección −1 para ambos encodings, cambio de dirección lookahead↔lookbehind anidados, backrefs hacia atrás, `LookLinear` backward con programas invertidos. | test262 `lookBehind` en verde; diferencial contra V8 en lookbehind sin discrepancias; `recursive_matcher.zig` sin usos. |
| **F6b — Plan B** | Si F6b no cierra dentro de su timebox (se fija al iniciar F6b; **no hay datos de velocidad para proponer una cifra**): se publica **sin lookbehind**. Los patrones con `(?<=…)`/`(?<!…)` fallan en `compile` con `error.UnsupportedFeature` (no `SyntaxError`, porque el patrón es válido) y se documenta en `docs/KNOWN_LIMITATIONS.md` como limitación conocida. **No** se conserva la implementación actual con ventana de 100 bytes, porque da resultados incorrectos en silencio. | Limitación documentada; tests que verifican el error explícito. **Impacto:** hoy el repo acepta lookbehind (con D7), así que el plan B es una regresión funcional para los consumidores actuales; se acepta a cambio de no dar resultados incorrectos (ver P10). |
| **F6b — Nota de F0d** | Dado el throughput medido en F0d (`(?<=\$)\d+` a 0,27–0,34 MB/s, ~74× por debajo del objetivo de ≥ 20 MB/s), **el plan B (publicar sin lookbehind) no es solo una defensa: es una opción razonable si el timebox se agota.** La decisión de intentar F6b completo debe justificarse contra el uso real del feature (F0c), no contra la completitud del spec. | — |
| **F7 — Endurecimiento** | Enforcement final de dependencias en el build; suite de benchmarks; retirar `recursive_matcher.zig`; telemetría opcional de Tiers para el host. Actualizar `docs/ARCHITECTURE.md` y `docs/PROJECT_STRUCTURE.md` (movido desde F0d). | Conformidad test262 medida y publicada en `docs/KNOWN_LIMITATIONS.md`. |

### 6.4 Agnosticismo e integración con un motor JS

- La lib nunca ve objetos JS. El host implementa `RegExpBuiltinExec` alrededor de `execAt` (lee y escribe `lastIndex`, crea el array resultado, `groups` e `indices`), y usa `expandReplacement` para GetSubstitution. `matchAll`, `split` y el resto de los protocolos `Symbol.*` son del host (§3.4).
- El host elige la representación de strings: si guarda UTF-16 usa `Subject.utf16`; si guarda WTF-8 (como `z-string` después de `7d36074`) usa `Subject.wtf8` y mapea índices (la lib puede ofrecer un helper de mapeo UTF-16↔WTF-8).
- El caché de `Regex` por (source, flags) es responsabilidad del host; `compile` es puro y determinista.
- Errores: `SyntaxErrorKind` + offset, sin textos de mensaje obligatorios.
- Allocators explícitos y `Scratch` reutilizable, con una instancia por hilo (§4.2): el host controla toda la memoria.

---

## 7. Plan de pruebas, fuzzing y benchmarks

### 7.1 Tipos de prueba

| Tipo | Qué | Dónde |
|---|---|---|
| Unitarias | Lexer/parser (cada producción + Annex B), CharSet (álgebra), Canonicalize, cada instrucción de la VM y del backtracker | Junto a cada módulo (patrón actual del repo) |
| Clasificación | patrón + flags → tier + razones (§5.2) | `tests/tier_classification.zig` |
| Conformidad (veredicto) | test262 real, desde F0b | `zig build test-conformance` |
| Diferencial interno (señal hasta F6a/F6b) | `force_tier` en todos los Tiers elegibles; delegación on/off; WTF-8 frente a UTF-16 | `tests/differential.zig` |
| Fuzz | (a) bytes arbitrarios → parser (sin crash ni leak); (b) generador gramatical de patrones + entradas → diferencial; (c) corpus diferencial contra V8 generado offline | `zig build fuzz` (fuzzer integrado de Zig) + `tests/corpus/` |
| Memoria | `std.testing.allocator` en todos los tests; `std.testing.checkAllAllocationFailures` en compile/exec | CI |
| Benchmarks | Casos de §7.2; métricas: MB/s, allocs por exec, pico de memoria, pasos | `zig build bench` (ReleaseFast), resultados versionados |

### 7.2 Objetivos de rendimiento por Tier

Son **estimaciones de orden de magnitud, no mediciones**. No hay benchmarks en el repo, y las cifras del README (`README.md:208-216`) no tienen un script que las respalde. Se recalibran con el baseline de F0d. Se supone ReleaseFast en un x86-64 o arm64 moderno a ~3 GHz.

| Benchmark (entradas de 1–10 MB) | Tier | Objetivo | Aspiracional | Baseline F0d (medido) | Razonamiento |
|---|---|---|---|---|---|
| Literal `hello` | T0 | **≥ 300 MB/s** | 500 MB/s | 6,1–6,4 MB/s | Prefiltro con `std.mem.indexOfScalar` sobre el primer byte o unidad del literal + comparación del resto (en F4a). Un memmem SIMD propio no está en el roadmap. **No verifiqué si `indexOfScalar` está vectorizado en la std de Zig 0.16**; por eso el objetivo que cuenta es 300. |
| `/[a-z]+/` con la VM genérica | T0 | ≥ 50 MB/s | — | 8,0–8,5 MB/s | 2–3 hilos activos × 5–10 ns por paso (dispatch, test de conjunto, inserción en sparse set) ≈ 10–30 ns/byte, es decir 33–100 MB/s. |
| `/[a-z]+/` con fast path de clase única | T0 | ≥ 500 MB/s | — | 8,0–8,5 MB/s (no hay fast path) | Basta una tabla de 256 entradas y un bucle simple (`while (i < n and tbl[s[i]]) i += 1`), ~1–2 ns/byte; no requiere desenrollado ni despacho especializado. Con Subject UTF-16, la tabla cubre las unidades < 256 y el resto va por `CharSet.contains`. |
| `\d{3}-\d{4}` con dígitos dispersos / densos | T0 | ≥ 200 / ≥ 40 MB/s | — | 5,4–6,7 / 4,7–5,8 MB/s | El prefiltro por primer byte descarta la mayoría de las posiciones / con dígitos densos trabaja la VM genérica. |
| Email | T0 | ≥ 30 MB/s | — | 3,0–3,2 MB/s | Más hilos activos. |
| `\p{L}+` con `u`, texto mixto / mayormente ASCII | T1 | ≥ 30 / ≥ 100 MB/s | — | 10,7–11,0 / 8,0–8,8 MB/s | Búsqueda binaria en rangos (~20–40 ns por code point) / bitmap ASCII primero. |
| `[\p{L}--\p{Lu}]` con `v` | T1 | igual que `\p` | — | 3,5–3,7 MB/s | El conjunto se calcula en compilación. |
| `<(\w+)>.*?<\/\1>` sobre HTML no adversarial | T2 | ≥ 10 MB/s | — | 13,7–14,8 MB/s | Sin objetivo de throughput para entradas adversariales. |
| `(?<=\$)\d+` | T2 | ≥ 20 MB/s | — | 0,27–0,34 MB/s | Lookbehind delegado a la VM con memo (disponible desde F6b). |
| `(a+)+b` y `(a\|aa)*c` sobre 40 `a` + un caracter que no matchea | T2 | `StepLimitExceeded` en ≤ 10 ms con el presupuesto por defecto | — | `StepLimitExceeded` en 44–48 ms (tope de 30 s no alcanzado) | Lo que se garantiza es la cota, no el throughput. |

**Baseline F0d.** Medido con `zig build bench` (`bench/bench.zig`, ReleaseFast): `findAll` sobre 1 MiB de entrada generada con semilla fija, mediana de 5 corridas, rango de 3 ejecuciones del bench. Intel Xeon @ 2,10 GHz, 4 núcleos, contenedor compartido: es **una sola máquina con ruido de ±10–20 %**, así que sirve para comparar fases entre sí, no como cifra absoluta. Detalle completo (asignaciones por `findAll`/match, tiempo de `compile`) en `zig-out/bench/results.json`. Lectura:
- Todo el camino actual está entre **0,3 y 15 MB/s**: 1–2 órdenes de magnitud por debajo de los objetivos de T0/T1. Esto es coherente con D12: `find` crea un matcher por posición y avanza de a un byte, sin prefiltro.
- `(?<=\$)\d+` es el peor caso (0,3 MB/s): el lookbehind actual (D7) prueba hasta 100 longitudes en cada posición.
- Asignaciones: 1–2 por match en la mayoría de los casos (la copia de 16 capturas del `MatchResult`), pero **~108 por match en email**, por las listas de posiciones de `matchStarGreedy`.
- Los casos adversariales agotan el presupuesto por defecto (1 M de pasos) en ~45 ms desde la primera posición de inicio; el objetivo de ≤ 10 ms implica bajar ese presupuesto o hacer cada paso ~5 veces más barato. **El presupuesto por defecto no está calibrado contra ese objetivo**; se revisa en F6a.

**Si no se llega al objetivo de literal (300 MB/s):**
1. Se perfila y se prueba a elegir, en lugar del primer byte, el byte del literal menos frecuente según una tabla fija de frecuencias. Sigue usando la std, sin SIMD propio.
2. Si aun así no se llega, se registra la cifra medida, se baja el objetivo en este documento con la justificación, y se abre una tarea de memmem SIMD fuera del roadmap.

Este objetivo **no bloquea F4a**: el throughput de literal no es un límite de corrección ni de overhead. Los límites de overhead sí bloquean (ver abajo).

**Overhead aceptado frente al backtracker actual.** En patrones triviales con entradas cortas, la Pike VM puede ser más lenta que el backtracker, que tiene un solo cursor y no gestiona hilos. Se acepta:
- hasta **1,5×** el tiempo por `exec` con entradas < 64 B;
- hasta **1,2×** con entradas ≥ 1 KB;
- hasta **2×** en tiempo de compilación.

El costo se justifica por la garantía de tiempo lineal. Los porcentajes son una política propuesta, no un dato.

**Si no se cumplen los límites de overhead, se pospone la fase.**
- Una categoría de patrones solo se enruta a la VM cuando cumple los límites. Mientras no los cumpla, el dispatcher la sigue enviando al backtracker actual (el comportamiento de hoy, sin regresión) y la fase no se cierra.
- Esto se aplica en F4a a los patrones sin capturas y en F4b a los patrones con capturas.
- Se descarta aceptar más overhead, porque rompe en silencio el contrato de rendimiento.
- Se descarta reconsiderar un híbrido (enviar de forma permanente los patrones "seguros" al backtracker), porque añade un tercer camino de ejecución y va contra la idea de una sola semántica.
- Costo de la postergación: esos patrones no tienen la garantía lineal mientras dure; solo los protege el presupuesto de pasos.

---

## 8. Riesgos y mitigaciones

### 8.1 Mitigaciones reales

Mecanismos que, una vez implementados, acotan el riesgo por construcción.

| Riesgo | Tier | Mecanismo | Estado hoy |
|---|---|---|---|
| Backtracking catastrófico | T0/T1 | Ejecutor lineal por construcción: O(n·m), sin backtracking | Pendiente (F4a/F4b) |
| Backtracking catastrófico | T2 | Presupuesto de pasos compartido por el backtracker y la VM delegada, configurable desde la API pública | Existe (`recursive_matcher.zig:168`) pero **no es público** (D11) → F6a |
| Backtracking catastrófico | T2 | Memo `(lookaround, pos)`: cada lookaround delegado se evalúa como mucho una vez por posición | Pendiente (F6a/F6b) |
| Patrones no confiables | todos | `max_tier` en `compile` + `error.TierExceeded` | Pendiente (F0a/F2) |
| Stack overflow en ejecución | T2 | Pila explícita en heap con límite de bytes (`BacktrackStackExhausted`) | Hoy recursión nativa con límite de profundidad, con crashes previos (`ce885bf`, Phase 6) → F6a |
| Stack overflow en el parser | todos | Contador de anidamiento con límite explícito que devuelve un error | Parcial: solo alternancia (`MAX_ALTERNATION_DEPTH = 32`, `parser.zig:99`); el resto en §8.2 |
| Divergencia entre Tiers | todos | Un solo parser/HIR/CharSet/Canonicalize; T1 sin ejecutor propio | Pendiente (F2) |
| Dependencias hacia arriba | todos | Módulo de build `zregex-t0` sin `unicode/`: una importación indebida no compila | Pendiente (F2) |
| Asignaciones y fugas en exec | todos | Todo el estado de ejecución vive en un `Scratch` reutilizable; sin allocs por exec en el caso normal | Pendiente (F3) |
| Fugas no detectadas | todos | `std.testing.allocator` en todos los tests como gate de CI (detecta, no previene) | Existe en los tests actuales |
| Condiciones de carrera | todos | `Regex` inmutable; `Scratch` con `in_use` en Debug | Pendiente (F3) |
| Deriva de las tablas Unicode | T1 | Versión fijada en el generador (DC4) | **No existe** (`latest`) → F5 |
| Pérdida semántica silenciosa por límites | T1 | `error.PatternTooLarge` en lugar de recortar | Hoy recorta (D10) → F5 |
| Resultados incorrectos de lookbehind | T2 | Plan B de F6b: error explícito en lugar de la ventana de 100 bytes | Hoy da resultados incorrectos (D7) → F6b |

### 8.2 Tareas pendientes fuera del roadmap

Trabajo suelto que no pertenece a ninguna fase. No son mitigaciones: reducen el riesgo solo cuando se completan.

| Tarea | Cuándo |
|---|---|
| `analyze()` deja de recoger features al encontrar una desviación conocida: `\2{9007199254740991}` sale `known_deviation` (D10) sin registrar la backreference, así que su Tier queda sin determinar. El fuzz no ejecuta los no clasificables por esto | F2 (`analyze()` migra al HIR) |
| `zig build test --fuzz` no compila en Zig 0.16.0 (`test_runner.zig`: `*builtin.StackTrace` frente a `*const debug.StackTrace`). Reintentar el modo continuo al subir de Zig | Al subir la versión de Zig |
| Fuzz diferencial gramatical (T0/T1 frente a T2, frente a V8 offline) | Desde F4b |
| Actualizar `docs/ARCHITECTURE.md`, `docs/PROJECT_STRUCTURE.md` y `README.md` (desactualizados) | Junto con F7 |
| `tests/test262_data.zig` no pasa `zig fmt --check`: `scripts/gen_test262_data.py` emite las listas de un elemento con espacios (`&[_]?[]const u8{ "x" }`), como pasaba con el generador de tablas Unicode (corregido en F0d). Corregir el generador y formatear | F7, o cuando se toque `gen_test262_data.py` |

---

## 9. Supuestos y preguntas abiertas

**Supuestos**
- S1. Un Tier es el backend mínimo requerido; T1 no tiene ejecutor propio.
- S2. `z-string` y `z-lexer` usan la API actual (`Regex.compile/find/...`, `unicode.isInCategory`), que se mantiene como wrapper. Esos repos no se revisaron.
- S3. D12 (arrancar a mitad de una secuencia UTF-8) está inferido del código, no verificado ejecutándolo.
- S4. Los objetivos de rendimiento de §7.2 son estimaciones hasta tener F0d.
- S5. Las duraciones (F0a: 1–2 semanas) son de esfuerzo, no de calendario: no se conoce la dedicación del equipo.

**Preguntas abiertas**
- ~~P1~~ **Cerrada** (F0d): la versión de Unicode es 17.0.0; ver DC4.
- **P2.** ¿Se adopta ES2026? No sé con certeza qué cambios de RegExp incluye.
- P3. ¿El motor consumidor guarda los strings en UTF-16, Latin1 o WTF-8? ¿Hace falta `Subject.latin1`?
- P4. ¿Los posesivos se mantienen como opt-in o se eliminan del todo?
- P5. ¿Qué `max_tier` por defecto quiere el host para patrones no confiables?
- P6. ¿Se puede romper la API pública actual (`CompileOptions`, `MatchResult` con 16 capturas) o hay que mantener compatibilidad con `z-string` durante una versión?
- P7. ¿Hay CI con Node para test262 desde F0b, o el harness se ejecutará solo en local?
- P8. ¿Qué límites de implementación son aceptables (tamaño de programa, conteos `{n}`, `max_memo_bytes`) y cómo se reportan al host?
- P9. ¿Qué corpus reales se pueden usar en F0c, con qué licencia y con qué ponderación?
- P10. Si se activa el plan B de F6b, ¿aceptan los consumidores actuales (`z-string`) perder lookbehind temporalmente, o necesitan un aviso previo o una versión mayor?

---

## 10. Verificación

- `zig build test` y `zig build test-conformance` (test262 real desde F0b) en cada fase; nuevos `zig build fuzz` y `zig build bench`.
- Tests de clasificación estables (§5.2).
- Diferencial `force_tier`: señal hasta F6a; bloquea merges desde F6a (sin lookbehind) y desde F6b (con lookbehind).
- `std.testing.allocator` sin fugas; `checkAllAllocationFailures` en compile y exec.
- Conformidad test262 medida y documentada en `docs/KNOWN_LIMITATIONS.md` al cierre de cada fase.
