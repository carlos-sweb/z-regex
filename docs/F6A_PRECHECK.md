# F6a: verificación previa y plan

Lo que se midió antes de escribir código en F6a (backtracker con pila explícita, trail y
LookLinear), y el plan que salió de ello. Medido en `66a9d60` con sondas del scratchpad (un
proceso por caso, `ulimit -s`), `zregex_xbench` y los corpus de F0c (npm) y F2c. Las líneas
citadas son las de `66a9d60`.

## H1. `src/tier2/executor/recursive_matcher.zig` (1.368 líneas)

**Tipos**

| Línea | Tipo | Nota |
|---|---|---|
| 36–59 | `ExecOptions {max_recursion_depth=1000, max_steps=1_000_000}` | Es el `ExecLimits` público (`regex.zig:83`, un alias). |
| 64 | `MatchResult {matched, end_pos}` | Se devuelve por valor en cada nivel. |
| 71 | `CaptureGroup {start: ?usize, end: ?usize}` | |
| 84 | `LoopState {pc, pos}` | |
| 94–130 | `Scratch {captures, snapshots, loop_guard, positions, in_use}` | |
| 139–177 | `RecursiveMatcherFor(Unit)` | Campos: `inline_captures[16]`, `heap_captures`, `snapshots`, `recursion_depth`, `step_count`, `loop_guard`, `positions`, `mode`. |
| 182 | `MatchError` | Incluye `RecursionLimitExceeded` y `StepLimitExceeded`. |

**Recursión nativa** (todo el núcleo; estilo de continuaciones: cada instrucción que avanza llama a `matchFrom(pc + size, pos')`, así que **la profundidad = la longitud del camino**, no el anidamiento):

| Línea | Qué | Detalle |
|---|---|---|
| 329–678 | `matchFrom` | |
| 331–336 | Paso por llamada | Se reinicia en cada posición de inicio: `matcher.zig:188`, `m.reset()`. |
| 339–343 | Límite de profundidad | 1000 niveles. |
| 350–351 | Contador de profundidad | |
| 366–435 | Instrucciones que consumen | Cada una recursa (p. ej. `CHAR32` en 366–371). |
| 437–446 | `GOTO` | Hacia atrás → `matchBackEdge`. |
| 448–525 | `SPLIT*` | Alternancia: prueba `pc1` y luego `pc2` (511–523). Si el `SPLIT` es un `*` simple, va a `matchStar`. |
| 527–576 | `SAVE_START`, `SAVE_END`, `CLEAR_CAPTURE` | Deshacer por frame: guarda `prev`, recursa y lo restaura si falla. |
| 578–588 | `BACK_REF(_I)` | Vía `matchBackRef` (1266). |
| 590–604 | Lookahead | `matchLookahead` (1085–1141): subllamada al cuerpo y luego a la continuación. |
| 606–619 | Lookbehind | `matchLookbehind` (1181–1232): hasta 100 posiciones atrás (D7). |
| 317–327 | `matchBackEdge` | Guarda de iteración vacía: búsqueda lineal en `loop_guard`, push/pop alrededor de la llamada. |
| 737–743 | `matchAnyChar` | |

**Ya fuera de la pila nativa (en el heap):**

| Estructura | Uso | Líneas |
|---|---|---|
| `positions` | El `*` greedy de un átomo simple guarda cada posición en una pila compartida | 909–950 |
| `snapshots` | Copia de todos los slots al entrar en un lookahead | 1106–1108, 1143 |
| `loop_guard` | Guarda de iteración vacía | |

Los tres ya se reutilizan desde `Scratch`: 0 asignaciones con el Scratch caliente.

**Reutilizable tal cual:**
- `decodeAt`/`decodeBefore` (701–709), `isLineTerminator*` (720–733) y `charMatches` (747–762);
- `checkCharSet` (777), `checkUnicodeProperty`/`Script`/`ScriptExtensions` (790–832) y `checkBackRef` (1278–1325);
- `isWordBoundary` (1332), `isStarQuantifier`/`isStarConsumePath`/`isQuantifiableAtomOpcode` (837–894), `matchSingleInstruction` (1013–1082) y `findLookaheadEnd` (1148);
- `captureSlotsIn` (269) y la gestión del Scratch (220–265).

