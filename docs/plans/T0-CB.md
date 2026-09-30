# T0-CB: Shift-And (C) y literal interior (B) — precheck y plan

Precheck sobre `da7d12e` (J incluido). No se tocó `src/`. Todas las cifras salen de un prototipo en el scratchpad:
- una copia `git archive` del repo con C y B añadidos en `tier0/prefilter.zig` y `tier0/pikevm.zig` (~200 líneas);
- una sonda que compila contra esa copia y contra la base sin cambios.

Es un prototipo de medida, no la implementación. Las **estimaciones** se marcan como tales; el resto está medido.

## 1. Resumen
- **Resultados** (tiempo real, 10 rondas intercaladas del harness del bench, la mejor por caso):

  | Caso | Ruta | Ganancia |
  |---|---|---|
  | `\d{3}-\d{4}` denso | C | **12,6×** (45,4 → 571,7 MB/s) |
  | `(\d{3})-(\d{4})` denso | C, más el pase etiquetado | **3,7×** |
  | e-mail | B | **4,5×** (58,0 → 261,1 MB/s) |

  El e-mail queda por debajo de lo estimado en el informe anterior (10-20×): ver §4.
- **Exactitud:** 0 diferencias frente a la base en los 28.563 programas de la VM de los tres corpus. Son 34,2 M de `execAt` desde cada índice, en WTF-8 y UTF-16, con grupos y con `u`/`v`.
- **C y B se solapan:** 485 programas cumplen los dos (§3). C tiene prioridad.
- **Hallazgos que el plan corrige:**
  1. **B necesita una regla de selección.** Sin ella, en `(Mr|Mrs|Miss)\.? ([A-Z][a-z]+)` elige `' '` en lugar del memchr de `M`, y es **4× más lento**. La regla medida es no usar B cuando `first` ya es un solo byte.
  2. **B necesita el «prefijo mínimo».** Con 1 MiB de solo `@`, B costaba 233 instrucciones por byte frente a las 7 de `first`. Con la regla, 68. Sigue siendo lineal en todos los casos.
  3. **El prototipo cobra +2,9 % de instrucciones** a los patrones que no cambian de ruta. En tiempo real sale un 0,86× en `book_word`/`book_title`: la comprobación extra en `Vm.search` más un efecto de colocación del código. La implementación debe especializar `search` por estrategia en `comptime`.
- **Recomendación:** C primero y B después, en **dos commits con dos gates**. Estimación: C 3-4 días y B 4-5 días, **~1,5-2 semanas** en total (estimación).

## 2. Precheck: dónde encajan
- **El despacho:**
  - `pikevm.exec` (`src/tier0/pikevm.zig:197`) despacha según `Prefilter.Kind`;
  - `literal` y `class_run` son rutas completas que no tocan `VmScratch` (el invariante de `prefilter.zig`);
  - `first` es un salto dentro de `Vm.search` que solo se usa cuando no hay hilos vivos y aún no hay match;
  - `prefilter.analyze` (`prefilter.zig:97`) elige la ruta con este orden: `literal`, `class_run`, `first`;
  - todo esto solo en modo code unit: con `u`/`v` corre la VM sin prefiltros.
- **Las capturas no se rechazan.** `execCaptures` (`pikevm_tagged.zig:56`) pide los límites a `pikevm.exec` y después corre la VM etiquetada solo sobre `[s, e]`. Una ruta nueva en `exec` sirve también a los patrones con grupos:
  - por C van 19, 89 y 70 programas etiquetados (f2c, f2c-2 y npm);
  - por B, 135, 644 y 216.
- **C** es una ruta completa (`shift_and`), como `class_run`. **B** es un salto nuevo (`inner`) en el mismo punto de `Vm.search` que `first`. Ninguno pasa por `buildClosures`.

## 3. Solapamiento y conteos (corpus)
Programas de la VM en modo code unit (sin `u`/`v`). La prioridad del prototipo es `literal` > `class_run` > **C** > **B** > `first`.

