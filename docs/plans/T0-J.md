# T0-J: compilar `x+` sin duplicar el cuerpo (precheck)

Precheck en solo lectura sobre v0.7.0 (`419f49e`). No se tocó `src/`. Las mediciones usan una
sonda del scratchpad (fuera del repo) que:
- importa el módulo `zregex` del repo;
- reescribe el programa ya compilado de T0 a la forma propuesta;
- recalcula sus clausuras como `buildClosures`;
- lo ejecuta en la Pike VM real (`tier0.exec`).

Es un prototipo de medida, no la implementación.

## 1. Diagnóstico

### Cómo se compila hoy (`src/tier0/compile.zig`, `Builder.emitRepeat`, líneas 366-400)

`emitRepeat` emite `min` copias del cuerpo (`emitIteration`, sin `optional`) y después una de dos cosas:
- `max - min` copias opcionales, cada una con su `split`;
- un bucle.

| Repetición | Programa |
|---|---|
| `x*` (voraz) | `L: split(B, out); B: x; jmp L; out:` (una copia) |
| `x*?` | `L: split(out, B); B: x; jmp L` (una copia) |
| `x?` | `split(B, out); B: x; out:` (una copia) |
| **`x+`** | **`x; L: split(B, out); B: x; jmp L`**: el cuerpo **dos veces** |
| **`x{n,}`** | **`n` copias + el bucle de `x*`**: `n+1` copias |
| `x{n,m}` | `n` copias + `m-n` opcionales (desenrollado; J no aplica) |

En el cuerpo etiquetado cada iteración empieza con `clear` de sus grupos (D4). Un cuerpo anulable usa el producto de fases (D3) en las iteraciones opcionales.

Ejemplo real, el e-mail `[\w.+-]+@[\w-]+\.[\w.]+`: 15 instrucciones, con `set0` en los pc 0 y 2, `set1` en 5 y 7 y `set2` en 10 y 12.

### Cómo trata la Pike VM los `split` (`src/tier0/pikevm.zig`)
- **Clausuras precalculadas:** `buildClosures` (`compile.zig:202`) precalcula en tiempo de compilación la clausura épsilon de cada pc, recorriendo `jmp`, `split` (primero `x`) y `save`/`clear`. El resultado es la lista ordenada de pcs que consumen (`follow`).
- **En ejecución no se resuelve ningún `split`:** `addThread` copia la lista y deduplica por pc con un sello de generación. Solo las clausuras con `assert` se resuelven dinámicamente (`addClosure`).
- **Qué hace la duplicación:**
  - en cada posición se siembra un hilo en el pc 0 (la primera copia);
  - el hilo que ya estaba dentro de la palabra está en el pc 2 (la segunda copia), que es otro pc aunque sea el mismo conjunto;
  - la deduplicación no los une: los dos prueban el conjunto;
  - el sembrado desemboca en la clausura del bucle, que ya estaba en la lista.

### Desglose medido (e-mail, `emails.txt` del bench)

Contadores por byte, 1 MiB:

| | Hoy | Forma A | Cambio |
|---|---|---|---|
| hilos avanzados | 2,78 | 1,95 | −30 % |
| pruebas de conjunto | 1,89 | 1,05 | −44 % |
| inserciones del sembrado | 0,99 | 0,14 | −86 % |
| visitas de clausura | 4,20 | 2,80 | −33 % |
| matches | 7.167 | 7.167 | = |

Instrucciones (callgrind, 256 KiB, VM real, sin el arranque):

| | Hoy | Forma A |
|---|---|---|
| instrucciones | 71,2 M (271,6 por byte) | 56,2 M (214 por byte) |
| cambio | — | **−21 %** |

Tiempo real (1 MiB, la mejor de 15 ejecuciones intercaladas): **37,1 → 47,6 MB/s, 1,28×**.

De la clausura épsilon (el 37 % de las instrucciones), la duplicación explica un tercio de las visitas y casi todas las inserciones del sembrado.

### Dónde no gana
- **`[A-Z][a-z]+` sobre el libro:** 7.669.258 instrucciones hoy y 7.669.407 con la forma A, iguales. La siembra (`[A-Z]`) muere en las minúsculas, así que en el bucle solo hay un hilo y no hay nada que deduplicar.
- **Cuándo sí gana:** cuando el bucle cuelga de la clausura del inicio (el patrón empieza por `x+`, quizá tras alternativas), o cuando varios hilos solapados entran en el mismo `x+`.
- **`\d{3}-\d{4}` denso** no tiene `+`: J no lo toca.