Todo eso es lógica de "¿casa este átomo en `pos`?", sin control de flujo. **Se reescriben** `matchFrom`, `matchBackEdge`, `matchStar*`, `matchLookahead` y `matchBackRef`: unas 450 líneas.

**Semántica de la guarda de bucle (a conservar exacta):**
- En el estilo de continuaciones, la entrada `(pc, pos)` vive desde el salto hacia atrás hasta que esa llamada vuelve.
- Solo vuelve al fallar, o al terminar todo el match.
- Equivale a "vive hasta que se desapila un choicepoint anterior a ella": es una pila con altura guardada en cada choicepoint.

## H2. D14/D15 y bucles largos hoy

`probe` con `execAt`, límites por defecto. Tiempos: mediana de 5 en ReleaseSafe; el resto, una corrida.

| Caso | Debug 8 MiB | Debug 1 MiB | ReleaseSafe 8 MiB | ReleaseSafe 1 MiB | ReleaseFast 8 MiB |
|---|---|---|---|---|---|
| D15 `()\1{1000}` sobre `""` (spec: match `[0,0]`) | **SIGSEGV** en `matchFrom` (`recursive_matcher.zig:329`) | SIGSEGV | `RecursionLimitExceeded`, 0,86–1,07 ms | **SIGSEGV** (`:358`) | `RecursionLimitExceeded`, 0,99 ms |
| D14 `<body.*>((.*\n?)*?)<\/body>`/i (test262 `S15.10.2.8_A3_T17`) | `[7,96]`, 118 µs | `[7,96]`, 98 µs | `[7,96]`, 20 µs | `[7,96]`, 21 µs | `[7,96]`, 22 µs |
| `()\1{300}` | match | SIGSEGV | match 0,33 ms | match 0,26 ms | match 0,24 ms |
| `(x)(?:ab)*\1`, 100 × `ab` | match | SIGSEGV | match | match | match 0,35 ms |
| `(x)(?:ab)*\1`, 400 × `ab` (V8: match) | SIGSEGV | SIGSEGV | **`RecursionLimitExceeded`** | SIGSEGV | `RecursionLimitExceeded` |
| `(?:(a)\|b)*\1`, 2000 × `b` (V8: match) | SIGSEGV | SIGSEGV | `RecursionLimitExceeded` | SIGSEGV | `RecursionLimitExceeded` |

**Hallazgos:**
- D14 ya **responde** con 1 MiB desde F1c: la pila del llamador sigue decidiendo, pero en otros patrones.
- D15 crashea en Debug con cualquier pila y en ReleaseSafe con 1 MiB.
- Nuevo: un bucle con cuerpo no simple deja de responder a partir de ~330 iteraciones (unas 3 instrucciones por iteración frente al límite de 1000), y crashea con pilas pequeñas.

**Bug F** (encontrado aquí; previo; no está en los docs):
- Qué pasa: cuando un lookahead positivo tiene éxito y el camino falla más adelante, sus capturas no se deshacen.
- Causa: la copia de `snapshots` solo se restaura si falla el propio lookahead, y los frames de `SAVE_*` del cuerpo ya volvieron con éxito.
- Casos:

  | Patrón | Sujeto | zregex | V8 |
  |---|---|---|---|
  | `/(?:(?=(a))ab\|ac)/` | `"ac"` | g1 = `[0,1]` | `undefined` |
  | `/(?=(a))?.b\|../` | `"ac"` | g1 = `[0,1]` | `undefined` |
  | `/(?:(?=(a+))a*x\|a*)/` | `"aay"` | g1 = `[0,2]` | `undefined` |

- La Parte 2 (el trail, que se conserva tras el lookahead) lo corrige.

## H3. Dispatcher, VM y qué va al backtracker

