# T0-A precheck: DFA completo al compilar

Precheck sobre v0.7.1 (`49b3634`). No se tocó `src/`. El prototipo vive en el scratchpad (`dfaprobe`): una sonda que compila contra el repo e importa `zregex.internal.tier0`. Contiene:
- el alfabeto de clases;
- el DFA hacia delante con contexto para los asserts y su versión anclada;
- el DFA inverso;
- la ejecución de `(inicio, fin)`.

Las cifras son medidas salvo las marcadas como estimación.

**Resultado:**
- **El diseño es correcto:** 0 diferencias en 66,9 M de ejecuciones.
- **P6 no cumple el umbral:** en el e-mail, el ejecutor del prototipo da 0,50× (0,87× con el salto de B) frente a la VM actual. Según la regla del encargo, **el precheck se para aquí**.
- **P1 tampoco cumple su criterio:** construir el DFA cuesta el 177-294 % (mediana) del `compile()` actual.
- **Lo que falta:** un segundo prototipo con un ejecutor ajustado, y decidir cuándo se construye el DFA (§1 y §6).

## 1. Coste de compilación
**Cómo se midió:** por programa de T0 de los tres corpus, la mejor de 20 repeticiones de `Regex.compileWithOptions` frente a la mejor de 5 de la construcción del DFA (clases, ida sin anclar y anclada, e inverso), en µs.

| | f2c | f2c-2 | npm |
|---|---|---|---|
| `compile()` p50 / p99 / máx. | 2,69 / 19,2 / 279 | 2,65 / 15,5 / 470 | 3,04 / 40,6 / 968 |
| DFA p50 / p99 / máx. | 4,29 / 305 / 2.500 | 4,84 / 295 / 7.814 | 8,23 / 567 / 399.483 |
| DFA / `compile()` por patrón p50 / p90 | 177 % / 560 % | 189 % / 572 % | 284 % / 620 % |
| suma DFA / suma `compile()` | 555 % | 574 % | 3.770 % |

- **Desglose** (f2c-2, mediana): clases 1,78 µs, ida 1,80 µs, inverso 0,69 µs.
- **Qué afecta a este constructor:** es de prototipo (mapas hash, copias en un arena, firmas de clase con hash). Calcular el cierre una sola vez por estado en los programas sin asserts casi no cambió las cifras (de 195 % a 177 % en f2c).
- **El máximo de npm, 399 ms, sale de un solo programa:** 5.200 estados × 337 clases. El tope (§2) lo acota.
- **Criterio (< 20 %): no se cumple.**
  - **Estimación:** un constructor sin asignaciones por estado podría bajar 3-5×, lo que aún deja la mediana en el 40-100 % de `compile()`.
- **Opciones para decidir:**
  - **(i) Construcción diferida en el primer `execAt`.** El DFA se guarda en el `Regex` con publicación atómica: si dos hilos lo construyen a la vez, gana uno y el otro libera el suyo. `compile()` no cambia y la API tampoco (`execAt` recibe `*const Regex`, así que el DFA iría detrás de un puntero con estado atómico). Coste: la complejidad de esa publicación.
  - **(ii) Construir solo para los programas que hoy van a la VM sin ruta propia** (ni `literal`, ni `class_run`, ni `shift_and`). Quita un 15 % de los programas (inventario de T0-A) y no cambia la mediana.
  - **(iii) Aceptar el coste,** unos µs por patrón, documentado.

  Recomiendo (i).

## 2. Tope del DFA
**Estados de ida (sin anclar y anclado) más inverso:**

| | f2c | f2c-2 | npm |
|---|---|---|---|
| ida p50 / p99 / máx. | 8 / 108 / 2.765 | 10 / 109 / 2.095 | 18 / 260 / 5.200 |
| inverso p50 / p99 / máx. | 3 / 45 / 136 | 4 / 39 / 160 | 5 / 130 / 687 |
| tabla en bytes p50 / p99 / máx. (estados × clases × 4) | 204 / 10.532 / 80.736 | 316 / 10.576 / 111.036 | 572 / 33.420 / 2.085.156 |

**Programas que quedan fuera del DFA según el tope** (de 4.706 / 16.486 / 7.371):

| Tope | 256 | 512 | 1.024 | 2.048 | 4.096 | 8.192 |
|---|---|---|---|---|---|---|
| f2c | 11 | 1 | 1 | 1 | 0 | 0 |
| f2c-2 | 52 | 16 | 8 | 1 | 0 | 0 |
| npm | 105 | 43 | 23 | 10 | 4 | 1 |

**Recomendación: 1.024 estados en total**, más un tope de bytes de la tabla (p. ej. 128 KiB) para los programas con muchas clases:
- deja fuera 32 de 28.563 programas (0,11 %), que siguen en la VM;
- su tabla es de p99 ≤ 33 KiB;
- con 2.048 quedan fuera 12, pero el peor caso de memoria se dobla.

## 3. Asserts
- **Tratables con estados, sin dejar el patrón a la VM:**
  - el estado lleva el contexto del carácter anterior: inicio de texto, fin de línea, palabra u otro;
  - el cierre con asserts se resuelve al leer el siguiente carácter (o el fin de entrada), un carácter después;
  - cubre `^`, `$` (con y sin `m`), `\b` y `\B`, también `word_ci`.
