# F7c: precheck. Inventario y sub-fases

Base: `c5aa744` (v0.6.0 en `main` es `ae52e85`). Solo lectura: no se tocó `src/` ni `build.zig`.
Las cifras son de este árbol; lo que no está claro está marcado **(sin decidir)**.

F7c es la última fase antes de v0.7.0: API congelada, código limpio y docs honestas. Después
viene el período de producción y luego v1.0.0.

**Regla del freeze:** toda sintaxis válida no implementada es `error.UnsupportedFeature`, y lo
que llegue después solo puede quitar casos de error, nunca añadir errores nuevos.

## 0. Hallazgo bloqueante: `i` + `v` da resultados incorrectos en silencio

Bajo `v`, los sets todavía pliegan con la regla anterior a F5b: letras ASCII y el par simple de
un literal (entonces en `KNOWN_LIMITATIONS.md`, «Unicode case folding under `v` (F5c)»; hoy `LIMITATIONS.md`, «`v` with `i`»). No es un
`UnsupportedFeature`, es un resultado distinto del de V8.

Medido con la `.so` de `c5aa744`, UTF-16:

| Patrón | Sujeto | V8 | zregex |
|---|---|---|---|
| `/[À-Ö]/iv` | `"à"` | `[0,1]` | sin match |
| `/[\p{Lu}]/iv` | `"a"` | `[0,1]` | sin match |
| `/[\w]/iv` | `"ſ"` | `[0,1]` | sin match |
| `/[a-z]/iv` | `"K"` | `[0,1]` | `[0,1]` |
| `/[[A-Z]--[Q]]/iv` | `"q"` | sin match | sin match |

`lbdiff-v8` ya contaba 2 de sus 6 diferencias fijas como «`v` con `i`» (B′). Con el freeze,
esto no se podría convertir después en `UnsupportedFeature` sin romper la regla (sería un error
nuevo).

**Hay que decidirlo antes de congelar (sin decidir):**
- **(a) Implementar el plegado bajo `v`.** Es parte de F5c. Sin medir.
- **(b) Dar `UnsupportedFeature` a `i`+`v` con sets que el plegado viejo no cubre.** Es lo que hizo E0 con `\q{}`. Rechaza patrones que hoy compilan y a veces aciertan: hay que medir cuántos en los corpus.
- **(c) Documentarlo como divergencia conocida.** Contradice la regla de E0 («nunca un resultado incorrecto»).

**Cerrado en F7c-0 con (b″)** (decisión del usuario, tras medir (b′) y (b″) con prototipos):
- con `iv`, literales y clases usan el plegado de F5b en modo Unicode (el de `iu`);
- `UnsupportedFeature` en toda propiedad, en toda clase negada con miembros plegables y en las operaciones de conjuntos con un operando no cerrado bajo el plegado.

| Con `iv` (1,059 patrones) | Compilan | Coinciden con V8 | Distintos sin error | `UnsupportedFeature` |
|---|---|---|---|---|
| Antes | 1,026 | 727 | 299 | 33 |
| (b′): solo el plegado de `iu` y los operandos cerrados | 594 | 580 | 14 | 465 |
| **(b″), implementada** | **221** | **221** | **0** | **838** |

`lbdiff-v8` pasa a la referencia `lbdiff-v8-f7c0.json` (la de v0.5.1, archivada): 6 patrones fijos con `iv` pasan a `UnsupportedFeature`, uno de ellos el de las 6 diferencias. `lbdiff` sigue con 0 discrepancias; sus cuentas se mueven (invalid 16 → 672, B′ 15,532 → 14,904, comparados 13,142 → 13,116), porque los cuerpos `iv` rechazados cuentan como «invalid».

(b′) no bastaba: bajo `v`, `\P{…}` complementa después de plegar, y V8 no hace coincidir el signo Kelvin con `\p{ASCII}/iv`. Detalle en `LIMITATIONS.md`, «`v` with `i`», y las mediciones en `HISTORY.md`.

