# F0c: el diseño por capas y su evidencia

Este documento cuenta por qué z-regex está organizado por capas (Tiers) y qué dijo la
medición F0c sobre esa decisión. Es un documento de razonamiento: la hipótesis de partida,
los datos que la confirman o la corrigen, y las decisiones de plan que salen de ellos. Los
números vienen de la medición de F0c (commit `636d3e2`, fila F0c de
[REGEX_TIERS_PLAN.md](../REGEX_TIERS_PLAN.md)); lo que es inferencia está marcado como tal.

**Resumen.** La primera medición de F0c dio T0/T1/T2 = 68,2/30,2/1,6 % ponderado (68,9/27,1/4,0
por patrón único); el desglose posterior ([F0C_T1_BREAKDOWN.md](F0C_T1_BREAKDOWN.md)) la
corrige: un solo paquete de datos de locale llevaba el 96 % del peso de T1. Sin él, el
reparto es **91,7/3,9/4,4 ponderado** (85,6/8,3/6,0 único): T0 domina aún más, y T1 y T2
pesan parecido. La decisión F5/F6a queda **abierta** (§4).

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
| npm sin el paquete atípico (§2.1), único | 85,6 % | 8,3 % | 6,0 % |
| npm sin el paquete atípico, ponderado | 91,7 % | 3,9 % | 4,4 % |

**Qué se confirmó y qué se corrigió** (en la primera medición; el desglose de §2.1 cambia
las dos correcciones):

- **Confirmado: T0 domina.** Un 68,2 % ponderado (68,9 % único) está muy cerca del 70 %
  supuesto. La mayor parte de las regex que se escriben en aplicaciones son regulares.
- **Corregido: T1 pesa más.** Un 30,2 % ponderado, no un 20 %: Unicode pesa alrededor de un
  50 % más de lo que se suponía.
- **Corregido: T2 pesa mucho menos.** Un 1,6 % ponderado, no un 10 %: retroreferencias y
  lookaround aparecen unas 6 veces menos de lo supuesto. Por patrón único es un 4,0 %, así
  que los patrones T2 existen pero se repiten poco.

La primera medición sugería 70/30/2; con el desglose, el reparto se parece más a 90/4/4.

### 2.1 El outlier de T1

Un paquete (datos de locale: nombres de meses y días en decenas de idiomas, como regex
cortas con `i`) aporta el 36 % de las regex únicas, el 69 % de las ocurrencias y el 96 % del
peso de T1. Sin él, el reparto ponderado es 91,7/3,9/4,4. T2 aparece en más paquetes que T1
(75 frente a 56, de 262 con alguna regex) y pesa más por ocurrencias; por patrón único, T1
sigue por delante (8,3 % frente a 6,0 %). En los dos Tiers, la mediana es de 2 regex por
paquete; la media de T1 (8,9) es mayor que la de T2 (4,9) por dos o tres paquetes grandes.
Son regex reales pero generadas, no escritas a mano: por eso se dan las dos lecturas.

### 2.2 Dentro de T1, sin el outlier

- **`u` sin más:** 43–49 % de T1. 193 de esas 201 regex tienen texto solo ASCII.
  *Inferencia:* muchas usan `u` por costumbre.
- **`i` sobre conjuntos** (clases negadas, `\s`, `\W`, rangos): 35–39 %. Es la sub-feature
  Unicode real más común.
- **`\p{…}`:** 13–14 % (General_Category, Script y binarias).
- **`v`:** 10 regex, ninguna con operaciones de conjuntos.
- **`\q{}` y propiedades de strings:** 0.
- **Contadores > 100:** 16 regex en todo el corpus (de 7.690).

### 2.3 Metodología del desglose

El corpus se regeneró desde `scripts/f0c/packages.txt` en 41 s y reproduce F0c exactamente
(7.690 únicas, 53.787 ocurrencias, el mismo histograma). `analyze()` no distingue los tipos
de `\p`, ni `\q{}`, ni los contadores, así que cada patrón T1 se vuelve a parsear con
`@eslint-community/regexpp` en `scripts/f0c/t1_breakdown.mjs`. No se tocó `src/`,
`build.zig` ni el motor.

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

- **T0 cubre entre el 68 % (corpus completo) y el 92 % (sin el paquete atípico) del uso**
  con el ejecutor más simple: lineal, sin tablas Unicode, sin folding completo y sin
  backtracking. Es la capa que más código real toca, y ya está cerrada.
- **T1 cubre un 3,9 % ponderado sin el paquete atípico** (30,2 % con él). Como en el diseño
  T1 no tiene ejecutor propio, sino que añade datos al `Program` de T0, lo que cubre se gana
  sin duplicar el ejecutor; su parte más usada (`u` sin más y `\p`) es también la más barata.
- **T2 cubre un 4,4 % ponderado sin el paquete atípico** (1,6 % con él) y está en 75 de los
  262 paquetes con regex. Es la capa más cara de implementar bien (pila explícita,
  presupuestos de pasos, lookbehind).

**Reglas de decisión que salen de los datos.**

- **F5 (Unicode) o F6a (T2) primero: pendiente de revisión con los datos corregidos.** La
  primera medición sostenía "F5 antes que F6a" con dos reglas: T2 ponderado < 15 % (1,6 %) y
  T1 ponderado ≥ 30 % (30,2 %). Con los datos corregidos, T2 = 4,4 % (sigue por debajo del
  15 %) y T1 = 3,9 % (ya no llega al 30 %): ninguna de las dos reglas sostiene ya el orden.
  **La decisión queda abierta**; la registrada en el plan es anterior al desglose.
- **El plan B de F6b (publicar sin lookbehind) sigue siendo defendible, con menos
  margen.** El lookbehind es una parte de T2 (el desglose por feature de F0c lo sitúa por
  debajo de lookahead y retroreferencias), pero T2 pesa un 4,4 % ponderado sin el paquete
  atípico, no un 1,6 %. *Inferencia:* intentar F6b completo sigue justificándose más por
  completitud del spec que por uso.

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

**Qué se puede concluir:** en código JavaScript publicado y popular, la gran mayoría de las
regex son regulares; Unicode y las features que exigen backtracking son minoritarias y
pesan parecido. Un solo paquete puede distorsionar un corpus de 500: el análisis de outliers
es parte del trabajo. Ponderado y sin el paquete atípico, el uso de T1 es 3,9 %, no 30 %, y
el de T2 es 4,4 %, no 1,6 %: T2 pesa más que T1 por ocurrencias y por paquetes (por patrón
único, T1 sigue por delante). **Qué no:** cuánto tiempo de ejecución consume cada Tier, ni
cómo es el reparto fuera de npm.