- **Diferencial:** 0 diferencias en los 8.879 programas con asserts. Comparados el final y la existencia del match; el inicio, solo con `sticky` (§7).
- **Cuántos estados añade** (ida, programas con asserts, p50 / p99; con contexto frente a las mismas listas sin él):

  | | Con contexto | Sin contexto |
  |---|---|---|
  | f2c | 14 / 142 | 6 / 125 |
  | f2c-2 | 16 / 149 | 8 / 121 |
  | npm | 20 / 268 | 12 / 256 |

  Es ~2× en la mediana y 1,05-1,2× en p99. Caben en el tope.
- **Sin integrar los asserts se quedarían fuera** 743 (f2c, 16 %), 3.148 (f2c-2, 19 %) y **4.989 de npm (68 %)**, casi todos con `^`.
- **Nota:** con `^` sin `m` (4.391 en npm) el match solo puede empezar en 0, así que su inicio no necesita el DFA inverso.

## 4. Prioridad leftmost-first
- **Construcción:** es la de la VM con los hilos colapsados en estados:
  - la lista de pcs en orden de inserción;
  - el mismo DFS de `addClosure`, que deduplica por pc en toda la posición;
  - la siembra del pc 0 al final mientras no hay match;
  - el corte al llegar a `match`;
  - seguir hasta el estado muerto.
- **Diferencial:** DFA frente a `tier0.exec` sobre `cbsubj.txt` (612 bytes), en cada índice, con y sin `sticky`, en WTF-8 y UTF-16:

  | | f2c | f2c-2 | npm |
  |---|---|---|---|
  | programas | 4.706 | 16.486 | 7.370 (1 sobre el tope de 8.192) |
  | con grupos / `u`/`v` / asserts | 848 / 1.103 / 743 | 4.113 / 2.988 / 3.148 | 2.841 / 263 / 4.988 |
  | ejecuciones | 11,0 M | 38,6 M | 17,3 M |
  | inicios comprobados | 3,8 M | 10,6 M | 1,1 M |
  | **diferencias** | **0** | **0** | **0** |

- **No hay problema de diseño.** El único fallo encontrado fue un bug del prototipo (la tabla ASCII se rellenaba con la propia función que la lee), y lo detectó la compilación Debug antes de medir.

## 5. Alfabeto de clases
- **Unifica WTF-8/UTF-16 y code unit/code point:**
  - la transición va por la clase del valor que ya devuelve `decodeAt`, en el modo del programa;
  - el diferencial pasa en las dos codificaciones y en los 4.354 programas con `u`/`v` con el mismo código.
  - Un carácter mal formado (`invalid`) no casa con ningún `char` pero sí con un `set` por su valor, como en la VM, así que tiene su propia familia de clases.
- **Cuántas clases hay:**

  | | p50 | p99 | máx. |
  |---|---|---|---|
  | code unit | 4-6 | 22-28 | 337 (npm) |
  | `u`/`v` | 2-4 | 12-29 | 39 |

  Con asserts se añaden los cortes de palabra y de fin de línea.
- **Cálculo:** los cortes de todos los rangos de `char`/`set`, ordenados; cada intervalo toma la firma de pertenencia y las firmas iguales forman una clase. Mediana: 1,78 µs en el prototipo.
- **Mapeo en ejecución:**
  - una tabla de 128 entradas para ASCII y una búsqueda binaria en los cortes para lo demás;
  - no hace falta una tabla de 65.536 para UTF-16: en el corpus las clases no ASCII son pocas y la búsqueda es corta.
  - Para WTF-8, el ejecutor ajustado debe leer el byte directamente cuando es ASCII (§6).

## 6. Tiempos del prototipo (se para aquí)
**Tiempo real:** bucle de `execAt` sobre 1 MiB, la mejor de 10 rondas intercaladas, MB/s. La VM actual es `Regex.execAt`: con B en el e-mail, C en el denso, `first` en los demás.

| Caso | VM actual | DFA | DFA con el salto de B/`first` | DFA / VM | salto / VM |
|---|---|---|---|---|---|
| e-mail | 289,0 | 143,3 | 251,7 | **0,50** | **0,87** |
| `\d{3}-\d{4}` denso | 618,4 (C) | 115,3 | 113,2 | 0,19 | 0,18 |
| `[A-Z][a-z]+` | 484,0 | 196,3 | 310,6 | 0,41 | 0,64 |
| `(Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+)` * | 714,8 | 256,2 | 645,8 | 0,36 | 0,90 |
| `(?:(a)\|b)*c` * | 20,5 | 63,6 | 70,9 | 3,10 | 3,46 |

\* Tienen grupos: la VM actual rellena los grupos y el prototipo solo da los límites, así que para estos dos casos la comparación no es válida. Los resultados (número de matches y un hash de los límites) coinciden en los cinco casos.

**Callgrind, e-mail** (256 KiB, instrucciones por byte sin el arranque):

| Variante | Instr./byte |
|---|---|
| VM con B | 43,1 |
| DFA | 53,9 |
| DFA con salto | **25,8** |

- **Por qué va más lento con menos instrucciones:** el DFA con salto ejecuta 1,67× menos instrucciones y aun así va más lento en tiempo real.
  - el bucle de ida del prototipo gasta unas 35 instrucciones por byte: `decodeAt` genérico, búsqueda de clase con la rama de `invalid`, la multiplicación `estado × columnas` y la rama de `EMIT`;
  - cada byte depende de la carga anterior (estado → tabla), con poco paralelismo;
  - el inverso usa `Subject.decodeBefore`, que pasa por `midOf` sin ruta rápida para ASCII (el 21 % de las instrucciones).