## 1. API pública actual

`src/main.zig` tiene **61 declaraciones `pub`**: 60 `pub const` y `placeholder()`.

| Grupo | Símbolos | Uso en `tests/`, `tools/`, `bench/`, `examples/` |
|---|---|---|
| **Estable** (propuesta del usuario) | `Regex` (métodos: `compile`, `compileWithOptions`, `deinit`, `matchFull`, `test_`, `find`, `findAt`, `findFrom`, `findAll`, `getPattern`, `groupCount`, `slotCount`, `execAt`, `iterator`, `advanceIndex`, `replace`, `replaceAll`), `CompileOptions`, `MatchResult`, `Subject`, `Scratch`, `MatchSlots`, `MatchIterator`, `ExecLimits`, `ExecError`, `unicode.isInCategory` (+ `unicode.UnicodeProperty`), `test_`, `find`, `findAll`, `version` | `Regex` en 21 archivos; `CompileOptions` en 14; `Scratch`/`MatchSlots`/`Subject` en 8; `MatchResult`, `MatchIterator`, `ExecError` y `unicode` en ninguno (se usan vía `Regex`) |
| **Interno** | `DynBuf`, `BitSet256`, `DynBitSet`, `Pool`, `Pooled`, `debug`, `Budget`, `Opcode`, `OpcodeCategory`, `Instruction`, `BytecodeWriter`, `BytecodeReader`, `disassemble`, `Token`, `TokenType`, `Lexer`, `Node`, `NodeType`, `Parser`, `ParseError`, `CodeGenerator`, `CodegenError`, `MAX_PROGRAM_BYTES`, `compile`, `compileSimple`, `CompileResult`, `compileTiers`, `Compiled`, `TierUnavailable`, `force_backtracker`, `CharSet`, `subject` (módulo), `hir`, `lower`, `tier2`, `tier0`, `NamedGroup`, `Capture`, `Matcher`, `CaptureIndices`, `analysis`, `analyze`, `two_pass_fallbacks`, `zig_version_required` | ver la tabla de tests |
| **Borrar** | `Optimizer`, `OptLevel`, `placeholder()` | ninguno |

**Huecos en la superficie estable:**
- **`RegexError` no se exporta** (`regex.zig:147`). Es el conjunto de errores de `compile`: sin él, el consumidor no puede nombrarlo. **Hay que exportarlo.**
- **`replace` y `replaceAll` libres** (`regex.zig:588`, `595`) no se exportan; `test_`, `find` y `findAll` sí. Exportarlos o no **(sin decidir)**.
- **Campos de `CompileOptions`:** `opt_level` (se borra), `case_insensitive`, `multiline`, `dot_all`, `sticky`, `unicode`, `v`, `possessive` (extensión no-JS), `force_tier`, `tier_diagnostic`, `t0_prefilters` y `t2_look_linear`. Los cuatro últimos son diagnóstico y ajuste de tiers: ¿estables o internos? **(sin decidir)**. `tier_diagnostic` necesita `TierUnavailable`, que hoy está en «interno».
- **C API (40 símbolos `zregex_*`):** el usuario la cuenta como estable, pero `PROJECT_STRUCTURE.md` y la tabla resumen de `KNOWN_LIMITATIONS` la describen como «internal FFI substrate, not a public API», y el README dice «no maintained C headers». **Contradicción que hay que resolver en F7c.**

**Tests y herramientas que usan símbolos internos:** 12 archivos, 83 líneas.