| | f2c | f2c-2 | npm |
|---|---|---|---|
| programas en code unit | 3.603 | 13.498 | 7.108 |
| **C** (predicado §4.1) | **235 (6,5 %)** | **672 (5,0 %)** | **495 (7,0 %)** |
| de ellos, con grupos | 19 | 89 | 70 |
| **B** cumple el predicado (§5.1) | 896 | 4.160 | 884 |
| **B** elegido (C no aplica y `first` no es un solo byte) | **409 (11,4 %)** | **1.909 (14,1 %)** | **291 (4,1 %)** |
| de ellos, con grupos | 135 | 644 | 216 |
| **C ∩ B** (cumplen los dos) | 78 | 301 | 106 |

- **Forma de la intersección:** líneas rectas de longitud fija con un carácter interior que no está en lo anterior. Ejemplos: `\d{3}-\d{4}`, `b{2}c`, `ab[ercst]de`, `a(bc)d(ef)g`, `comment[134]`, `;base64` con `i`.
  - Van a C, que es mejor en los dos extremos: en denso, B sería malo porque `-` aparece cada ~4 bytes; en disperso, C ya da 1,28×.
  - No hay patrones que B sirva mejor que C dentro de la intersección, salvo un literal muy raro en un texto largo. Eso no se midió.
- **Casi-C** (medido, no incluido):

  | Falla por | f2c | f2c-2 | npm |
  |---|---|---|---|
  | sets o chars no ASCII (`.`, `[^x]`, `\D`, `\S`) | 693 | 1.852 | 314 |
  | asserts (casi todos en los extremos: `^…$`, `\b…\b`) | 80 | 260 | 986 |
  | `m > 64` | 2 | 2 | 0 |

  Se ve en §8 como ampliación.
- **Con `u`/`v`** (excluidos): cumplirían C 100, 212 y 21 programas, y B 121, 495 y 65.
- **Distribución de `m`** en C:

  | `m` | f2c | f2c-2 | npm |
  |---|---|---|---|
  | 1 | 130 | 251 | 222 |
  | 2-8 | 77 | 305 | 199 |
  | 9-16 | 22 | 91 | 58 |
  | 17-32 | 1 | 20 | 10 |
  | 33-64 | 5 | 5 | 6 |

## 4. C: Shift-And

### 4.1 Predicado exacto
Se evalúa sobre el `Program` de T0 ya compilado, no sobre el HIR. El compilador ya ha bajado `i`, los scopes, `x{n}` y las clases, así que el predicado ve lo que la VM ejecuta:
- `insts = [char | set | save | clear]* match`: sin `split`, `jmp`, `assert` ni `fail`;
- cada `char` es menor que 0x80, y cada `set` es no vacío con su último rango por debajo de 0x80 (solo miembros ASCII);
- `m` = número de `char`/`set`, con `1 ≤ m ≤ 64`;
- modo code unit (sin `u`/`v`): la comprobación ya está en `exec` (`use_pf`);
- no es `literal` ni `class_run`, que van antes en `analyze`.

**Equivalente en HIR:** la raíz, tras el `modifier_scope`, es:
- un `seq` de literales ASCII (sin `i` sobre letras no ASCII), de `char_set` con todos sus miembros ASCII, de `repeat{n,n}` de esos o de `capture` de esos;
- sin `alt` (aunque sus ramas midan lo mismo), sin asserts, sin lookaround y sin backrefs.