- **Diagnóstico:** es el ejecutor del prototipo, no el diseño. Pero eso solo se confirma con otro prototipo.
- **Estimación** (no medida):
  - un bucle ajustado (byte ASCII leído directamente, columnas precalculadas, identificadores de estado premultiplicados, match como rango de estados) debería bajar a unas 4-6 instrucciones por byte en la ida;
  - la latencia de una carga por byte limita la ida a unos 600-700 MB/s en este procesador;
  - con el salto de B delante, el e-mail podría estar en 400-800 MB/s. **Sin medir.**
- **El denso no es para el DFA:** C (Shift-And) va 5× por delante del prototipo. En el despacho, `shift_and` va antes que el DFA.
- **Regla del encargo:** «si el prototipo no da ≥ 1,3× en el e-mail, parar». Da 0,87×. **El precheck se para.** No se hizo un segundo prototipo.

## 7. DFA inverso
- **Coste:** construcción de 0,69 µs de mediana. Estados p50 3-5, p99 39-130, máx. 687: una fracción de los de ida.
- **Es necesario en la fase 1.** El DFA de ida da el final del match leftmost-first; el inicio sale del inverso:
  - desde el final, hacia la izquierda, el `t` más a la izquierda desde el que `input[t..e]` lleva a `match`, sin bajar de `index`;
  - comprobado en 15,5 M de ejecuciones sin diferencias.
- **Sin inverso,** el DFA solo acelera `test_`, y `execAt` tendría que volver a la VM para el inicio.
- **Linealidad:** cada inverso recorre `[index, e]`, un tramo que la ida ya recorrió, así que el total sigue siendo lineal.
- **Pendiente:**
  - el inverso con asserts, que exige el contexto al revés, no está prototipado;
  - para `^` sin `m` (la mayoría en npm) el inicio es trivial;
  - para `\b` y `$` en medio del patrón hay que diseñarlo.

## 8. Riesgos nuevos
1. **Rendimiento del ejecutor** (§6). El riesgo principal: el diseño es correcto, pero la ganancia depende de un bucle ajustado que aún no se ha medido.
2. **Coste de compilación** (§1). No cabe en el 20 %: exige construcción diferida (con publicación atómica) o aceptar el coste.
3. **Pares sustitutos partidos por `index`** (code point, UTF-16): el inverso decodifica hacia atrás un par que la ida, desde `index`, ve como una mitad suelta. El prototipo lo corrige leyendo desde `index`. `Regex.execAt` normaliza el índice con `charStart`, pero `tier0.exec` no.
4. **Programas con muchas clases** (máx. 337 en npm): la tabla crece con clases × estados, y el tope de bytes (§2) lo acota.
5. **Grupos:** el DFA solo da los límites; el pase etiquetado sigue igual. Es donde V8 va por delante (T0-A §2), y A no lo resuelve.
6. **Binario:** el ejecutor (instanciado para `u8` y `u16`) y el constructor añaden código. No medido: el prototipo no está en el `.so`.
7. **Interacción con C y B:** `literal`, `class_run` y `shift_and` deben ir antes que el DFA. Los saltos `inner`/`first` se aplican en el estado inicial del DFA (medido: sin salto, 0,50×; con salto, 0,87×).
8. **Matches vacíos y `advanceIndex`:** cubiertos por el diferencial en todos los índices. En el bucle de `findAll`, el avance tras un match vacío sigue siendo el de `Regex`.

## 9. Recomendación y re-estimación
- **No arrancar la fase 1 todavía.** Faltan dos cosas:
  1. **un segundo prototipo con el ejecutor ajustado** (1-2 días, estimación): ida con lectura directa de bytes ASCII, columnas precalculadas, estados premultiplicados, e inverso con ruta rápida ASCII. Mismo umbral: ≥ 1,3× en el e-mail frente a 289 MB/s, medido, más el diferencial;
  2. **decidir cuándo se construye el DFA:** diferido en el primer `execAt` (recomendado), o aceptar el coste en `compile()`.
- **Tope:** 1.024 estados en total, más un tope de bytes de la tabla.
- **Re-estimación** (estimación): de 6-9 semanas pasa a **7-10 semanas**, por:
  - la construcción diferida con publicación atómica (+3-5 días);
  - el inverso con asserts, que no estaba separado en el plan (+2-3 días).

  Queda condicionada al segundo prototipo: si el ejecutor ajustado no llega a 1,3×, A no compensa en el e-mail frente a B, y conviene replantear (por ejemplo, un DFA solo en el tramo que deja B, o nada).
- **Lo que el precheck sí deja cerrado:**
  - la corrección del diseño (0 diferencias, asserts incluidos);
  - el tamaño de los DFAs y de las tablas;
  - el alfabeto de clases;
  - la necesidad del inverso en la fase 1.

## 10. Segundo prototipo: bucle ajustado (pasa)
**Qué cambia respecto al primero** (mismo constructor, mismo diseño; solo el ejecutor en WTF-8 para programas sin asserts):
- **El match es propiedad del estado.** Sin asserts, el cierre no depende del carácter siguiente, así que la marca de match depende solo del estado de origen. Comprobado al construir: en ningún programa del corpus una columna difiere de las demás.
- **Identificadores premultiplicados** por el ancho de la fila: la transición es `ft[st + clase]`, sin multiplicación.
- **Los especiales van primero:**
  - en la ida: el muerto, los estados de match y el inicio sin anclar;
  - en el inverso: el muerto y los estados «puede empezar aquí».

  Una sola comparación por byte (`st <= máx.`) separa la ruta lenta.