**Hoy:**
- `Regex.exec` (`src/regex.zig:338–366`): si hay `t0`, la VM (plana, o tagged en `execCaptures`); si no, `Matcher.exec` (`src/tier2/executor/matcher.zig:174–203`) con `scratch.bt` (`regex.zig:53`) y `limits`.
- `route()` (`src/compile.zig:183–216`) manda al backtracker todo lo T2 y lo T1 que no cumple `vmTakesUnicode` (218).

**Patrones que van al backtracker:**

| Corpus | Al backtracker | Detalle |
|---|---|---|
| npm, F0c (7.690 únicos) | **≈ 2.144 (27,9 %)** | 306 T2 + 1.838 T1 no enrutados (de 2.087 T1, 249 van a la VM; casi todos los demás son `i` Unicode del paquete atípico: F5b) |
| npm, T2 por feature | 306 | lookahead 228 (699 ocurrencias), lookahead + backref 20, backref 24, **lookbehind 34 (59)** |
| F2c, sintético (40.636) | ≈ 18.300 (~50 %) | 36.753 compilan (conteo de `t1diff`), 18.435 van a la VM (`pfdiff`) |
| F2c, T2 (11.751) | | lookbehind 5.717, lookahead 2.555, backref 2.312, lookahead + backref 1.167 |

**LookLinear (npm):**
- 248 patrones con lookahead y sin lookbehind; 328 sitios.
- **297 sitios delegables** (sin capturas, backrefs ni lookarounds anidados; contados con regexpp).
- En 220 patrones (640 ocurrencias), **todos** sus lookaheads son delegables.

**`existsAnchoredMatch`:**
- Existe desde F4a (`src/tier0/pikevm.zig:260`, exportada en `tier0/root.zig:27`).
- `.backward` → `error.Unsupported` (261). `Budget` está en `src/utils/budget.zig`.
- **Sin wiring:** su único llamador es un test (`tests/t0_tests.zig:397–414`).
- `tier2` no puede importar `tier0`: tabla de capas en `build.zig:25`.

**Qué cambia con F6a:**
- `Regex.exec` no cambia.
- `Matcher.exec` elige el ejecutor por patrón: `recursive_matcher` si el patrón tiene lookbehind; el nuevo en otro caso.
- `tier2` gana la dependencia `tier0`.
- `tier2.Scratch` gana un `VmScratch` propio: el `vm` de `regex.Scratch` pertenece al camino T0 del mismo `exec`.

## H4. Bench del backtracker hoy

`zregex_xbench` ReleaseFast de `66a9d60`, 5 corridas, mediana (mín–máx):

| Caso | `execAt` MB/s | `findAll` MB/s | ns por exec corto | Compilación (µs) |
|---|---|---|---|---|
| `t2_backref` `<(\w+)>.*?<\/\1>` | 36,80 (36,08–36,96) | 32,22 | 360 | 4,06 |
| `t2_lookahead` `(?=.*[a-z])(?=.*[A-Z]).{8,}` | 3,91 (3,75–3,99) | 3,78 | 857 | 3,75 |
| `t2_lookbehind` `(?<=\$)\d+` | 0,78 (0,76–0,81) | 0,77 | 672 | 1,46 |
| `t2_book_backref` `\b(\w+) \1\b` | 10,73 (8,25–11,29) | 11,24 | 285 | 3,20 |
| `t0_az_bt` `[a-z]+` forzado a `.expert` | 38,86 | 25,33 | 113 | 1,09 |
| `t1_vset` (backtracker) | 27,13 | 16,29 | 198 | 15,40 |

**Adversariales en el backtracker:**

| Caso | Motor | Resultado |
|---|---|---|
| `(a+)+b` y `(a\|aa)*c` sobre a⁴¹ (sin match) | `.expert`, `probe` ReleaseFast | `StepLimitExceeded`: 25,5 ms (25,5–44,0) y 25,6 ms (24,9–26,5) |
| Los mismos | ReleaseSafe | 33 y 27 ms |
| Los mismos, sin forzar | Van a la VM tagged | "no match" en 2–6 µs |
| `adv_lookahead` `(?=(a+)+b)` sobre aⁿc | Backtracker | `StepLimitExceeded`: 24,5 ms (n = 25–40); 50,7 ms con n = 20 (primera corrida) |