## 2. Alternativas

| Forma | Qué es | ¿La VM la soporta? | Coste | Riesgo |
|---|---|---|---|---|
| **A** | `L: x; split(L, out)` (voraz) o `split(out, L)` (perezosa). En etiquetado: `L: clear; x; split(L, out)` | Sí. Las aristas hacia atrás ya existen (`x*` usa `jmp L`). `buildClosures` las sigue con su marca de visitado, y el cuerpo no anulable consume antes de volver, así que no hay ciclo épsilon | 2-3 días | Bajo (abajo) |
| B | Un opcode nuevo `PLUS` | Habría que añadirlo a la VM, a la VM etiquetada, a `buildClosures` y al prefiltro | 1 semana | Sin ganancia sobre A: el coste de ejecución ya está solo en las instrucciones que consumen (las clausuras son precalculadas). El `Program` de T0 es interno, así que un opcode nuevo no tocaría la API, pero no aporta nada |
| C | Reordenar para emitir el cuerpo una vez: `jmp B; L: split(B, out); B: x; jmp L` (el `x*` de hoy con un salto de entrada) | Sí | 2-3 días | Igual que A. Las clausuras en ejecución son idénticas; tiene 2 instrucciones más por bucle |

**Recomendación: A.** Es la más corta y reutiliza lo que la VM ya hace. C daría el mismo tiempo de ejecución con un programa algo más largo.

## 3. Semántica (forma A, cuerpo no anulable)
- **Prioridad (leftmost-first):** no cambia. `x+` voraz es `x (x+ | ε)`, y `split(L, out)` prueba otra iteración antes de salir, el mismo orden que hoy tras la primera copia. El perezoso invierte el `split`, como hoy.
- **Alternancia dentro del cuerpo:** sus `split` internos no cambian; la arista hacia atrás vuelve al inicio del cuerpo, como hoy vuelve a la segunda copia.
- **Guarda de iteración vacía (RepeatMatcher):** J se limita a cuerpos **no anulables**, que no pueden iterar vacíos.
  - En el programa sin grupos, un cuerpo anulable que itera ya es inelegible (`nullable_repeat`).
  - En el etiquetado, el cuerpo anulable usa el producto de fases (`Iteration.product`) y se queda como hoy.
- **Grupos dentro de `x+`:** cada iteración sigue empezando con `clear` (D4), también la primera, igual que la copia obligatoria de hoy.
- **Diferencial del prototipo** (programas sin grupos, modo code unit, sin prefiltros, `exec` desde cada índice y límites comparados):

  | Corpus | Programas reescritos | Diferencias |
  |---|---|---|
  | f2c | 780 | 0 |
  | f2c-2 | 3.018 | 0 |
  | npm | 533 | 0 |

  Son 4.331 programas y 12,2 M de ejecuciones. **No se probó en el prototipo:** la VM etiquetada, el modo code point y UTF-16. Eso lo cubren los diferenciales del gate al implementar.

## 4. Coste real
- **Qué se ahorra:**
  - el programa pierde `m+1` instrucciones por cada `x+`/`x{n,}` (en los corpus: 1.810 + 7.287 + 1.348 instrucciones sobre 4.331 programas);
  - en ejecución, cuando el bucle cuelga del inicio, cada posición evita avanzar la copia sembrada: en el e-mail, 0,83 hilos y 0,84 pruebas de conjunto menos por byte.
- **Dónde aplica:**
  - `x+` y `x{n,}` (`n ≥ 1`), voraces y perezosos;
  - no aplica a `x*` ni a `x?` (ya tienen una sola copia) ni a `x{n,m}` (desenrollado).
- **Ganancia:**
  - **e-mail: 1,28× medido** (no 1,4-1,7×, como estimaba el informe anterior); frente a V8 pasa de 2,2× a ~1,7× por detrás;
  - `[A-Z][a-z]+`: 1,00×;
  - denso: 1,00×.