- **Ruta rápida ASCII:** el byte `< 0x80` se lee directamente con la tabla de 128 clases, en la ida y en el inverso (`input[pos-1]`). El resto pasa por `decodeAt`/`decodeBefore`.
- **El salto de B/`first`** se aplica al estar en el estado inicial sin anclar (sin hilos vivos ni match), igual que en la VM.

**Corrección:** el diferencial con estos bucles para WTF-8 da **0 diferencias** en los tres corpus: 28.562 programas, 66,9 M de ejecuciones, 15,5 M de inicios comprobados. El Debug de f2c también da 0.

**Tiempos:** 1 MiB, la mejor de 10 rondas intercaladas, MB/s; resultados idénticos a la VM (matches y hash de los límites).

| Caso | VM actual | 1.er prototipo con salto | Ajustado | Ajustado con salto | Ajustado con salto / VM |
|---|---|---|---|---|---|
| e-mail | 297,4 (B) | 237,4 | 290,0 | **747,6** | **2,51×** |
| `[A-Z][a-z]+` | 442,0 (`first`) | 300,6 | 282,0 | 692,6 | 1,57× |
| `\d{3}-\d{4}` denso | 569,0 (C) | 112,2 | 268,8 | 154,3 | 0,27× |

**Callgrind** (256 KiB, instrucciones por byte sin el arranque):

| Caso | VM actual | 1.er prototipo con salto | Ajustado | Ajustado con salto |
|---|---|---|---|---|
| e-mail | 43,1 | 26,0 | 27,6 | **8,8** |
| `[A-Z][a-z]+` | 27,4 | 25,7 | 29,0 | 12,1 |
| denso | 19,5 | 70,1 | 31,6 | 39,1 |

- **El e-mail supera el umbral** (≥ 376 MB/s) con **747,6 MB/s**. Es del orden de los 705,0 de Rust en la corrida de 0.7.0 (comparación indicativa: son corridas distintas).
- **Reparto del e-mail ajustado:** el bucle de ida lleva el 38 % de las instrucciones, el inverso el 29 %, el salto el 11 % y la inicialización del `Scratch` (`memset`) el 12 %. El inverso es la siguiente pieza a mirar: recorre de nuevo el tramo del match.
- **Sin el salto, el DFA no mejora a la VM en el e-mail** (0,98×): la ganancia es la combinación. El DFA recorre rápido el tramo que deja B, y la VM ya no paga por posición.
- **El denso se queda en C:** el DFA va a 0,47×, y con el salto de `first` (que en el denso no salta nada) a 0,27×. En el despacho, `shift_and` va antes que el DFA; y el salto solo debe aplicarse cuando es selectivo (`inner`, o `first` con pocos bytes), una regla a fijar en la fase 1.

**Decisión según el umbral: A compensa. La fase 1 puede arrancar.**

### Coste con la construcción diferida (primer `execAt`)
- `compile()` no cambia. El primer `execAt` de cada `Regex` paga la construcción, y después queda publicada.
- **Construcción medida** con las tablas ajustadas incluidas:

  | | p50 | p99 | máx. |
  |---|---|---|---|
  | f2c | 4,6 µs | 257 µs | 2,5 ms |
  | f2c-2 | 5,6 µs | 295 µs | 9,8 ms |
  | npm | 9,3 µs | 555 µs | 385 ms |

  Frente a los 2,7-3,2 µs de mediana de `compile()`, el primer `execAt` cuesta unas 2-3 compilaciones más, una sola vez.
- **El máximo de 385 ms** es un único programa de npm (5.200 estados × 337 clases). El tope de §2 debe acotar también el producto estados × clases (p. ej. ≤ 32.768 celdas, 128 KiB), para que la construcción quede acotada. **Estimación:** con ese tope el peor caso baja a unos pocos ms; a medir en la fase 1.
- **Implementación:** el DFA detrás de un puntero con estado atómico en el `Regex` (vacío, en construcción, listo, o «no cabe»). El que construye publica y los demás usan la VM mientras tanto, o esperan. `execAt` recibe `*const Regex`, así que la API no cambia.

### Re-estimación de las fases (estimación)

| Fase | Contenido | Estimación |
|---|---|---|
| 1 | Ida e inverso ajustados (WTF-8 y UTF-16), alfabeto de clases, construcción diferida con publicación atómica, topes de estados y de celdas, vuelta a la VM, despacho después de C con la regla del salto selectivo, diferencial en el gate | 4-5 semanas |
| 2 | Asserts: ida con contexto (prototipada, 0 diferencias) e inverso con contexto (sin prototipar) | 2 semanas |
| 3 | `u`/`v` (el diferencial ya pasa con el modo code point en el ejecutor genérico) | 1 semana |
| 4 | ReverseInner generalizado | 1-2 semanas |
| **Total** | | **8-10 semanas** (antes 6-9) |

Sube por la construcción diferida y el inverso con asserts, que no estaban separados en el plan.