| Archivo | Líneas | Símbolos |
|---|---|---|
| `tests/t0_tests.zig` | 29 | `tier0`, `tier2`, `lower`, `analysis`, `compile`, `Budget`, `TierUnavailable`, `force_backtracker`, `subject` |
| `tests/tier2_pipeline_tests.zig` | 17 | `Lexer`, `Parser`, `CodeGenerator`, `BytecodeWriter`, `Opcode`, `Matcher`, `compileSimple`, `CompileResult`, `hir`, `lower`, `tier2` |
| `tests/fuzz_common.zig` | 12 | `ParseError`, `lower`, `tier0`, `analysis`, `analyze`, `force_backtracker` |
| `tests/exec_tests.zig` | 4 | `compile`, `analysis` |
| `tests/snapshot_common.zig` | 4 | `compile`, `CompileResult`, `disassemble` |
| `tests/regression_tests.zig` | 3 | `compile`, `MAX_PROGRAM_BYTES` |
| `tests/hir_contract_tests.zig` | 3 | `Lexer`, `Parser`, `lower` |
| `tests/code_unit_tests.zig` | 2 | `compile`, `tier2` |
| `tests/syntax_tests.zig` | 2 | `Lexer`, `Parser` |
| `tools/lbdiff.zig` | 3 | `analysis`, `analyze` |
| `tools/f0c.zig` | 2 | `analysis`, `analyze` |
| `bench/bench.zig` | 1 | `two_pass_fallbacks` |

Las herramientas del scratchpad (sección 3) también usan internos: `pfdiff`/`tagck` usan `tier0.*`, `lower.Frontend` y `analysis`; `t1diff` usa `analysis`; `lldiff` usa `tier2`.

**Código muerto:**

| Candidato | Estado real | Dónde |
|---|---|---|
| `Optimizer` + `OptLevel` | Muerto: no se ejecuta desde F7b | `tier2/codegen/optimizer.zig` (3 tests propios), `tier2/root.zig:12`, `main.zig:67-68` |
| `CompileOptions.opt_level` | Muerto: sin efecto | `compile.zig:38`; lo usan 2 tests (`regex.zig:615`, `compile.zig:439`) |
| Opcode `LOOP` (0x16) | Nunca se emite; `exec1` no lo trata | `opcodes.zig:157`, `338`, `373`, `398`, `543` (test); `format.zig:136`, `216`; los diagramas de `ARCHITECTURE.md:278-309` |
| Opcode `CHAR2` (0x02) | Nunca se emite; `exec1` no lo trata (P1) | `opcodes.zig` (4), `format.zig` (2), `core.zig:488`, `generator.zig:797` |
| **`pending_trail` del lexer** | **No es código muerto.** Con `code_units`, que se activa en todo patrón sin `u`/`v` (`lower.zig:81`, `625`), un escape por encima de U+FFFF devuelve la mitad alta y deja la baja aquí (F3d). No se borra | `lexer.zig:221-1270` |

## 2. Documentación

| Documento | Líneas | Estado |
|---|---|---|
| `docs/ARCHITECTURE.md` | 549 | Describe la estructura anterior a F2: `parser/`, `codegen/optimizer.zig`, `recursive_matcher.zig` como motor único, «`src/unicode/` design only», diagramas con `LOOP`. No describe `frontend/`, `ir/` (HIR), `analysis/`, `subject/`, `tier0` (Pike VM etiquetada), `tier2` (pila explícita, trail, LookLinear), ni el lookbehind hacia atrás (arquitectura B) |
| `docs/PROJECT_STRUCTURE.md` | 370 | Igual: árbol con `core/`, `parser/`, `codegen/`, `executor/`, `bytecode/`, «unicode: 0 lines, design only», `executor/recursive_matcher`, y un ejemplo de `main.zig` con `executor/matcher.zig`. Llama a la C API «internal FFI substrate» |
| `docs/KNOWN_LIMITATIONS.md` | 2094 | Ver el desglose de abajo |
| `README.es.md` | 374 | Aviso de «desactualizado, anterior a 0.3.0». Badge «tests 402/402», «Versión 0.1.0», el ejemplo de configuración no compila con Zig 0.16. Último cambio: `c557ec0` |
| `docs/BENCHMARKS.md` + `bench/results.json` | 426 | Medido en **0.3.0**. F7b midió solo deltas de rendimiento y tamaño en `KNOWN_LIMITATIONS` («F7b closed»). Hay que re-medir las tablas T0/T1 (findAll y execAt MB/s), T2 (lookbehind, ahora con B′ y hacia atrás) y el tamaño del binario |
| `README.md` | 304 | Badge 2994/3017 ✓. Tabla de soporte ✓ (v0.6.0). El roadmap dice «E3, F7c → v1.0.0»; el plan nuevo es **F7c → v0.7.0 → producción → v1.0.0**. Hay que actualizarlo (también `ROADMAP_1.0.md`) |
| `docs/ROADMAP.md` | 1003 | Roadmap antiguo de las fases 0-8; lo sustituye `plans/ROADMAP_1.0.md`. Candidato a archivar **(sin decidir)** |
| `docs/REGEX_TIERS_PLAN.md` §6.1 | — | Ver sección 6 |