### 4.2 Diseño
- **Estado:** un `u64` y un bit por posición del patrón (`m ≤ 64`, así que un solo registro).
- **Tabla:** `masks[u]` para `u < 128`, 128 × 8 B = 1 KiB en el heap, liberada en `Prefilter.deinit` como la de `literal`.
- **Unidades no ASCII:** una unidad ≥ 0x80 (byte en WTF-8, unidad en UTF-16) tiene máscara 0. Así un match nunca incluye una y siempre empieza en una posición.
- **Bucle:** `d = ((d << 1) | 1) & mask[u]`; si `d & (1 << (m−1)) != 0`, hay match `[i+1−m, i+1]`.
- **Corte:** se para en el primer bit `m−1` que aparece.
- **`sticky`:** se comparan las `m` unidades en `index`.
- **Patrones de más de 64 posiciones:** no entran en C y siguen en la VM. En el corpus son 4 programas (2 + 2 + 0), así que no hace falta Shift-And multipalabra.
- **Dónde vive:**
  - la tabla y el predicado (`shiftAndOf`) en `prefilter.zig`;
  - el ejecutor en `pikevm.zig`, junto a `classRun`;
  - no hace falta un archivo `shiftand.zig`: son ~40 líneas de predicado y ~25 de ejecutor.
- **Sin registro en `buildClosures`:** es un ejecutor aparte, como `class_run`.
- **Salto inicial:** no se implementó. El bucle ya son ~4 instrucciones por byte; con estado 0, un salto por `mask[u] & 1` solo ayudaría en textos dispersos. Queda como opción medible.

### 4.3 Semántica
- **Leftmost-first:**
  - el programa es una línea recta sin `split`, así que tiene un solo camino y todo match mide exactamente `m` unidades;
  - entre matches de la misma longitud, el leftmost-first de la VM es el de menor inicio, y el de menor inicio es el de menor fin;
  - Shift-And encuentra el menor fin, así que el primero que encuentra es el de la VM.
- **Matches sin solapamiento:** `execAt` devuelve el primer match desde `index`; el que itera avanza hasta el final del match, como hoy.
- **Capturas:** aceptadas; C da los límites y la VM etiquetada rellena los grupos sobre el tramo.
- **Iteración vacía:** imposible, porque no hay bucles y `m ≥ 1`.
- **`u`/`v`:** excluidos, como el resto de prefiltros. Con `u`+`i`, `\w` incluye U+017F y U+212A, que dejan de ser ASCII.
- **UTF-16:** en modo code unit cada unidad es un carácter; las unidades ≥ 0x80 tienen máscara 0.

### 4.4 Medido
Instrucciones por byte con callgrind (256 KiB, bucle de `execAt`, sin el arranque) y tiempo real con el harness del bench:

| Caso | Instr./byte base → C | Tiempo real |
|---|---|---|
| `\d{3}-\d{4}` denso | 271,5 → **20,8** (13,1×) | 45,4 → 571,7 MB/s (12,6×) |
| `(\d{3})-(\d{4})` denso | 349,1 → 98,4 (3,5×) | 34,8 → 128,3 MB/s (3,7×) |
| `\d{3}-\d{4}` disperso | 20,9 → 15,2 | 1,28× |
| `(\d{3})-(\d{4})` disperso | — | 1,16× |

- **Denso:** las 20,8 instrucciones por byte incluyen `execAt` por match (30.810 matches por MiB). Quedan por debajo de las 70,4 de Rust medidas en el informe anterior.
- **Con grupos:** lo que queda es el pase etiquetado sobre cada tramo.

## 5. B: literal interior

### 5.1 Predicado exacto (sobre el `Program`)
Existe un pc `L` con `char c`, `c < 0x80`, tal que, recorriendo desde el pc 0 todas las aristas sin entrar en `L`:
1. no se alcanza `match`: todo match pasa por `L`, así que el literal es obligatorio y ninguna alternancia lo esquiva;
2. ningún `char`/`set` alcanzado acepta `c`;
3. se alcanza al menos un `char`/`set`: el prefijo no es vacío.

Además:
- **C:** la unión de lo que aceptan esos `char`/`set`, guardada como tabla conservadora como la de `First` (en WTF-8, cualquier miembro ≥ 0x80 marca todos los bytes ≥ 0x80; en UTF-16, `high`);
- **`min_prefix`:** el mínimo de unidades consumidas del pc 0 a `L`;
- **condiciones:** sin `^` inicial (`anchored`), modo code unit y tamaño ≤ `max_scan` (4096), como `first`.