## 11. Fase 1 implementada
**Diseño:**
- **Dónde vive:** `src/tier0/dfa.zig`. El DFA de ida y el inverso se construyen **al compilar** (decisión del usuario), dentro de `Program.dfa`: inmutable y compartible como el resto del `Program`, sin atomics y sin cambio del contrato de hilos o de alocador.
- **Cuándo se construye:** solo para los programas sin asserts cuya ruta no es `literal`, `class_run` ni `shift_and`, y solo con los prefiltros activos (así que no con `u`/`v` ni con `t0_prefilters = false`).
- **Cómo se construye:** el cierre usa las listas `follow` del `Program`, las mismas del `addThread` de la VM.
- **Topes:** 1.024 estados (ida más inverso) y 32.768 celdas; por encima, la VM.
- **Despacho** (`pikevm.exec`, modo code unit):
  1. `literal`, `class_run` y `shift_and`;
  2. el DFA (`dfaSearch`, fuera de línea), con el salto `inner` siempre y `first` solo si admite ≤ 32 bytes (`prefilter.dfaSkip`);
  3. la VM.
- **Con grupos,** los límites vienen del DFA y la VM etiquetada corre sobre el tramo.
- **`dfaSearch` fuera de línea:** inlineado en `exec`, sus tres instancias ralentizaban las otras rutas rápidas hasta 0,77× (disperso) con las mismas instrucciones (callgrind): un efecto de layout.

**Cobertura:** tienen DFA 2.413 de 3.603 programas en code unit en f2c (67 %), 9.407 de 13.498 en f2c-2 (70 %) y 1.390 de 7.108 en npm (20 %: allí la mayoría tiene asserts, que llegan en la fase 2).

**Corrección:**
- **Tests:** 904 pasados, 13 omitidos, en Debug y ReleaseSafe.
- **Diferencial propio** frente a 0.7.1 (`169933b`): salida idéntica con `execAt` en WTF-8 y UTF-16 desde cada índice, sin `sticky` y con `sticky` forzado. Son 28.563 programas y 68,5 M de ejecuciones.
- **Gate:** GATE-PASS; test262 2994 en UTF-16 y WTF-8; los diferenciales sin cambios.

**Bench** frente a 0.7.1 (10 rondas intercaladas, la mejor por caso):

| Caso | 0.7.1 | Fase 1 | Factor |
|---|---|---|---|
| e-mail | 288,9 | 683,5 | **2,37×** |
| `[A-Z][a-z]+` | 427,4 | 608,8 | **1,42×** |
| `(Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+)` | 760,4 | 968,7 | 1,27× |
| `(?:(a)\|b)*c` | 19,5 | 27,5 | 1,41× |
| `\d{3}-\d{4}` denso (C) | 550,8 | 551,6 | 1,00× |
| `\d{3}-\d{4}` disperso (C) | 842,4 | 839,8 | 1,00× |

- **El resto de casos:** entre 0,98× y 1,11×.
- **Entrada corta de `[a-z]+`** (`class_run`): 0,89-0,94× en cuatro corridas; callgrind da +1,05 % de instrucciones (unas 3 por llamada).

**Coste de `compile()`** (µs, 0.7.1 → fase 1, la mejor de 20 por patrón de T0):

| Corpus | p50 | p99 | máx. |
|---|---|---|---|
| f2c | 2,43 → 4,28 | 16,8 → 91,9 | 209 → 694 |
| f2c-2 | 2,67 → 5,00 | 15,6 → 102,4 | 438 → 1.875 |
| npm | 3,03 → 3,65 | 42,4 → 222,2 | 947 → 5.588 |

El tope acota el peor caso: el programa de 385 ms del prototipo queda fuera del DFA.

**Binario** (`measure_binary.sh`, 40 símbolos): ReleaseFast 1.188.720 B (+58.640 frente a 0.7.1), ReleaseSmall 738.936 B (+23.376). Es el constructor más los ejecutores instanciados para `u8`/`u16` y para tres saltos.

## 12. Fase 2 implementada: asserts
**Diseño** (`src/tier0/dfa.zig`, tablas `Ctx`):
- **Qué programas las usan:** un programa con `^`, `$`, `\b` o `\B` recibe tablas con contexto.
- **El contexto:** el estado guarda el contexto de un lado de la posición (el borde del texto, un fin de línea, un carácter de palabra en code unit, u otro). El cierre se resuelve un carácter después, con `addClosure` y los asserts evaluados como `Vm.holds` a partir de los dos contextos.
- **Ida:** la marca de match va en la transición, y hay una columna para el fin de la entrada. Los inicios dependen del contexto a la izquierda de `index`. Los cuatro inicios sin anclar son los estados especiales del salto: tras saltar, el estado es el inicio del contexto de la nueva posición.
- **Inverso** (el retraso simétrico):
  - el estado es el conjunto de pcs más el contexto a la derecha;
  - el arranque depende del contexto a la derecha del final del match;
  - «puede empezar aquí» va en la transición;
  - cuatro columnas de borde dan el contexto real en `index`.
- **Alfabeto:** con asserts, la firma de clase incluye el contexto, así que una clase nunca mezcla palabra, fin de línea y resto.
- **Programas anclados** (`^` sin `m` delante): reciben DFA y corren la ida con `sticky` en el índice 0, sin inverso.

**Cobertura** (programas en code unit con DFA, fase 1 → fase 2):