**Desglose de `KNOWN_LIMITATIONS.md`, 2094 líneas:**

| Parte | Líneas | Rango |
|---|---|---|
| Cabecera y versión (una línea de 1124 caracteres con el historial de versiones) | 30 | 1-30 |
| «What works»: capacidades actuales, pero casi cada entrada anotada con «(fixed in Phase N)» | 438 | 31-468 |
| **Historial de fases** (test262 sample, F1-F5b, F7-0, baseline F0b, cambios de F1) | 1082 | 469-1550 |
| Vigente: `test_()` vs `find()` y «Confirmed bugs» | 15 | 1551-1565 |
| Historial: «Fixed in E0» | 18 | 1566-1583 |
| Vigente: la regla y la tabla de E0 | 42 | 1584-1625 |
| Historial: F7a, `Optimizer`, binario F7b, cierre F7b y B′ | 137 | 1626-1762 |
| Vigente: F6b (0.6.0) y la divergencia de V8 dentro de un par sustituto | 80 | 1763-1842 |
| Historial: «Fixed in F2b» | 23 | 1843-1865 |
| Vigente: «Genuinely unimplemented», «Summary», «When to use» | 229 | 1866-2094 |

Resumen: vigente estricto unas 366 líneas (+438 de «What works»); historial 1,260; cabecera 30.

**Filas desfasadas en «Summary»:**
- «Lookahead / Lookbehind … fixed length without captures, F6b step 1»: F6b ya está cerrada.
- «`case_insensitive` (ASCII)»: el plegado completo existe desde F5b.
- «test262 conformance sample 168/168».
- «`u` flag: malformed … still lenient» (sin verificar hoy).

## 3. Herramientas del scratchpad

| Herramienta | Código | Depende de | Corpus / referencia |
|---|---|---|---|
| `gate.sh` | 59 líneas | todo lo de abajo; referencias de otro gate (`e0/g3`) | — |
| `pfdiff` + `tagck` (`eqf/`) | 344 + 136 líneas Zig, `arbiter.mjs` 120 | `build.zig.zon` con dos dependencias, `old` (copia vieja) y `new` (symlink al repo); usa `tier0.*`, `lower.Frontend` y `analysis` | `corpus.txt` 9,262 líneas (599 KB), `corpus2.txt` 31,374 (2.3 MB); referencias `slot.tsv` 460 KB, `pf.out`, `pfs.out` |
| `t1diff` | 124 líneas | ruta absoluta al repo en `build.zig.zon`; `arb.mjs` 17 líneas | los dos corpus + `f0c2/npm.tsv` 7,690 líneas (781 KB); referencia `t1.tsv` (vacía = 0 diferencias) |
| `lldiff` | 120 líneas | ruta absoluta al repo; `tier2` | los mismos 3 corpus |

**Coste de traerlas al repo:** unas 860 líneas de código y unos 3.7 MB de corpus más 0.46 MB de referencias.

Trabajo:
- rutas relativas;
- `pfdiff` sin la dependencia `old`, que hoy es una copia manual;
- pasos `zig build` para cada una;
- un `scripts/gate.sh` con la limpieza de caché;
- adaptar sus imports si los internos pasan a `internal`.

Estimación: 1–1.5 días.

