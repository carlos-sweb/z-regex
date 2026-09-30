# T0-A: ruta hacia el DFA (inventario y fases)

Inventario y propuesta sobre `83e78d4` (J, C y B en la rama). No se tocó `src/`.
- **Cifras del corpus:** de una sonda en el scratchpad que compila contra el repo y recorre los programas de T0 de f2c, f2c-2 y npm.
- **Cifras de V8 y Rust:** de F7c-6 (`docs/BENCHMARKS.md`, execAt, la mejor ronda).
- **Cifras de z-regex con J+C+B:** del harness `xbench` en esta sesión (10 rondas intercaladas).

V8/Rust y z-regex salen de corridas distintas, así que las distancias son indicativas hasta el re-bench de §1. Las estimaciones van marcadas.

## 1. Cierre del trabajo actual
- **Merge** de `claude/trusting-ride-po3bt8` a main: J (`da7d12e`), C (`80f6ac7`) y B (`83e78d4`), cada uno con su gate en verde.
- **Tag v0.8.0 (recomendado) frente a v0.7.1:**
  - J+C+B cambian las cifras que publica el proyecto: 12,25× en el denso, 4,89× en el e-mail, 1,26× en el disperso. Son tres rutas de ejecución nuevas en T0 (`shift_and`, `inner` y el bucle de J);
  - un parche (0.7.1) comunicaría «arreglos»; v0.8.0 comunica «rendimiento nuevo»;
  - la API no cambia (congelada en 0.7.0) y los resultados tampoco: ningún diferencial se movió. En 0.x un salto de minor puede leerse como ruptura, así que las notas de la versión deben decir explícitamente «API y resultados sin cambios».
- **Re-bench completo** (todos los motores, `bench/compare`, 10 rondas intercaladas y la mejor): el de F7c-6 es anterior a J+C+B.
- **BENCHMARKS.md:** cifras nuevas con la nota «cifras de v0.8.0, tras J+C+B». El tag lo crea el usuario desde la web (el push de tags da 403 desde aquí).

## 2. Estado de T0
**Rutas** (en el orden de `prefilter.analyze`): `literal`, `class_run`, `shift_and` (C), `inner` (B, un salto dentro de la VM), `first` (salto dentro de la VM), y si no, la Pike VM sin salto. Con grupos, esas rutas dan los límites y la VM etiquetada corre sobre el tramo. J hace que `x+` y `x{n,}` no dupliquen el cuerpo.

**Inventario del corpus** (programas de T0, medido):

| | f2c | f2c-2 | npm |
|---|---|---|---|
| programas en T0 | 4.706 | 16.486 | 7.371 |
| con `u`/`v` | 1.103 | 2.988 | 263 |
| con grupos | 848 | 4.113 | 2.841 |
| con asserts (clausura dinámica) | 743 | 3.148 | **4.988** |
| — `^` / `$` sin `m` | 237 / 204 | 788 / 805 | **4.391** / 1.685 |
| — `\b` / `\B` | 171 / 197 | 852 / 842 | 174 / 5 |
| ruta: `literal` / `class_run` / `shift_and` | 278 / 55 / 235 | 685 / 70 / 672 | 349 / 27 / 495 |
| ruta: `inner` / `first` / ninguna | 408 / 2.128 / 1.602 | 1.906 / 8.024 / 5.129 | 290 / 5.765 / 445 |
| instrucciones p50 / p90 / p99 / máx. | 5 / 20 / 64 / 444 | 7 / 23 / 68 / 311 | 9 / 47 / 134 / 1.716 |
| pcs que consumen p50 / p99 / máx. | 2 / 46 / 247 | 3 / 40 / 157 | 5 / 93 / 1.033 |
| pcs que consumen ≤ 30 (umbral de Rust para un DFA completo) | 4.609 (98 %) | 16.157 (98 %) | 6.586 (89 %) |
| clases del alfabeto p50 / p99 / máx. | 3 / 22 / 39 | 4 / 21 / 39 | 5 / 27 / 337 |