| Corpus | Fase 1 | Fase 2 |
|---|---|---|
| f2c | 2.413 | 3.035 (84 %) |
| f2c-2 | 9.407 | 12.066 (89 %) |
| npm | 1.390 | **6.200 (87 %)** |

**Corrección:**
- **Tests:** 907 pasados y 13 omitidos, en Debug y en ReleaseSafe. Los nuevos comparan con la VM en todos los índices: `^`/`$` con y sin `m` (`\n`, `\r`, U+2028/2029), `\b`/`\B` junto a no ASCII y bytes mal formados, matches vacíos, grupos, anclados por `exec`, el tope y los fallos de memoria.
- **Diferencial propio** frente a la fase 1 (`14612d0`): salida idéntica con y sin `sticky` forzado, en WTF-8 y UTF-16. Son 28.563 programas y 68,5 M de ejecuciones.
- **Gate:** GATE-PASS; test262 2994 en UTF-16 y WTF-8; los diferenciales sin cambios.
- **El único bug encontrado:** la firma de clase sin el contexto, que mezclaba `\n` con letras. Lo detectaron los tests de la VM antes del diferencial.

**Bench:**
- **El harness `xbench`** frente a la fase 1 (sin casos con asserts): todo entre 0,98× y 1,11×.
- **Patrones con asserts,** con el bucle de `execAt` (la mejor de 10 intercaladas, 1 MiB, MB/s):

  | Patrón | Fase 1 | Fase 2 | Factor |
  |---|---|---|---|
  | `\b[\w.+-]+@[\w-]+\.[\w.]+\b` (e-mails) | 145,7 | 713,4 | **4,90×** |
  | `\d{3}-\d{4}\b` (denso) | 60,4 | 230,1 | 3,81× |
  | `[a-z]+\.$` (prosa) | 399,1 | 1.249,8 | 3,13× |
  | `\b[A-Z][a-z]+\b` (libro) | 203,4 | 526,1 | 2,59× |
  | `\bDarcy\b` (libro) | 4.644,8 | 8.381,3 | 1,80× |

**Coste de `compile()`** (µs, fase 1 → fase 2, la mejor de 20 por patrón):

| Corpus | p50 | p99 | máx. |
|---|---|---|---|
| f2c | 4,19 → 5,13 | 94,7 → 151,8 | 662 → 2.482 |
| f2c-2 | 4,88 → 6,37 | 102,5 → 174,0 | 1.764 → 3.522 |
| npm | 3,57 → 12,00 | 222 → 911 | 5.492 → 10.870 |

- **npm paga más:** ahora construye DFA para el 87 % de sus programas, y el constructor con contexto rehace el cierre por clase (no puede usar `follow`).
- **Mejora posible** (estimación): calcular el cierre una vez por contexto (4 × 4 combinaciones) en vez de una vez por clase.

**Binario** (`measure_binary.sh`, 40 símbolos): ReleaseFast 1.208.080 B (+19.360 frente a la fase 1), ReleaseSmall 749.960 B (+11.024).

## 13. El cierre por contexto en el constructor con asserts
**La causa,** medida en una copia instrumentada de `0277ae4`:
- **Ida:** el constructor rehacía el cierre en cada columna (clase), aunque solo depende del contexto derecho.
- **Inverso:** recorría en cada columna todos los pcs que consumen, aunque el conjunto que llega al estado solo depende del contexto izquierdo.

| Corpus | Recorridos del cierre (ida) | Necesarios: (estado, contexto) | Columnas del inverso / necesarias |
|---|---|---|---|
| f2c | 352.271 | 62.856 | 2,3 |
| f2c-2 | 1.906.769 | 291.328 | 2,3 |
| npm | 5.782.533 | 754.428 | 2,6 |

- **En npm,** el inverso hacía además 8,5 M de consultas al cierre y 10,8 M de pasos de intersección.
- **Callgrind** (todo npm compilado una vez):
  - `dfa.build` es el 89 % de las instrucciones;
  - `Walker.walk`, el 22 %;
  - el bucle por columna del inverso, otro ~19 %.

**El arreglo** (solo `buildCtx`):
- **Ida:** el cierre ordenado se calcula una vez por (estado, contexto derecho). Cada columna solo filtra por la firma de su clase.
- **Inverso:** se calculan una vez por (estado, contexto izquierdo) dos cosas:
  - «puede empezar aquí»;
  - la lista de pcs que consumen cuyo cierre de `pc + 1` corta el conjunto.

  Solo se recorren los pcs que alguna clase de ese contexto acepta. Sin ese filtro, la mediana empeoraba un 2 %.
- **Verificación:** las tablas salen idénticas a las de `0277ae4` en todos los programas de los tres corpus (8.091 con contexto, 13.210 sin él).

**Coste de `compile()`** (µs, `0277ae4` → ahora; dos rondas intercaladas, la mejor de 20 por patrón):

| Corpus | p50 | p99 | máx. | media |
|---|---|---|---|---|
| f2c | 5,48-5,65 → 5,52-5,55 | 160-164 → 141-149 | 2.765-2.786 → 1.425-1.427 | 14,5-15,2 → 13,4-13,5 |
| f2c-2 | 6,81-6,87 → 6,69-6,82 | 186-188 → 146-153 | 3.765-3.841 → 2.056-2.083 | 17,9-18,1 → 15,6-16,1 |
| npm | 12,66-13,28 → 12,29-12,39 | 996-1.025 → 658-672 | 11.775-12.041 → 5.293-5.371 | 71,9-73,9 → 50,9-51,2 |