`measure_binary.sh` y la sonda de callgrind:
- **`scripts/measure_binary.sh`** está en el repo, pero no en `gate.sh`: se ejecuta a mano en cada cierre.
- **`cgprobe`** (P3) **no está en el repo**: se borró con el worktree del spike y queda en `scratchpad/p3/cgprobe.zig`.
- **`lbdiff` y `lbdiff-v8`** están en el repo y en `gate.sh`.

## 4. Freeze de API

- **Estable:** la fila «Estable» de la sección 1, más `RegexError`. Pendiente de decidir: la C API, los 4 campos de ajuste de `CompileOptions`, `replace`/`replaceAll` libres y `possessive`.
- **A `zregex.internal`:** la fila «Interno» (44 símbolos). Los 12 archivos de tests y herramientas cambian `zregex.X` por `zregex.internal.X` en 83 líneas. No cambia ningún resultado.
- **Borrar:**
  - `Optimizer`, `OptLevel`, `opt_level` y `placeholder()`;
  - los opcodes `LOOP` y `CHAR2`, reservando sus valores 0x16 y 0x02 para no mover el formato;
  - los 3 tests de `optimizer.zig` y los 2 que fijan `opt_level`.
- **Cómo documentarlo:** una sección «API stability» en el README y en un `docs/API.md` nuevo **(sin decidir si es archivo aparte)**, con:
  - la lista de lo estable;
  - `zregex.internal` sin garantías;
  - la regla de errores: toda sintaxis válida no implementada es `UnsupportedFeature` y 1.x solo quita casos de error;
  - los nombres de error y sus códigos C como contrato;
  - `max_steps` por posición de inicio, que es un contrato y nunca pasa a por ejecución (`F7.md`, ítem 8);
  - la sección de `ExecLimits` de la C API (`F7.md`, F7c).

## 5. `zregex_version()`

- **Hoy:** devuelve `main.version`, la versión del paquete (`c_api.zig:182-183`). Medido con la `.so` de v0.6.0: `"0.6.0"`. Lo cubre el test `zregex_version is the package version`.
- **El `"1.0.0"` fijo del informe de F7b ya no existe:** se corrigió en v0.5.0 (`030c183`, «zregex_version() from the package version»).
- En F7c no hay nada que hacer, salvo mantenerlo en el gate.

## 6. `zregex-t0` (§6.1 de `REGEX_TIERS_PLAN.md`)

- **Hoy:** §6.1 describe un árbol (`api/`, `syntax/`, `ir/lower.zig`, `tier1/unicode_sets.zig`…) y tres módulos en `build.zig`, `zregex-t0`, `zregex-t1` y `zregex`: «Un consumidor que solo necesite T0 puede importar `zregex-t0` y no enlaza las ~330 KB de tablas».
- **Realidad:**
  - `build.zig` solo expone `zregex`; las capas (`ir`, `unicode`, `utils`, `subject`, `frontend`, `tier0`, `tier1`, `tier2`) son módulos internos;
  - el árbol real es `frontend/{parser,lower}`, `ir`, `analysis`, `subject`, `tier0`, `tier1` (solo `root.zig`, 14 líneas), `tier2/{bytecode,codegen,executor}`, `unicode` y `utils`.
- **Debería decir:** «`zregex-t0` no existe. Es un candidato condicionado a que un consumidor lo pida (`F7.md`, decisión 3: el básico ahorraría ~90 KB, el 17–19 %). Hoy el único módulo público es `zregex`.» Y el árbol real.

## 7. Items de 1.x: ¿dan `UnsupportedFeature`?

Medido con la `.so` de `c5aa744` contra V8 (Node 22):

