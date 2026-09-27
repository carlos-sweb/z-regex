# F0c: el diseño por capas y su evidencia

Este documento cuenta por qué z-regex está organizado por capas (Tiers) y qué dijo la
medición F0c sobre esa decisión. Es un documento de razonamiento: la hipótesis de partida,
los datos que la confirman o la corrigen, y las decisiones de plan que salen de ellos. Los
números vienen de la medición de F0c (commit `636d3e2`, fila F0c de
[REGEX_TIERS_PLAN.md](REGEX_TIERS_PLAN.md)); lo que es inferencia está marcado como tal.

## 1. La hipótesis inicial (antes de medir)

El punto de partida fue una intuición: la mayor parte del uso real de las expresiones
regulares es simple. Literales, clases de caracteres, cuantificadores, anclas y alternancia
cubrirían en torno al 70 % de los patrones; alrededor de un 20 % necesitaría Unicode (`u`,
`v`, `\p{…}`, case folding completo), y solo un 10 % usaría lo que obliga a un motor con
vuelta atrás: retroreferencias y lookaround. Es la hipótesis 70/20/10 (§5.6 del plan).

De esa intuición sale la forma del motor. Si el 70 % simple no necesita nada del 30 %
restante, no debería pagar por ello:

- **Un solo frontend.** Un parser, un HIR y un `analyze()` que decide, para cada patrón, el
  Tier mínimo que lo puede ejecutar, con sus razones.
- **T0 (regular):** ejecución lineal (Pike VM, y la VM tagged cuando hay grupos), sin
  backtracking, sin tablas Unicode y sin folding completo.
- **T1 (Unicode):** en el diseño, **no es un ejecutor propio**: es el mismo `Program` y la
  misma VM de T0 con capas de datos encima (conjuntos Unicode, Canonicalize, `\q{}`). Hoy,
  hasta que se haga F5, los patrones T1 todavía corren en el backtracker.
- **T2 (experto):** el backtracker, para lo que no es regular (retroreferencias,
  lookaround).

Es decir: tres Tiers, dos familias de ejecutores (las VM lineales de T0, que T1 reutiliza, y
el backtracker de T2), y la elección automática del Tier mínimo.

El plan fijó desde el principio que la hipótesis no era un supuesto: se mediría antes de
decidir el orden de las fases siguientes (F5, Unicode; F6a, T2 con pila explícita).

## 2. La verificación empírica (F0c)

**Qué se midió.** Se tomaron 500 paquetes de npm con versiones fijadas
(`scripts/f0c/packages.txt`). `scripts/f0c/extract.mjs` recorre sus archivos `.js`, `.mjs` y
`.cjs` con acorn y extrae los literales `/…/flags` y las llamadas `RegExp(…)` y
`new RegExp(…)` cuyo patrón (y flags) son literales. Cada patrón se clasifica con
`analyze()` (`zig build f0c -- corpus.tsv`). Resultado: **7.690 regex únicas y 53.787
ocurrencias**.

| | T0 | T1 | T2 |
|---|---|---|---|
| Hipótesis | 70 % | 20 % | 10 % |
| npm, por patrón único | 68,9 % | 27,1 % | 4,0 % |
| npm, ponderado por ocurrencia | 68,2 % | 30,2 % | 1,6 % |
| test262 (aparte, sesgado) | 10,4 % | 85,0 % | 4,6 % |

**Qué se confirmó y qué se corrigió.**

- **Confirmado: T0 domina.** Un 68,2 % ponderado (68,9 % único) está muy cerca del 70 %
  supuesto. La mayor parte de las regex que se escriben en aplicaciones son regulares.
- **Corregido: T1 pesa más.** Un 30,2 % ponderado, no un 20 %: Unicode pesa alrededor de un
  50 % más de lo que se suponía.
- **Corregido: T2 pesa mucho menos.** Un 1,6 % ponderado, no un 10 %: retroreferencias y
  lookaround aparecen unas 6 veces menos de lo supuesto. Por patrón único es un 4,0 %, así
  que los patrones T2 existen pero se repiten poco.

El reparto real, ponderado, se parece más a 70/30/2 que a 70/20/10.

## 3. El hallazgo inesperado: test262 frente al uso real

test262, la suite de conformidad del estándar, da un reparto casi opuesto: 10,4 % T0,
85,0 % T1 y 4,6 % T2. No es un error de medición, sino otra población: test262 existe para
ejercitar los bordes del spec (Unicode, `u`/`v`, `\p{…}`, casos límite de la gramática), y
por eso está lleno de patrones T1. Las regex de los paquetes de npm resuelven problemas
concretos (validar, tokenizar, limpiar texto) y son mayoritariamente regulares.