- **Callgrind, todo npm:** 5,18 G → 3,43 G instrucciones (−34 %); `dfa.build`, 4,62 G → 2,44 G.
- **La mediana de npm apenas baja** (callgrind sobre los patrones entre p40 y p60: 573,7 M → 552,6 M, −3,7 %).
  - Allí la redundancia del cierre pesaba poco.
  - El coste es construir la tabla entera: un ~20 % el interning de estados (hash de claves), un ~20 % los recorridos del cierre que sí hacen falta, y un ~13 % la memoria (arena y listas).
  - Volver a los 3,5-4 µs de la fase 1 pide otra cosa (construcción diferida o interning más barato). Queda fuera de este arreglo.

**Corrección:**
- **Tests:** pasan en Debug y en ReleaseSafe.
- **Diferencial propio:** idéntico a `0277ae4` con y sin `sticky` (68,5 M de ejecuciones).
- **Gate:** GATE-PASS, con test262 2994 en UTF-16 y WTF-8 y los diferenciales sin cambios.

**Bench de los patrones con asserts:** entre 0,96× y 1,02× (las mismas tablas).

**Binario:** ReleaseFast 1.208.800 B (+720), ReleaseSmall 750.456 B (+496).

## 14. Fase 3 implementada: code points (`u`/`v`)
**Diseño** (`src/tier0/dfa.zig`):
- **El modo es un dato del DFA:** un programa `u`/`v` recibe su DFA en modo code point (`Dfa.mode`).
  - **Las tablas:** son las mismas, sobre los valores que da `decodeAt(.code_point)`. Un par válido es un valor astral y un sustituto suelto, su propio valor.
  - **La ruta ASCII no cambia:** por debajo de 0x80, una unidad es un carácter entero en los dos modos.
  - **Solo la ruta lenta decodifica en el modo del DFA,** así que no hay instancias nuevas del ejecutor.
- **`\b` con `i`** usa los caracteres de palabra extendidos (`word.extra`, ſ y K), como `Vm.isWordBoundary`; los cortes los separan.
- **El registro:**
  - `tier0.compile.Options.code_point` construye el DFA sin prefiltros ni salto, porque `first` e `inner` miran code units;
  - `Options.dfa` es el interruptor de diagnóstico;
  - `exec` despacha al DFA cuando `d.mode == mode`.

**Precheck:**
1. **Cobertura:** 4.349 de los 4.354 programas `u`/`v` de T0 tienen DFA. Los otros 5 quedan fuera por el tope.

   | Corpus | Con DFA | Con asserts | Fuera por el tope |
   |---|---|---|---|
   | f2c | 1.102 | 121 | 1 |
   | f2c-2 | 2.985 | 485 | 3 |
   | npm | 262 | 156 | 1 |

2. **Clases:**

   | | p50 | p99 | máx. |
   |---|---|---|---|
   | sin asserts | 2-3 | 11 | 39 |
   | con asserts | 5-6 | 12-29 | 31 |
   | **cortes** | 13-24 | 1.507-1.886 | 2.598 |

   `\p{…}` es lo que dispara el número de cortes.
3. **Estados:**
   - ida: p50 6-13, p99 73-149, máximo 855;
   - inverso: p50 2-7, p99 27-71, máximo 91.
4. **Sustitutos sueltos (punto 4) y bytes mal formados (punto 5):**
   - **Sujetos:** a `cbsubj` se suman casos en los dos formatos.
     - WTF-8: lead y trail sueltos, la pareja codificada por separado, una continuación suelta, secuencias truncadas y `0xFF`.
     - UTF-16: lead y trail sueltos, un par invertido y un lead al final.
   - **Resultado:** el diferencial es idéntico a la fase 2 (75,9 M de ejecuciones).
6. **Asserts:** 45 programas con `\b` extendido y 49 con `^`/`$` de línea, todos sin diferencias.
7. **Coste de `compile()`:** abajo.
8. **Binario:** abajo.

**El fix del alfabeto** (antes de portar):
- **El problema:** el prototipo daba firma a cada intervalo con `Set.contains` (búsqueda binaria) por corte y por instrucción, y repetía el trabajo para la familia de mal formados. Con miles de cortes, el p99 `u`/`v` subía 10-17×.
- **Ahora:**
  - un barrido por los rangos ordenados de cada conjunto;
  - la firma «mal formado» derivada de la válida (sin los bits de los literales), igual a ella salvo cuando un literal acepta el intervalo.
- **Tablas:** idénticas, en los 25.650 DFAs de los tres corpus.
- **El p99 `u`/`v`:** de 280-462 µs a 121-337 µs.
- **El criterio** se compara con code unit con DFA: el p99 `u`/`v` de npm queda por debajo del de code unit.

**Corrección:**
- **Tests:**
  - 911 pasados y 13 omitidos, en Debug y en ReleaseSafe;
  - los nuevos comparan `exec` con el DFA y sin él, en modo code point, en todos los índices, con y sin `sticky`, en WTF-8 y UTF-16:
    - literales astrales;
    - clases no ASCII y astrales;
    - `.` con y sin `s`;
    - `\b`/`\B` con palabra extendida;
    - `^`/`$` con LS/PS y `m`;
    - grupos;
    - matches vacíos;
    - sustitutos sueltos, pares e índices dentro de un par;
    - bytes mal formados;
    - el tope;
    - fallos de memoria.
  - Una mutación (decodificar en code unit) los hace fallar.