**Regla de selección** (medida en §5.4): no usar B cuando `first` es un solo byte (`single8`), porque su memchr ya es mejor.

**Equivalente en HIR:** raíz `seq` con un literal ASCII `c` en el nivel superior, y un prefijo cuyos caracteres posibles no incluyen `c`. En el `Program` el predicado cubre además los prefijos con alternancias, capturas, asserts (se atraviesan) y repeticiones.

### 5.2 Diseño
**Salto `inner`** en `Vm.search`, en el mismo punto que `first`, solo con la lista vacía, sin match y sin `sticky`:
1. se busca con memchr la primera aparición `p` de `c` a partir de `pos`;
2. se retrocede sobre las unidades de C hasta `s = max(inicio del tramo, pos)`;
3. si `p − s < min_prefix`, ningún match usa esta aparición y se pasa a la siguiente;
4. si no, `pos = s` y la VM sigue como siempre: siembra en cada posición mientras haya hilos y se detiene en el primer match.

**Caché:** se guardan `(p, s)`. Mientras `p ≥ pos`, cada salto siguiente es O(1): no se vuelve a hacer memchr ni a retroceder.

**Literal:**
- una unidad, `std.mem.indexOfScalarPos`;
- un literal de 2 o más unidades (`b_literal_run_ge2`: 537, 2.466 y 513) podría usar `findLiteral`, que es SIMD. No se prototipó.

**Qué literal elegir:**
- el prototipo toma el primero que cumple, en orden de pc;
- 576, 2.629 y 546 programas tienen más de un candidato;
- elegir el menos frecuente necesita una tabla de rangos por byte, como la de `memchr` de Rust. El `@` del e-mail es el único candidato.
- **Queda por medir en la implementación.**

**Relación con los otros prefiltros:** sustituye a `first` en esos programas, porque `Kind` es una unión. Orden en `analyze`: `literal`, `class_run`, C, B (si `first` no es un solo byte), `first`.

### 5.3 Semántica
- **Leftmost-first. Prueba de que el salto no pierde ningún match:**
  - sea `p` la primera aparición de `c` en `≥ pos`, y un match que empieza en `t ≥ pos`;
  - por (1) contiene una primera visita a `L`, que consume una aparición `p' ≥ t` de `c`;
  - por (2), las unidades de `[t, p')` están en C, y `c` no está en C;
  - si `p' > p` y `t ≤ p`, `[t, p')` contendría `p`, lo cual es imposible; luego, o `t > p`, o bien `p' = p` y `t ≥` el inicio del tramo, es decir `t ≥ s`;
  - así que ningún match empieza en `[pos, s)`;
  - con la regla del prefijo mínimo: si `p − s < min_prefix`, un match con `p' = p` necesitaría `t < s`. Todos los demás empiezan después de `p`.
- **El primer `@` que produce match:** la VM desde `s` es la misma VM de siempre, así que devuelve el leftmost-first entre los matches que empiezan en `≥ s`. Por lo anterior, es el leftmost-first en `≥ pos`.
- **WTF-8:** `s` siempre es una posición:
  - si C es solo ASCII, `s` es un byte ASCII;
  - si no, la tabla marca todos los bytes ≥ 0x80, así que el retroceso para tras un byte ASCII o en `pos`.
- **Capturas:** aceptadas. B solo cambia desde dónde busca la VM de límites.
- **Iteración vacía:** B no la toca; la VM la trata como hoy. Un prefijo anulable da `min_prefix = 0` pero con C no vacío; el predicado (3) solo pide que se alcance algún carácter.
- **`u`/`v`:** excluidos. **UTF-16:** la tabla tiene 256 entradas más `high`.
- **Diferencial:** 0 diferencias (§1), incluidos sujetos con `@@@`, `a@`, `a@b.c@d` y `é@é.é`.