- **Cuántos programas:**

  | Corpus | Programas simples en la VM | Reescritos | Con el bucle en la clausura del inicio (los que ganan de verdad) |
  |---|---|---|---|
  | f2c | 2.871 | 27 % | **11,4 %** |
  | f2c-2 | 9.991 | 30 % | **10,4 %** |
  | npm | 4.297 | 12 % | **2,6 %** |

  Los programas etiquetados no se midieron.

## 5. Riesgos
- **Snapshot de bytecode:** 0 pares cambian. `tests/snapshots/bytecode.txt` es el bytecode del backtracker (tier2), y J solo toca el `Program` de T0.
- **Tests que dependen de la forma actual:** ninguno.
  - Los `expectProgram` de `compile.zig` no tienen un `x+` de cuerpo no anulable. El único `+` es `(a*)+` etiquetado, anulable, que se queda como hoy.
  - `prefilter.zig` y `pikevm.zig` comparan resultados, no formas.
  - Hay que añadir tests de forma para `a+`, `a+?`, `(ab)+` etiquetado y `a{2,}`.
- **Prefiltros:**
  - `literal` y `class_run` salen del HIR y no cambian;
  - `first` recorre el programa desde el pc 0 hasta las instrucciones que consumen, que son las mismas. Como el programa queda más corto, alguno más cabrá en su límite de escaneo, lo que solo puede añadir prefiltros.
- **LookLinear:** su memo guarda por posición si hay match anclado (`existsAnchoredMatch`). No depende de la forma del programa, así que no se invalida.
- **Diferenciales del gate:**
  - `pfdiff` (VM frente al backtracker, con la referencia de slots `pfdiff-slots.tsv`), `t1diff`, `lldiff` y `differential-v8` deben quedar idénticos, porque J no cambia resultados;
  - `ivdiff` y `lbdiff` no pasan por programas afectados de forma distinta.
- **API:** ninguna. Todo es interno a `tier0`.

## 6. Recomendación y estimación
- **Hacer J con la forma A,** limitada a `max == null`, `min ≥ 1` y cuerpo no anulable (sin producto de fases), en la VM simple y en la etiquetada.
- **Estimación: 2-3 días:**
  - `emitRepeat` y sus tests: medio día;
  - comprobar la VM etiquetada y el modo code point: 1 día;
  - gate completo y bench antes/después: 1 día.
- **Expectativa honesta:** J no quita lo grotesco del e-mail. Da 1,28× en el e-mail y en los patrones que empiezan por `x+` (~10 % de los de f2c, ~3 % de los de npm), y nada en el resto. Es barata y de bajo riesgo, pero lo que cambia la situación del e-mail es B (el literal interior) y la del denso es C (Shift-And), del informe anterior.

## 7. Patrones del corpus que se beneficiarían
- **Los que empiezan por una clase o un carácter repetido con `+`,** a veces tras una alternancia. Por ejemplo, el e-mail del bench: `[\w.+-]+@…`, y las formas `\w+…`, `[a-z0-9]+…`, `\d+…` al inicio.
- **Conteos:** 327 (f2c), 1.038 (f2c-2) y 111 (npm) programas simples tienen el bucle reescrito en la clausura del inicio. El resto de los reescritos (453, 1.980 y 422) solo ahorran instrucciones del programa, sin ganancia medida en ejecución.

## 8. Resultado de la implementación
- **Forma emitida** (`Builder.emitRepeat`, cuerpo no anulable, `max == null`, `min ≥ 1`): `x^(n-1) L: x; split(L, out)`; perezoso `split(out, L)`; con grupos `L: clear; save; x; save; split(L, out)`. `a+` queda `0: char 'a' / 1: split 0, 2 / 2: match`.
- **Diferencial propio** (base frente a J, VM simple y etiquetada, `u`/`v`, WTF-8 y UTF-16, `execAt` desde cada índice): 9.130 programas reescritos (3.811 etiquetados, 1.360 `u`/`v`), 25,1 M de ejecuciones, 0 diferencias.
- **Bench** (10 rondas intercaladas, la mejor por caso): e-mail 46,2 → 59,2 MB/s (1,28×). Denso: mismo programa, 71.625.679 frente a 71.625.683 instrucciones (callgrind); el 0,92× del bench es ruido.
- **Binario:** +512 B (ReleaseFast), +336 B (ReleaseSmall).