**Binario** (`.so`, con strip):

| Build | Tamaño | `.text` |
|---|---|---|
| ReleaseFast | 940.720 B | 336.112 B |
| ReleaseSmall | 552.488 B | |

`RecursiveMatcherFor` (u8 + u16) ocupa **27,3 KB** de código en ReleaseFast; el resto de tier2 (codegen, bytecode, `matcher`), 14,3 KB; tier0, 15,5 KB.

## Plan de F6a

**Decisiones de diseño** (desviaciones del prompt, justificadas):
1. **D15 debe dar match `[0,0]`**, la respuesta del spec y el criterio del plan de fases (fila F6a), no `RecursionLimitExceeded`/`StepLimitExceeded`. El test `skip` de `tests/regression_tests.zig:185` se activa tal como está.
2. **Lookbehind:** los patrones con lookbehind siguen enteros en `recursive_matcher.zig` hasta F6b. Por eso `(?<!\$)` **no** se delega (`existsAnchoredMatch(.backward)` es `Unsupported` hasta F6b); el test de delegación usa `(?!\$)`, y otro test fija que `(?<!\$)` sigue en el matcher viejo.
3. **`max_steps` sigue siendo por posición de inicio**, como hoy. Por ejecución, el bench `t2_backref` (1 MiB, 46.806 matches) superaría 1M pasos.
4. **Parte 1 = exactamente el comportamiento actual** (`pfdiff --slots` idéntico). La Parte 2 cambia solo lo que el trail corrige a propósito: el bug F. Puede quitar divergencias de `differential-v8`; se clasifican una a una.

**Parte 1: pila explícita** (commit 1; estimación 2–3 días)
- **Nuevo `src/tier2/executor/backtrack.zig`, `BacktrackerFor(Unit)`**:
  ```zig
  const Kind = enum(u8) { alt, star_greedy, star_lazy, look, restore };
  const Choice = struct {        // 40 B
      kind: Kind,
      pc: u32,        // alt: pc2 · star: pc_rest · look: pc tras LOOKAHEAD_END · restore: slot
      guard_h: u32,   // altura de `guards` al empujar
      pos: usize,     // alt: pos · star_greedy: índice en `positions` · star_lazy: pos actual · look: pos de entrada
      a: usize,       // star_greedy: marca inferior en `positions` · star_lazy: pc del átomo · look: altura de la pila · restore: prev.start
      b: usize,       // look: negativo (bit) + marca de `snapshots` · restore: prev.end
  };
  ```
- **Bucle `run(pc0, pos0)`:** `while (true)` con `switch (opcode)`.
  - Un átomo que casa avanza `pc`/`pos`; si no, `fail`.
  - `SPLIT` (alternancia u opcional): `push(alt, pc2, pos)` y sigue en `pc1`.
  - Un salto hacia atrás pasa por `guard(target, pos)`: si ya está en `guards`, falla; si no, lo empuja.
  - `*` simple: llena `positions` como hoy (909–932) y empuja un único `star_greedy`; el `lazy` empuja `star_lazy`.
  - `SAVE_*`/`CLEAR_CAPTURE`: `push(restore, slot, prev)` y escribe.
  - `LOOKAHEAD`: copia los slots a `snapshots` (como hoy), `push(look)` y entra al cuerpo.
  - `LOOKAHEAD_END`: la barrera `look` más interna (índice guardado en `look_top`).
    - Positivo: la pila se trunca a `a` (se descartan los `restore` del cuerpo: es el comportamiento actual, bug F incluido) y se sigue en `pc`/`pos` de la barrera.
    - Negativo: restaura `snapshots`, trunca y falla.
  - `fail`: desapila.
    - `restore`: escribe `prev` y sigue desapilando.
    - `alt`: reanuda.
    - `star_*`: siguiente posición, o se desapila.
    - `look` alcanzado por un fallo: positivo → restaura y sigue fallando; negativo → restaura y continúa tras el END.
    - `guards` se trunca a `guard_h` en cada reanudación.