**Estados del DFA hacia delante, medidos sin ejecutar:**
- **Cómo se contaron:** construcción de subconjuntos leftmost-first sobre el alfabeto de clases:
  - cada estado es una lista ordenada de pcs más una marca de «ya hay match»;
  - la lista se corta en `match`;
  - el pc 0 se siembra mientras no hay match;
  - el estado muerto termina.
- **Qué programas entran:** los que no tienen asserts, con un tope de 10.000 estados.

| | f2c | f2c-2 | npm |
|---|---|---|---|
| code unit: programas medidos | 2.981 | 10.837 | 2.277 |
| estados p50 / p90 / p99 / máx. | 4 / 17 / 53 / 141 | 5 / 18 / 52 / 1.147 | 6 / 32 / 143 / 7.215 |
| ≤ 100 estados | 2.978 | 10.812 | 2.236 |
| más de 10.000 | 0 | 0 | 0 |
| `u`/`v`: medidos, estados p99 / máx. | 982, 30 / 1.327 | 2.501, 45 / 1.418 | 106, 9 / 24 |

Todo el recorrido (unos 28.000 programas, incluida la construcción) tardó 2,3 s.

**Los patrones del bench:**

| Patrón | Estados | Clases |
|---|---|---|
| e-mail `[\w.+-]+@[\w-]+\.[\w.]+` | **7** | 6 |
| `\d{3}-\d{4}` | 9 | 3 |
| `(Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+)` | 14 | 9 |
| `[A-Z][a-z]+` | 4 | 3 |

**No medido (necesita el programa invertido, que no existe):** los estados del DFA inverso.

**Distancia a V8 y a Rust** (execAt, MB/s; z-regex de esta sesión, V8 y Rust de F7c-6):

| Caso | z-regex J+C+B | V8 | Rust | Quién va delante |
|---|---|---|---|---|
| e-mail | 286,5 | 79,4 | 705,0 | **Rust, 2,46×**; V8 detrás |
| `\d{3}-\d{4}` denso | 557,6 | 172,8 | 84,3 | z-regex |
| `\d{3}-\d{4}` disperso | 829,2 | 909,5 | 1.819,2 | Rust 2,2×, V8 1,1× |
| `(\d{3})-(\d{4})` denso | 125,2 | 143,7 | 71,5 | V8 1,15× |
| `(\d{3})-(\d{4})` disperso | 443,8 | 1.002,5 | 1.155,5 | Rust 2,6×, V8 2,3× |
| `(?:(a)\|b)*c` | 19,4 | 29,5 | 51,3 | Rust 2,6×, V8 1,5× |
| `[A-Z][a-z]+` | 437,9 | 506,5 | 301,0 | V8 1,16× |
| `(Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+)` | 726,1 | 460,8 | 2.116,5 | Rust 2,9× |
| `[a-z]+` | 223,4 | 77,9 | 59,0 | z-regex |
| `hello` / `Darcy` | 16.632 / 15.621 | 1.809 / 8.760 | 19.917 / 19.277 | Rust ~1,2× |

**Qué falta para empatar en todo T0:**
- **El e-mail es el único caso grotesco que queda frente a Rust** y es el objetivo de A. El denso ya está: 557 MB/s frente a 84 de Rust, así que el criterio «denso a <0,5× de Rust» se cumple desde C.
- **Casi todo lo demás que queda por detrás de V8 tiene grupos** (los dos `(\d{3})-(\d{4})`, `(?:(a)|b)*c`). Ahí el coste está en el pase etiquetado, que A no toca: A da los límites, y los grupos siguen en la VM etiquetada (ver §7).

## 3. D frente a A: no hacer D
- **D** (reorganizar el despacho de la VM):
  - 1-2 semanas (estimación);
  - toca el bucle caliente de todos los patrones de la VM;
  - riesgo alto de layout: en C y B, 1-3 % de instrucciones ya dieron ±14 % en tiempo real;
  - una ganancia de 1,3-1,8× (estimación) que A sustituye en los mismos patrones.
- **A:** quita la VM del camino en los programas que caben en el DFA, que según §2 son casi todos los que no tienen asserts.
- **Recomendación: ir directamente a A.** D sería pagar dos veces el mismo bucle. La VM seguirá siendo la vuelta atrás de A, y su coste solo importará en lo que A no cubra.