- **Diferencial propio:** idéntico a la fase 2 con y sin `sticky`, en `cprobe` (68,5 M de ejecuciones) y en la sonda de sustitutos (75,9 M).
- **Gate:** GATE-PASS; test262 2994 en UTF-16 y WTF-8; los diferenciales sin cambios.

**Bench `u`/`v`** (`execAt` en bucle, la mejor de 10 intercaladas, MB/s, mismos matches):

| Patrón | Fase 2 (VM) | Fase 3 (DFA) | Factor |
|---|---|---|---|
| `\p{L}+` (libro) | 44,7 | 89,0 | 1,99× |
| `\p{Script=Greek}+` (griego) | 44,5 | 30,1 | **0,68×** |
| `[\p{L}\p{N}_]+` (código) | 51,0 | 119,0 | 2,33× |
| `\b\p{L}+\b` (libro) | 17,3 | 80,3 | 4,64× |

**El griego es más lento:**
- **Callgrind:** 50,4 M → 67,7 M instrucciones en 256 KiB.
- **La ida** del DFA es más barata que la VM (13,8 M frente a 27,8 M).
- **El inverso** decodifica cada carácter hacia atrás en WTF-8 (`decodeBefore` más `seqAt`), unos 34 M. En un texto casi todo no ASCII, con matches cortos, eso pesa más que lo que ahorra la ida.

  Mejora posible (estimación): decodificar en línea las secuencias de 2 bytes en las dos direcciones; cubre griego, cirílico y latín extendido.

**Code unit sin regresión:**
- **Tiempo** (los casos de la fase 2 más tres sin asserts): entre 0,90× y 1,06×.
- **En instrucciones:**
  - `\bDarcy\b`, −0,7 %;
  - el denso, +4,7 %;
  - el e-mail con `\b`, +3,6 %.

**Coste de `compile()`** (µs; dos rondas; `fbdac3a` → fase 3):

| Corpus | Total p50 | Total p99 | Total máx. | `u`/`v` p50 | `u`/`v` p99 | `u`/`v` máx. |
|---|---|---|---|---|---|---|
| f2c | 7,1-7,2 → 8,1-8,3 | 203-204 → 259-268 | 2.013-2.025 → 1.928-1.948 | 2,8 → 4,8 | 31 → 191-193 | 2.836-2.884 → 2.864-3.016 |
| f2c-2 | 8,7-8,8 → 9,9 | 227 → 273-276 | 2.718-2.722 → 3.006-3.012 | 3,1 → 5,6 | 29 → 253-262 | 2.806-2.842 → 2.898 |
| npm | 16,4-16,5 → 16,0-16,2 | 1.001-1.008 → 992-998 | 7.586-7.868 → 8.258-8.259 | 3,6-3,7 → 13,8-14,0 | 40-41 → 502-514 | 95-97 → 1.036-1.055 |

Esta máquina mide más lento que la de los §11-13; las dos columnas se midieron juntas.

**Binario** (`measure_binary.sh`, 40 símbolos):
- ReleaseFast 1.211.904 B (+3.104 frente a `fbdac3a`);
- ReleaseSmall 751.528 B (+1.072).

**Fix del griego** (`Dfa.decodeBack`):
- **El cambio:** el inverso lee en línea las secuencias WTF-8 bien formadas de 2 y 3 bytes, y las de 4 en modo code point. El resto sigue por `decodeBefore`. Un test lo compara con `decodeBefore` en todas las posiciones de un texto con secuencias raras, en los dos modos.
- **La causa medida antes:** en el griego, el inverso costaba 34,2 M instrucciones, de ellas 21,5 M (63 %) en `decodeBefore`.
- **Callgrind del griego:** 67,7 M → 46,3 M instrucciones; la fase 2 hacía 50,4 M. El inverso baja de 34,2 M a 12,7 M.
- **Bench** (la mejor de 10 intercaladas, MB/s; fase 2 → `f087db5` → fix):

  | Patrón | Fase 2 | `f087db5` | Fix | Fix / fase 2 |
  |---|---|---|---|---|
  | `\p{L}+` | 44,7 | 89,6 | 92,1 | 2,06× |
  | `\p{Script=Greek}+` | 44,8 | 29,9 | 47,5 | **1,06×** |
  | `[\p{L}\p{N}_]+` | 50,8 | 118,6 | 120,9 | 2,38× |
  | `\b\p{L}+\b` | 17,3 | 80,8 | 80,5 | 4,65× |

- **Lo que queda en el griego** es la ida (`decodeAt`, 15,0 M).
- **Programas que se benefician (cota):** los DFAs con miembros no ASCII, 3.330 de 4.349 en `u`/`v` y 14.633 de 21.301 en code unit (incluye `.` y las clases negadas). Code unit gana en texto no ASCII con 2 y 3 bytes.
- **Corrección:** tablas y diferenciales idénticos; GATE-PASS.
- **Binario:** ReleaseFast 1.212.544 B (+640 frente a `f087db5`) y ReleaseSmall 752.104 B (+576).

**Deuda aparte:** Construcción diferida del DFA (lazy build, o abaratar el interning de estados). Afecta a code unit y a code point. No es de fase 3.