### 5.4 Medido
Instrucciones por byte con callgrind (256 KiB):

| Caso | Base | B | Tiempo real (bench) |
|---|---|---|---|
| e-mail | 214,9 | **45,3** (4,7×) | 58,0 → 261,1 MB/s (4,5×) |
| `(?:(a)\|b)*c` (ab_runs) | 629,9 | 525,6 | 1,22× |
| `(Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+)` sin la regla de selección | — | — | 751 → 180 MB/s (**0,24×**) |
| el mismo con la regla (se queda en `first`) | 21,7 | 22,3 | 0,86× (§6) |

**Por qué el e-mail da 4,5× y no 10-20×:**
- el 88 % de lo que queda es la VM sobre el tramo de cada dirección: desde el inicio del usuario hasta el final del dominio, ~50 bytes de cada ~144 (un `@` cada 143,6 bytes);
- B quita el texto entre direcciones, pero no abarata la VM sobre la dirección;
- bajar más exige abaratar la VM (la opción D) o un DFA (A).

### 5.5 Adversariales (patrón del e-mail, 256 KiB, instrucciones por byte)

| Entrada | Base (`first`) | B sin prefijo mínimo | B final |
|---|---|---|---|
| `a@a@a@…` | 265,0 | — | 281,5 (+6 %) |
| `aaaaaaa@b…` | 307,8 | — | 324,7 (+5,5 %) |
| solo `@` | **7,0** | 233,0 | **68,0** |
| solo `a` (sin `@`) | 217,0 | — | 0,2 |
| 1 MiB de `x` y `@y.` al final | 217,0 | — | 0,2 |
| `[ab]+@[^\n]*z` sobre `a@a@…` (sufijo que cruza todos los `@`) | 306 | — | 323 (+5,5 %) |

- **¿Cuántos `@` puede haber en un MiB?** Hasta 1.048.576 (todos los bytes). El bench tiene 7.168.
- **Linealidad sin tope:**
  - los retrocesos son disjuntos, porque cada uno para en la aparición anterior (que no está en C);
  - el caché hace O(1) cada salto sobre la misma aparición;
  - la VM es la misma VM lineal, que corre de forma continua mientras haya hilos y no reinicia en cada `@`;
  - por eso no hace falta un máximo de `@` a probar.
- **El caso cuadrático de Rust** (un DFA inverso por aparición que retrocede hasta el principio) no existe aquí: el retroceso no pasa de la aparición anterior.
- **Peor caso medido:** «solo `@`», 68 instrucciones por byte frente a 7 de `first`, por el coste de una llamada a memchr por byte. Está por debajo del peor caso de la VM de hoy (~270). Se puede bajar comprobando el tramo en línea antes del memchr. Queda para la implementación.

## 6. Riesgos de hacerlos juntos
- **Funciones compartidas:** `Prefilter.Kind`, `analyze` (el orden), `Prefilter.deinit` y el `switch` de `exec`. C y B añaden cada uno una variante y una rama.
- **Solo B toca `Vm.search`:** su firma y la comprobación del salto. Es el bucle caliente de toda la VM, también para patrones que no usan B.
- **El pipeline:** un cambio en `search` afecta a todo lo que corre en la VM; C no pasa por `search`.
- **El coste medido del prototipo en patrones que no cambian de ruta:**
  - +2,9 % de instrucciones en `book_word` y `book_title` (los dos `first`, que no cambian);
  - +3,9 % en `[a-z]+` (`class_run`), que ni pasa por `search`: el `switch` de `exec` más grande y el inlining;
  - en tiempo real, 0,86× en `book_word`/`book_title` y 0,89× en `t0_az_vm`, por encima del criterio del 10 % de F7c-6.

  Callgrind confirma que el coste en instrucciones es real, aunque menor que en tiempo. La implementación debe:
  - pasar la estrategia de salto a `search` como parámetro `comptime` (una instancia por estrategia), para que `first` y `none` no paguen la comprobación de B;
  - revisar el despacho de `exec`.