- **Límites:**
  - `steps += 1` por instrucción, lo mismo que hoy por `matchFrom`;
  - `bytes = stack.len·40 + positions.len·8 + guards.len·16 + snapshots.len·16`, y `> max_backtrack_stack_bytes` da `error.BacktrackStackExhausted`.
- **Estado en `tier2.Scratch`** (`recursive_matcher.zig:94`, compartido): `stack`, `guards`; `positions` y `snapshots` se reutilizan.
- **`ExecLimits` propio** en `src/regex.zig:83`: `{ max_steps = 1_000_000, max_backtrack_stack_bytes = 64 MiB, max_memo_bytes = 1 MiB }`.
  - `recursive_matcher` (lookbehind) recibe `ExecOptions{ .max_recursion_depth = 1000, .max_steps }`.
  - `BacktrackStackExhausted` entra en `ExecError`; en `src/c_api.zig:98` se mapea a `ZREGEXP_ERROR_RECURSION_LIMIT`. Siguen 40 símbolos y el struct de opciones C no cambia.
- **`matcher.zig:174`:** `if (self.has_lookbehind) RecursiveMatcherFor else BacktrackerFor`. `has_lookbehind` se calcula al compilar, recorriendo el bytecode (`LOOKBEHIND`/`NEGATIVE_LOOKBEHIND`).
- **Tests** (`tests/regression_tests.zig`, `tests/tier2_pipeline_tests.zig`):
  - D15 sin `skip`;
  - `()\1{1000}` con 1 KiB de presupuesto → `BacktrackStackExhausted`;
  - D14 en hilos de 64 KiB, 1 MiB y 8 MiB;
  - los cuatro casos de bucle largo de H2 → match, contra V8;
  - `(a+)+b` y `(a|aa)*c` en `.expert` → `StepLimitExceeded`;
  - un test por cada bug de Phase 6 del índice (`regression_tests.zig:10–22` y `:43`), con `force_tier = .expert`. Hoy, los que son T0 solo prueban la VM en `src/regex.zig`.
- **Archivos:**
  - nuevos: `src/tier2/executor/backtrack.zig`;
  - cambiados: `matcher.zig`, `recursive_matcher.zig` (solo el `Scratch`), `src/tier2/root.zig`, `src/regex.zig`, `src/main.zig`, `src/c_api.zig`, `src/compile.zig` (`has_lookbehind`), los tests;
  - docs: `docs/F6A_PRECHECK.md` (este documento).

**Parte 2: trail** (commit 2; estimación 1 día)
- Fuera `restore` y `snapshots`:
  - `trail: [](struct { slot: u32, prev: CaptureGroup })`, 24 B por entrada;
  - `Choice.b` pasa a ser `trail_h`;
  - `SAVE_*`/`CLEAR_CAPTURE` empujan al trail;
  - `fail` deshace hasta `trail_h` del choicepoint que reanuda.
- **Lookahead:**
  - positivo con éxito: trunca la pila de choicepoints y **conserva el trail**, así que un fallo posterior deshace sus capturas (corrige el bug F);
  - negativo: deshace hasta la altura de entrada siempre.
- **Tests:** los tres casos del bug F contra V8; el resto de las capturas de lookahead (fuga en positivo y ninguna en negativo, `regex.zig` "negative lookahead's own captures"); Phase 6 en `.expert`.
- **Archivos:** `backtrack.zig`, tests y `KNOWN_LIMITATIONS.md` (bug F corregido).