| Item | Patrones probados | zregex |
|---|---|---|
| B6: lookaround dentro de un lookbehind hacia atrás | `(?<=a(?=b)c+)d`, `(?<=(?<!x)a+)b` | `UnsupportedFeature` ✓ |
| Lookbehind hacia atrás bajo `u`/`v` | `(?<=a+)b` con `u` y con `v`, `(?<=(a))b` con `u`, `(a)(?<=\1)b` con `u` | `UnsupportedFeature` ✓ |
| F5c: `\q{}`, propiedades de strings, operandos, unión anidada, encadenado | `[\q{abc\|d}]`, `\p{RGI_Emoji}`, `[\p{L}--a]`, `[\w--\d]`, `[[a][b]]`, `[A--B--C]` (todos con `v`) | `UnsupportedFeature` ✓ |
| Modificadores ES2025 | `(?i:a)`, `(?-m:^a)`, `(?ims-:a)` | `UnsupportedFeature` ✓ (el Node 22 del harness da SyntaxError) |
| **F5c: `i` con `v`** | ver la sección 0 | **✗ resultado incorrecto, sin error** |

## 8. Propuesta de sub-fases

| Sub-fase | Contenido | Días | ¿Bloquea v0.7.0? |
|---|---|---|---|
| **F7c-0** ✅ | `i`+`v` resuelto con (b″) (sección 0) | 1 | **Sí** (el freeze) |
| **F7c-1** ✅ | Herramientas al repo: `tools/{pfdiff,t1diff,lldiff,cgprobe}.zig`, `scripts/gate.sh`, `scripts/gate/` (árbitros V8), `scripts/test262/ivdiff.mjs`, `tests/corpus/{f2c,f2c-2}.txt` y `npm.tsv`, referencias `pfdiff-slots.tsv` e `ivdiff-f7c0.json`. `tagck` y la copia `old` del repo no se traen (fuera del gate y sin uso) | 1–1.5 | Sí: es el gate de las fases siguientes y del período de producción |
| **F7c-2** ✅ | Código muerto: `Optimizer`, `OptLevel`, `opt_level` y sus 5 tests, borrados; `LOOP` y `CHAR2` reservados (`RESERVED_16`, `RESERVED_02`) y sin referencias en codegen, executors ni encoder/decoder; test de que no se emiten. `placeholder()` queda para F7c-3 (no estaba en el alcance). `pending_trail` no es código muerto (lo usa el lexer en `code_units`) | 0.5–1 | Sí (API) |
| **F7c-3** ✅ | `zregex.internal` con 42 símbolos, 15 estables en la raíz más `RegexError`, `replace` y `replaceAll` libres; `placeholder()` y `zig_version_required` borrados; `CaptureIndices` estable (lo devuelve `MatchResult`); los 4 campos de diagnóstico de `CompileOptions` documentados fuera de la API estable; 17 archivos adaptados (10 de tests, 5 herramientas, `bench.zig`, `c_api.zig`); sección «API stability» en el README | 1.5–2 | Sí |
| **F7c-4** ✅ | Contrato de API en `docs/API.md`: los 19 símbolos estables con doc comment, `RegexError` (35) y `ExecError` (8) con sus códigos C, la regla del freeze, qué cambios rompen y la deprecación (`/// Deprecated: use X`, al menos un minor). Tests: la raíz, los dos conjuntos de errores y la tabla de códigos. Mapeo C corregido antes del freeze: 11 errores de sintaxis del frontend pasan de UNKNOWN a SYNTAX; 14 siguen en UNKNOWN (límites, invariantes, diagnóstico o sin productor). Paso `== fmt` en el gate (`tests/test262_data.zig` excluido: generado); `pfdiff`, `t1diff` y `lldiff` formateados. Movido a F7c-5: `max_steps` por posición de inicio como contrato, `ExecLimits` en la C API y el estado de la C API | 1 | Sí |
| **F7c-4b** ✅ | Antes del freeze, en clases `v`: la mezcla de `--` y `&&` es `MixedClassSetOperators` también con operandos planos (`[a--b&&c]` era `UnsupportedFeature`), y una lista o un rango como operando izquierdo es `InvalidClassSetOperand` (`[ab&&[c]]` y `[a-z&&[b]]` compilaban). V8 y ECMA-262 rechazan las dos formas. El bug B (operando derecho suelto, `[\p{L}--a]`) sigue en `UnsupportedFeature` | 0.5 | Sí |
| **F7c-5** ✅ | Docs, solo texto. `ARCHITECTURE.md` reescrito como referencia (pipeline, capas, compilación, ejecución, bytecode, memoria, errores, tests) y `PROJECT_STRUCTURE.md` como índice del árbol. `KNOWN_LIMITATIONS.md` dividido: `LIMITATIONS.md` (lo vigente: la regla, los `UnsupportedFeature`, divergencias con V8, lookbehind, `v` con `i`, qué funciona, límites, notas de API) e `HISTORY.md` (las secciones por fase, tal cual); `KNOWN_LIMITATIONS.md` queda como índice porque lo citan comentarios de `src/`. `REGEX_TIERS_PLAN` §6.1 con el árbol real (`zregex-t0` candidato, `zregex-t1` no existe). `ROADMAP_1.0.md`: F7c → v0.7.0 → producción 1–3 meses → v1.0.0, y la corrección del claim ES2023. `API.md`: `max_steps` por posición de inicio como contrato, `ExecLimits` en la C API (`max_recursion_depth` reservado). La C API: estable para el consumidor FFI, sin header, en `API.md`, `LIMITATIONS.md` y el README. `README.es.md`, `ROADMAP.md`, `CONCEPTS.md`, `F0C_*`, `F5_PLAN.md` y `F5A_CLOSING.md` a `docs/archive/` | 3–3.5 | Sí |
| **F7c-6** ✅ | Benchmarks re-medidos al final de F7c (`BENCHMARKS.md`, `results.json`, `bench/README.md`): 10 rondas intercaladas, el mejor por caso (criterio de F7-0), `-Dcpu=x86_64_v3`, en otro host que el de 0.3.0. z-regex 0.3.2 como motor base en las mismas rondas (`zregex_base` en `run.mjs`); `analyze.mjs` agrega por el mejor. Frente a 0.3.2: T1 bajo `u` 1,4–2,2×, lookbehind ~24×, doble lookahead 2,4×; el resto en ±10 % salvo una celda de diagnóstico (+12 %). `(a\|aa)*c` medido aparte | 1–1.5 | No |
| **F7c-7** ✅ (en F7c-5) | `README.es.md` archivado en `docs/archive/` (solo queda el README en inglés); `docs/ROADMAP.md` archivado | — | No |
| **F7c-8** ✅ | Versión 0.7.0 (`main.zig`, `build.zig.zon`, README, `API.md`, cabeceras de `LIMITATIONS`/`HISTORY`/`BENCHMARKS`); `docs/RELEASE_NOTES_v0.7.0.md`; en `BENCHMARKS.md`, el e-mail como peor caso de T0 frente a Rust (19×; 2,2× frente a V8, medido); doc comments de `unicode` y `v` en `compile.zig`; `build.zig.zon` sin `include/` y con descripción nueva; `test_` queda documentado sin cambio de comportamiento; gate final | 0.5–1 | Sí |

**Total:** 10–13.5 días, más F7c-0 si se elige (a).

**Orden que minimiza conflictos:** F7c-0 → F7c-1 → F7c-2 → F7c-3 → F7c-4 → F7c-5 (con F7c-6 en paralelo) → F7c-7 → F7c-8.
- **F7c-0 primero:** es la única que cambia resultados, y el resto documenta un comportamiento que ya no se mueve.
- **F7c-1 antes del código:** así las fases que tocan `src/` se validan con el gate del repo, y las herramientas se adaptan una sola vez a `internal` (en F7c-3).
- **F7c-2 antes que F7c-3:** así no se mueve a `internal` lo que se va a borrar.
- **Docs al final:** describen la API ya congelada.

**Puede ir a 1.x:** F7c-6 (si se acepta publicar v0.7.0 con las cifras de 0.3.0 marcadas como tales), F7c-7, `cgprobe` al repo y el plegado bajo `v` si se elige (b).