- **Atribución en el gate:**
  - con dos commits y dos gates, cualquier regresión en el bench o en los diferenciales cae en uno solo;
  - con un gate único para los dos, el diferencial seguiría siendo exacto (0 diferencias en cada uno), pero una regresión de rendimiento como la de arriba no se podría atribuir sin re-medir por separado.
- **Tests que cambian:** fijan la ruta elegida (esperado):
  - `prefilter.zig`: «literal: when it applies and when it doesn't» y «first: nullable patterns and non-ASCII members» (`\béx` pasa a B);
  - `t0_tests`: «prefilters: which one each pattern gets».

  El resto de tests pasa en el prototipo: 879 de 895, con 13 omitidos y esos 3.
- **Binario** (prototipo, `measure_binary.sh`): ReleaseFast 1.112.880 → 1.116.672 (+3.792 B), ReleaseSmall 704.792 → 707.496 (+2.704 B), 40 símbolos.
- **Memoria por `Program`:**
  - C, 1 KiB en el heap;
  - B, ~520 B dentro de la unión, el mismo tamaño que `First`, que ya ocupa esa variante.

## 7. Orden, estimación y commits
- **Recomendación: C primero y B después, con un gate por commit.**
  - **C es autocontenido,** como `class_run`: no toca `Vm.search`, su predicado es una línea recta, y da la mayor ganancia (12,6×) con el menor riesgo.
  - **B toca el bucle caliente** y necesita la especialización en `comptime`, la regla de selección y la regla del prefijo mínimo. Su gate debe volver a medir el bench completo para confirmar que los casos `first` y `none` recuperan el 1,00×.
- **Estimación** (a partir del prototipo):

  | Opción | Estimación |
  |---|---|
  | C: predicado, ejecutor, tests de forma y de límites (con grupos, UTF-16, `sticky`), docs, gate | 3-4 días |
  | B: predicado, `min_prefix`, `search` especializado en `comptime`, regla de selección y su bench, tests (adversariales incluidos), docs, gate | 4-5 días |
  | Juntos, en dos commits y dos gates | **~1,5-2 semanas** |
  | Juntos en un solo commit y un solo gate | ~1 día menos; se pierde la atribución |

- **Commits propuestos:**
  1. `tier0: Shift-And fast path for fixed ASCII sequences (C)`
  2. `tier0: skip to the run before a required inner literal (B)`
- **El gate de cada uno:**
  - los mismos pasos que J: Debug y ReleaseSafe, check-layers, gate.sh GATE-PASS, fmt=0, fuzz, test262 2994 y `measure_binary`;
  - los diferenciales sin cambios: pfdiff con slots idénticos, t1diff, lldiff, dv8, lbdiff e ivdiff;
  - el diferencial propio de este precheck;
  - el bench con 10 rondas intercaladas.

## 8. Fuera de alcance (medido, para después)
- **C con miembros no ASCII:**
  - 693, 1.852 y 314 programas;
  - en UTF-16 funcionaría tal cual (una unidad por carácter);
  - en WTF-8 no, porque la longitud en bytes deja de ser fija.
- **C con asserts en los extremos** (`^…$`, `\b…\b`):
  - 75, 220 y 984 programas; en npm son sobre todo validadores anclados;
  - los anclados ya solo prueban la posición 0, así que la ganancia sería pequeña.
- **B:**
  - literal de varias unidades con `findLiteral`;
  - el literal más raro con una tabla de frecuencias;
  - el caso «solo `@`» sin llamar a memchr por byte.
- **El e-mail más allá de 4,5×:** abaratar la VM (D) o un DFA (A), del informe anterior.