La consecuencia es que **la conformidad con el spec y la cobertura del uso real miden cosas
distintas**. Un motor que pasa mucho de test262 no por eso ejecuta bien lo que la gente
escribe, y al revés. z-regex necesita las dos métricas, por separado: test262 para la
corrección y un corpus de uso para decidir prioridades. Mezclarlas habría llevado a
priorizar Unicode por encima de todo, que es lo que test262, por sí solo, sugeriría.

## 4. La consecuencia para el diseño

**La arquitectura por capas queda justificada por los datos, con matices.**

- **T0 cubre alrededor del 68 % del uso** y lo hace con el ejecutor más simple: lineal, sin
  tablas Unicode, sin folding completo y sin backtracking. Es la capa que más código real
  toca, y es la que ya está cerrada.
- **T1 cubre casi un tercio.** Como en el diseño T1 no tiene ejecutor propio, sino que
  añade datos al `Program` de T0, ese 30 % se gana sin duplicar el ejecutor. *Inferencia:*
  esto hace de F5 la fase con mejor relación entre uso cubierto y código nuevo.
- **T2 cubre el 1,6 % ponderado.** Es la capa más cara de implementar bien (pila explícita,
  presupuestos de pasos, lookbehind) y la que menos uso real justifica.

**Reglas de decisión que salen de los datos.**

- **F5 (Unicode) va antes que F6a (T2).** Dos reglas independientes dan el mismo resultado:
  T2 ponderado es 1,6 %, por debajo del umbral del 15 % que habría adelantado F6a; y T1
  ponderado es 30,2 %, en el umbral del 30 % que prioriza F5. Esta decisión ya está
  registrada en el plan.
- **El plan B de F6b (publicar sin lookbehind) es más defendible.** El lookbehind es solo
  una parte de un 1,6 % que ya es pequeño; el desglose por feature de F0c (fila F0c del
  plan) lo sitúa por debajo de lookahead y retroreferencias. Si F6b agota su timebox,
  publicar sin él afecta a muy poco uso real. *Inferencia:* la decisión de intentar F6b
  completo se justifica mejor por completitud del spec que por uso.

## 5. Metodología y limitaciones

Lo que este corpus permite concluir tiene límites claros:

- **Son 500 paquetes de npm, no todo npm.** La selección favorece paquetes populares; su
  perfil (mucha lógica de utilidades, parsing y validación) puede no representar a las
  aplicaciones finales, que no se publican en npm.
- **Solo JavaScript.** El extractor lee `.js`, `.mjs` y `.cjs`; **no lee archivos `.ts`**.
  El TypeScript solo entra a través de lo que los paquetes publican ya compilado a JS. Las
  regex de código TypeScript que no se publica compilado no están medidas.
- **Solo regex estáticas.** Un `RegExp(…)` cuyo patrón se construye en tiempo de ejecución
  (concatenación, variables, templates con sustituciones) no se cuenta. *Inferencia:* esos
  patrones podrían tener otro reparto, por ejemplo más escapes de texto del usuario (T0).
- **Frecuencia estática, no de ejecución.** La ponderación por ocurrencia supone que un
  patrón que aparece 1.000 veces en el código pesa 1.000 veces más. Es discutible (una
  regex en un bucle caliente pesa más que mil en código muerto), pero es lo más cercano al
  uso real que se puede medir sin telemetría del host. Por eso se publican las dos métricas.
- **test262 va aparte** y no se usa para decidir prioridades, solo para medir corrección.
- **Reproducibilidad.** El TSV crudo no se conserva en el repo (son fragmentos de paquetes
  con licencias diversas). Se reconstruye con los 500 paquetes fijados en
  `scripts/f0c/packages.txt`, `scripts/f0c/extract.mjs` y `zig build f0c`.
- **No medido:** otros ecosistemas (código de navegador sin publicar, Deno, código
  propietario), y el corpus público de regex de investigación que el plan mencionaba (su
  disponibilidad y su licencia no se verificaron).

**Qué se puede concluir:** en código JavaScript publicado y popular, la mayoría de las
regex son regulares, Unicode es la segunda necesidad con diferencia, y las features que
exigen backtracking son raras. **Qué no:** cuánto tiempo de ejecución consume cada Tier, ni
cómo es el reparto fuera de npm.