## 4. Producción (1-3 meses, en paralelo con el precheck y la fase 1)
Qué observar en usuarios reales tras v0.8.0:
- **Qué patrones caen en la VM sin salto** (ruta `none`) y cuánto tiempo pasan ahí. El bench interno (`bench/bench.zig`) ya etiqueta la ruta por patrón.
- **Si el e-mail residual (2,46× de Rust) molesta** a alguien, o si los casos que preocupan son otros: grupos, entradas cortas.
- **Si algún consumidor pide algo que D resolvería y A no:** los programas con asserts hasta la fase 2, o los etiquetados.
- **El coste de compilación**, si alguien compila patrones en caliente: condiciona construir el DFA al compilar o en diferido (§5).

## 5. Precheck de A (2-3 días)
Debe responder, con un prototipo en el scratchpad y el diferencial frente a la VM:

1. **Prioridad leftmost-first en los subconjuntos.**
   - Los estados son listas de pcs en el orden de inserción de la Pike VM (el orden de `follow`); la lista se corta al llegar a `match`; el pc 0 se siembra mientras no hay match.
   - El DFA hacia delante sigue tras el primer estado con match hasta el estado muerto, recordando el último, como hace la VM.
   - **Verificación:** DFA frente a VM desde cada índice sobre los programas del corpus (el diferencial de C y B). Si no da 0 diferencias, las fases no arrancan.
2. **El inicio del match (DFA inverso).**
   - Hace falta invertir el programa de T0: no existe (`existsAnchoredMatch(.backward)` devuelve `Unsupported`, `src/tier0/pikevm.zig:316`).
   - El inverso corre anclado desde el final y busca el match más largo hacia la izquierda, sin bajar de `index`. Con el final del match leftmost-first, da su inicio: el inicio leftmost es el mínimo de todos los matches, y `[s0, e]` es uno de ellos.
   - **Medir:** el coste de invertir el programa y el número de estados del inverso en el corpus.
3. **Memoria.** El inventario de §2 abre dos diseños, y el precheck debe elegir:
   - **(a) DFA completo construido al compilar,** guardado en el `Program`, inmutable y compartible entre hilos, solo si cabe bajo un tope (p. ej. 1.024 estados o 64 KiB; a fijar), y la VM si no:
     - no hay caché ni expulsión: la memoria la fija el tope y la linealidad es trivial (una transición por unidad);
     - por el inventario, cubriría casi todos los programas sin asserts;
     - coste: tiempo de compilación, que hay que medir por patrón (la compilación de hoy está en 1-3 µs en el bench).
   - **(b) DFA perezoso con caché en `Scratch`** (campo privado, sin cambio de API):
     - cuántos estados caben;
     - vaciar entera al llenarse o LRU;
     - cuándo vaciar: `Scratch` se puede usar con varios `Regex` alternados, así que la caché debe reconocer el programa y vaciarse al cambiar;
     - volver a la VM si se vacía más de N veces por búsqueda.
   - **La recomendación queda para el precheck.** El dato de §2 favorece (a) con la VM por encima del tope (la variante F del informe anterior); (b) solo haría falta para la cola de programas grandes.
4. **Asserts** (fase 2): el diseño de Rust, con bits de contexto en el estado (inicio/fin de texto o de línea, y si la unidad anterior es de palabra). En modo code unit, `\b` es ASCII.
5. **El alfabeto de clases en tiempo de ejecución:**
   - una tabla de 128 entradas para ASCII;
   - una búsqueda en los cortes de rangos para el resto, sobre el valor que ya da `decodeAt` en WTF-8 y UTF-16;
   - **medir** las instrucciones por byte en el e-mail frente a B (43,4).
6. **Tiempos del prototipo:** el e-mail, el denso (C debe seguir por delante: `shift_and` va antes que el DFA) y los casos de §2.
7. **Confirmar la estimación de 6-9 semanas** de las fases.

## 6. Fases de A
Todas en modo code unit salvo la 3, con el alfabeto de clases del valor decodificado. Así WTF-8 y UTF-16 no son fases distintas, y el modo code point solo cambia la decodificación, que ya existe.