**Parte 3: LookLinear, memo y límites públicos** (commit 3; estimación 2 días)
- **Capas:** `build.zig:25`, `tier2.deps` += `"tier0"` (hacia abajo). Canario de `check-layers`: `tier0` sigue sin poder importar `tier2` (`build.zig:107`).
- **Compilación:**
  - `CodeGenerator.generateLook` (`src/tier2/codegen/generator.zig:678–693`) anota `(pc del LOOKAHEAD, *const hir.Node del cuerpo)` en `self.look_sites`; el bytecode no cambia (snapshot idéntico);
  - `compile.zig`: para cada sitio forward con `tier0.check(body) == null` (`src/tier0/compile.zig:56`), `tier0.compile` del cuerpo con los flags del scope (el mismo camino que `route()` usa para el patrón entero);
  - `CompileResult.linear: []LinearSite{ pc: u32, prog: tier0.Program }`, liberado en `deinit`.
- **Ejecución:**
  - en `LOOKAHEAD`/`NEGATIVE_LOOKAHEAD` con sitio lineal: `r = memo[site][pos] orelse tier0.existsAnchoredMatch(&prog, subj, mode, pos, .forward, &scratch.look_vm, &budget)`;
  - `budget` envuelve el contador de pasos: `Budget.init(max_steps - steps)`, y al volver se descuenta lo gastado;
  - la memo son 2 bits por posición (§4.4), reservada en `Scratch` al primer uso; sin memo si `⌈(n+1)/4⌉ > max_memo_bytes`;
  - después, `r != negated ? continuar en pc tras END : fail`; sin trail ni barrera.
- **`CompileOptions.t2_look_linear: bool = true`**, solo para tests y bench, como `t0_prefilters`.
- **Test del interruptor en las dos direcciones** (uno por valor, sobre el mismo patrón `(?=\d{3})\d+` y el mismo sujeto):
  - con `true`: `linear.len == 1` y el contador de delegaciones del Scratch > 0 tras ejecutar;
  - con `false`: `linear.len == 0` y el contador queda en 0 (el lookahead lo evalúa el backtracker);
  - los dos dan los mismos slots.
  - Si el interruptor no hiciera nada, falla uno de los dos.
- **Tests:**
  - `(?=\d{3})`, `(?=foo)` y `(?!\$)` delegados (`re.compiled.linear.len` y un contador de delegaciones en el Scratch), con el mismo resultado que con `t2_look_linear = false`;
  - no delegados: `(?=(a))`, `(?=\1)`, `(?=(?=a))` y `(?<!\$)`;
  - memo con `max_memo_bytes = 0` → mismo resultado;
  - `StepLimitExceeded` desde la VM con `max_steps` pequeño;
  - 0 asignaciones con el Scratch caliente.
- **Archivos:** `build.zig`, `generator.zig`, `compile.zig`, `backtrack.zig`, `matcher.zig`, `recursive_matcher.zig` (el `Scratch`), `regex.zig`, tests; docs (plan: D11, D14 y D15 cerrados, tabla de capas; `KNOWN_LIMITATIONS` sección F6a; README `ExecLimits`).

## Gate (cada commit)
- `zig build test` en Debug y ReleaseSafe (incluye la corrida `-Dforce-backtracker`), `check-layers` y fuzz de estrés en los dos modos.
- test262 en UTF-16 y WTF-8: 2974, 0 regresiones.
- `differential-v8` contra `diff-F5a.json`: 0 nuevas; las que desaparezcan, clasificadas.
- `pfdiff` modo por defecto y `--slots <archivo>` (esta vez con la salida explícita): Parte 1 idéntica a `66a9d60` (416 de límites, 52 patrones de slots, `bt_right` 0); Partes 2–3 sin `bt_right`.
- `t1diff`: 11.
- Probe H2 repetido.
- **Bench**, solo en la Parte 3 (o antes si la Parte 1 lo pide): 10 rondas intercaladas contra un worktree de `66a9d60`, ~15 min, aviso antes. Casos: los T2, `t0_az_bt`, `t1_vset` y los adversariales `.expert`. Criterio: ninguno > 20 % peor; los adversariales dan `StepLimitExceeded` en ±20 % del tiempo de hoy (~25 ms).
- Binario `.so` en ReleaseFast y ReleaseSmall por commit. Previsión: +15–25 KB mientras conviven los dos ejecutores (hasta F6b).
- `ps` con 0 procesos vivos al final.

Reporte por commit; parada al cerrar F6a.