## 9. Resultado de C (implementado)
- **Código:** `src/tier0/shiftand.zig` (predicado `of`, `ShiftAnd.find` y tests); registro en `prefilter.analyze` después de `class_run`; la ruta en `pikevm.exec`.
- **Tabla:** 128 × `u64` (1 KiB). Las unidades desde 0x80 tienen máscara 0, así que no hay vuelta a la VM: el resultado ya es exacto.
- **Programas por la ruta nueva:** 235, 672 y 495 (f2c, f2c-2 y npm), de ellos 19, 89 y 70 con grupos. Son los del precheck.
- **Diferencial propio** (base `da7d12e` frente a C): 28.563 programas y 34,2 M de `execAt`, 0 diferencias.
- **Bench** (10 rondas intercaladas, la mejor por caso):
  - `\d{3}-\d{4}` denso: 45,5 → 557,3 MB/s (**12,25×**);
  - `(\d{3})-(\d{4})` denso: 34,5 → 124,7 MB/s (**3,62×**);
  - el resto de los casos, entre 0,94× y 1,05×, salvo los dispersos, que mejoran (1,14× y 1,26×). El 0,86× del prototipo en `book_*` venía de B, no de C.
- **Binario:** ReleaseFast 1.114.432 B (+1.552), ReleaseSmall 706.040 B (+1.248), 40 símbolos.
- **Herramientas:** `tools/pfdiff.zig` dimensionaba su contador por tipo de prefiltro con un 4 fijo (panic con la variante nueva), y `bench/bench.zig` tenía un `switch` exhaustivo. Las dos se adaptan en el mismo commit.

## 10. Resultado de B (implementado)
- **Código:**
  - `prefilter.Inner`, `innerOf`, `innerAt` y `minPrefix` en `src/tier0/prefilter.zig`, registrados en `analyze` después de C;
  - el salto `InnerSkip` en `src/tier0/pikevm.zig`.
- **`Vm.search` recibe el salto como tipo en compilación:** hay una instancia sin salto, otra con `first` y otra con `inner`. Así un patrón sin B no paga la comprobación en cada posición, que era el +2,9 % del prototipo.
- **Selección del literal:** el candidato menos común según un rango grueso por clases de byte (`commonness`: controles < puntuación rara < dígitos, mayúsculas y puntuación común < minúsculas < espacio). No es una tabla medida. En empate gana el primero en el programa, y se prueban a lo sumo 32 candidatos.
- **Regla de `first`:** sin B cuando `first` es un solo byte.
- **Prefijo mínimo:** una búsqueda 0-1 sobre el programa; el salto descarta un literal cuyo tramo es más corto.
- **Programas por la ruta nueva:** 408, 1.906 y 290 (f2c, f2c-2 y npm), de ellos 135, 642 y 215 con grupos. El precheck daba 409, 1.909 y 291; la diferencia es el tope de 32 candidatos.
- **Diferencial propio** (base `da7d12e` frente a C+B): 28.563 programas y 34,2 M de `execAt`, 0 diferencias.
- **Bench frente a C** (10 rondas intercaladas, la mejor por caso): e-mail 58,6 → 286,5 MB/s (**4,89×**).
- **Casos de no regresión** (callgrind, instrucciones sin el arranque):

  | Caso | Instrucciones | Tiempo real |
  |---|---|---|
  | `book_word` | −3,6 % | 1,13× |
  | `book_title` | −1,3 % | 0,97× |
  | `[a-z]+` | 0,0 % | 0,94× |

- **Adversariales** (instrucciones por byte, base → B):

  | Entrada | Base | B |
  |---|---|---|
  | `a@a@…` | 265,0 | 269,5 |
  | `aaaaaaa@b…` | 307,8 | 312,7 |
  | solo `@` | 7,0 | 69,0 (peor caso, lineal) |
  | sin `@` | 217,0 | 0,2 |

- **Binario:** ReleaseFast 1.130.080 B (+15.648 frente a C) y ReleaseSmall 715.560 B (+9.520), con 40 símbolos. Casi todo son las tres instancias de `search` por tipo de unidad.