| Fase | Contenido | Estimación |
|---|---|---|
| **1** | DFA hacia delante y DFA inverso para programas sin asserts; alfabeto de clases; vuelta a la Pike VM (por encima del tope, o cuando la caché se vacía demasiado); los límites para `execAt`/`test_`; con grupos, los límites y después la VM etiquetada sobre el tramo, como hoy. `inner` y `first` siguen como salto antes del DFA. | 3-4 semanas |
| **2** | Asserts: `^`, `$` (con y sin `m`), `\b`, `\B`. En npm es lo que más pesa: 4.988 de 7.371 programas tienen asserts, sobre todo `^`. | 1-2 semanas |
| **3** | Code points (`u`/`v`): la decodificación ya existe; faltan las clases sobre rangos grandes y los pares sustitutos en UTF-16. El inventario da DFAs pequeños (p99 ≤ 45 estados). | 1 semana |
| **4** | ReverseInner generalizado (F y G): un literal interior obligatorio cualquiera, con el DFA inverso desde él. Generaliza B. | 1-2 semanas |
| **Total** | | **6-9 semanas**, a confirmar en el precheck |

- **Por qué la vuelta a la VM y el inverso van en la fase 1:**
  - sin la vuelta a la VM, la memoria no está acotada y la linealidad se rompe cuando la caché se desborda;
  - sin el inverso no hay inicio del match: la fase 1 solo aceleraría `test_`, que es marginal.
- **Cada fase tiene su gate** (§8) y su commit.

## 7. Lo que no entra en A
- **Backrefs:** van al backtracker (T2), como hoy.
- **Lookarounds:** LookLinear (T2 delegando en la VM de T0) ya los cubre; el DFA no los ve.
- **Grupos:** A da los límites; los grupos los sigue rellenando la VM etiquetada sobre el tramo. Acelerar ese pase (p. ej. una ruta «one-pass» para grupos sin ambigüedad) sería otro proyecto, y es donde queda casi todo lo que V8 hace mejor (§2).
- **Modificadores y `v` completo:** son de 1.x, no de T0.

## 8. Gate de A (cada fase)
- **Sin cambios de semántica:** el DFA da exactamente lo que da la Pike VM.
  - el diferencial propio (28.563 programas, 34,2 M de `execAt`, WTF-8 y UTF-16, con y sin grupos) con 0 diferencias;
  - pfdiff (slots idénticos), t1diff, lldiff, lbdiff, dv8, lbdiff-v8 e ivdiff sin cambios;
  - test262 2994 en UTF-16 y WTF-8.
- **Linealidad:** O(1) por unidad en el DFA, o la vuelta a la VM, que es lineal. Adversariales incluidos: programas en el tope, caché que se vacía (si se elige (b)).
- **Memoria acotada:** el tope por programa (a) o por `Scratch` (b), con test.
- **Bench:**
  - **el e-mail a menos de 2× de Rust:** ≥ 352,5 MB/s frente a 705,0; hoy 286,5;
  - sin regresiones más allá de ±10 % (confirmadas con callgrind) en el resto de casos;
  - el denso se queda en C.
- **Binario:** reportarlo; el DFA completo en el `Program` no afecta al binario, pero su código sí.
- **Tiempo de compilación:** reportarlo, sobre todo con (a).
- **La API no cambia.**

## 9. Decisiones del usuario
1. **Tag:** v0.8.0 (recomendado, §1) o v0.7.1.
2. **D o A:** no hacer D, ir a A (recomendado, §3).
3. **Memoria del DFA:**
   - (a) DFA completo al compilar, con tope y vuelta a la VM;
   - (b) perezoso con caché en `Scratch`.

   El precheck trae los datos; el inventario favorece (a).
4. **Criterio del bench de A:** confirmar que el objetivo es el e-mail a menos de 2× de Rust, y que el denso queda fuera, porque ya se cumple.
5. **Cuándo arrancar el precheck de A:** antes de tener datos de producción, o tras 1-3 meses con v0.8.0.
