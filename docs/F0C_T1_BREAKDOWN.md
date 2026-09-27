# F0c: qué usa T1 (desglose por sub-feature)

Análisis previo al plan de F5. Pregunta: dentro de las regex que `analyze()` clasifica como
T1, ¿qué sub-features aparecen, y con qué peso? Sirve para decidir el orden interno de F5 y
si los contadores grandes merecen trabajo propio. **No decide el plan de F5.**

El análisis encontró algo que afecta a F0c misma: **un solo paquete del corpus concentra
casi todo el peso de T1**. Por eso cada tabla aparece dos veces: con el corpus completo y
sin ese paquete (§3).

## 1. Metodología

- **Corpus:** el de F0c, regenerado desde cero con `scripts/f0c/extract.mjs` sobre los 500
  paquetes fijados en `scripts/f0c/packages.txt` (41 s de extracción). Reproduce F0c
  exactamente: 18.151 archivos, 7.690 regex únicas, 53.787 ocurrencias, y el mismo
  histograma (68,9/27,1/4,0 por únicas; 68,2/30,2/1,6 por ocurrencias). Solo 262 de los 500
  paquetes contienen alguna regex estática.
- **Tier:** `analyze()` sobre cada regex, con una herramienta en el scratchpad que vuelca
  Tier y features por patrón (no toca `src/` ni `build.zig`).
- **Sub-features:** `analyze()` no distingue un `\p` de General_Category de uno de Script,
  ni `\q{}`, ni contadores > 100. Cada patrón T1 se vuelve a parsear con
  `@eslint-community/regexpp` (4.12.2, ecmaVersion 2025) en
  `scripts/f0c/t1_breakdown.mjs`. regexpp parseó todos los patrones (0 fallos).
- **Pesos:** por patrón único, por ocurrencias, y por paquetes (suma, para cada patrón, del
  número de paquetes en que aparece; la misma métrica que F0c). Las categorías no son
  exclusivas; las combinaciones exclusivas están en §2.2.
- **Definiciones:**

  | Categoría | Criterio |
  |---|---|
  | u solo | las razones T1 de `analyze()` son solo `unicode_mode` (sin `\p`, sin `i` Unicode, sin `v`) |
  | `\p` General_Category | clave `General_Category`/`gc`, o valor suelto de categoría (`\p{L}`, `\p{Lu}`) |
  | `\p` Script | `Script`/`sc`/`Script_Extensions`/`scx` |
  | `\p` binaria | cualquier otra propiedad (`Alphabetic`, `Emoji`, `ID_Start`…); fila añadida |
  | `i` no ASCII simple | carácter literal > U+007F fuera de una clase, con `i` |
  | `i` folding de conjuntos | con `i`: clase negada, rango o miembro > U+007F, `\p`, `\s`/`\S`, `\W`/`\D` (y `\w` con `u`) |
  | `iu` sobre ASCII | `i`+`u` con texto solo ASCII: `analyze()` lo manda a T1 porque el folding Unicode relaciona `s`/`ſ` y `k`/`K` (Kelvin); fila añadida |
  | `v` | la flag `v`; subconteo de operaciones de conjuntos (`--`, `&&`) y clases anidadas |
  | `\q{}` / strings | `\q{…}` o propiedad de strings (`\p{RGI_Emoji}`) |
  | contador > 100 | `{n,m}` con `n` o `m` > 100 |

## 2. Resultados

### 2.1 Sub-features dentro de T1

Porcentajes sobre T1. "Completo": 2.083 únicas, 16.234 ocurrencias. "Sin el paquete
atípico": 408 únicas, 648 ocurrencias (§3). Dificultad: la escala dada para F5.

| Sub-feature | Único (completo) | Ponderado (completo) | Único (sin atípico) | Ponderado (sin atípico) | Dificultad F5 |
|---|---|---|---|---|---|
| u solo | 9,6 % (201) | 1,7 % (280) | 49,3 % | 43,2 % | 5 |
| `\p` General_Category | 1,3 % (27) | 0,3 % (45) | 6,6 % | 6,9 % | 4 |
| `\p` Script / Script_Extensions | 0,6 % (12) | 0,2 % (28) | 2,9 % | 4,3 % | 4 |
| `\p` binaria | 0,6 % (13) | 0,1 % (21) | 3,2 % | 3,2 % | — (no dada) |
| `i` no ASCII simple | 72,7 % (1.515) | 88,2 % (14.324) | 0,0 % | 0,0 % | 6 |
| `i` folding de conjuntos | 21,3 % (443) | 16,6 % (2.698) | 35,0 % | 39,2 % | 7 |
| `iu` sobre ASCII | 0,5 % (10) | 0,1 % (14) | 2,5 % | 2,2 % | — (no dada) |
| `v` (cualquier uso) | 0,5 % (10) | 0,1 % (12) | 2,5 % | 1,9 % | 7 |
| `v` con operaciones de conjuntos | 0 | 0 | 0 | 0 | 7 |
| `\q{}` / propiedades de strings | 0 | 0 | 0 | 0 | 8 |
| contador > 100 | 0,1 % (3) | 0,0 % (8) | 0,7 % | 1,2 % | 7–10 |
| más de una sub-feature a la vez | 7,2 % (149) | 7,3 % (1.193) | 2,2 % | 1,7 % | — |

La columna por paquetes da cifras muy parecidas a la de únicas en ambas variantes (está en
la salida de `t1_breakdown.mjs`).

### 2.2 Combinaciones exclusivas (sin el paquete atípico, % de T1 por únicas / ocurrencias)

u solo 49,3 / 43,2; folding de conjuntos solo 34,1 / 38,3; `\p` GC solo 5,1 / 5,7; `\p`
Script solo 2,9 / 4,3; `\p` binaria sola 2,7 / 2,9; `iu` sobre ASCII solo 2,0 / 1,9; `v` sola
1,2 / 1,1; `\p` GC + folding de conjuntos 1,0 / 0,9; contador > 100 solo 0,5 / 0,9; el resto
(combinaciones con `v`) 1,2 / 1,0. Con el corpus completo, `i` no ASCII simple sola es el
66,0 % de las únicas y el 81,0 % de las ocurrencias.

### 2.3 Contadores > 100 en todo el corpus

16 regex únicas de 7.690 (0,2 %), 32 ocurrencias: 7 en T0, 3 en T1, 6 en T2. Solo 2
superan el presupuesto de desenrollado de `analyze()` (1.000 copias) y por eso son T1.

## 3. El paquete atípico

Un paquete (datos de locale: nombres de meses y días en decenas de idiomas, compilados como
regex del tipo `^с` con `i`) aporta **2.802 de las 7.690 regex únicas (36 %) y 37.138 de las
53.787 ocurrencias (69 %)**. De sus regex, 1.113 son T0, 1.675 T1 y 14 T2. Concentra:

- el 99,9 % de las regex T1 "`i` no ASCII simple" (1.627 de 1.629 con texto no ASCII bajo
  `i`; todas aparecen en un único paquete);
- el 96,0 % de las ocurrencias de T1.

T1 aparece en 56 paquetes, pero el primero lleva el 96 % de su peso por ocurrencias. Sin
ese paquete (4.900 regex únicas, unas 16.650 ocurrencias), el histograma de F0c cambia:

| | T0 | T1 | T2 |
|---|---|---|---|
| F0c, corpus completo, único | 68,9 % | 27,1 % | 4,0 % |
| F0c, corpus completo, ponderado | 68,2 % | 30,2 % | 1,6 % |
| Sin el paquete atípico, único | 85,6 % | 8,3 % | 6,0 % |
| Sin el paquete atípico, ponderado | 91,7 % | 3,9 % | 4,4 % |
| Paquetes que usan el Tier (de 262 con regex) | 95,4 % | 21,4 % | 28,6 % |

**Consecuencia:** el "T1 = 30 %" de F0c es, sobre todo, un artefacto de un paquete. Sin él,
T1 y T2 pesan parecido (3,9 % frente a 4,4 % ponderado), y T2 aparece en más paquetes que T1
(75 frente a 56). No se publica el nombre del paquete (criterio de F0c sobre licencias);
se reproduce con los scripts.

Excluir un paquete entero es una decisión de método, no un dato: sus regex son uso real,
pero son datos generados, no regex escritas por personas. Por eso se dan las dos lecturas.

## 4. Interpretación

- **Qué domina T1.** Con el corpus completo, el `i` sobre literales no ASCII (72,7 % único,
  88,2 % ponderado), casi todo del paquete atípico. Sin él, dominan **u solo** (43–49 %) y
  **el folding de conjuntos con `i`** (~35–39 %); `\p` suma ~13–14 % (GC, Script y binarias
  juntas); `v` ~2 %.
- **"u solo" es barato.** 193 de sus 201 regex tienen texto solo ASCII (sin `\u{…}` ni
  escapes de surrogates), y ninguna usa `i`. *Inferencia:* en el diseño, T1 reutiliza la VM
  de T0 decodificando code points; estas regex necesitan poco más que ese modo (avance por
  code point, `.` y clases negadas sobre astrales, la gramática estricta de `u`).
- **Cuánto cubre un F5a (tablas + `\p` + `u`) sin folding.** Sin el paquete atípico: u solo
  + `\p` sin `i` ≈ 49,3 + 5,1 + 2,9 + 2,7 ≈ **60 % de T1 por únicas** (~56 % ponderado).
  Con el corpus completo, ~12 % de las únicas: el resto necesita folding.
- **Folding.** Es la otra mitad de T1 sin el atípico (~37–41 %, con `iu` sobre ASCII) y
  casi todo T1 con él. El folding de conjuntos (clases negadas, `\s`, `\W` bajo `i`) pesa
  más que el de literales en el uso escrito por personas.
- **`v` y `\q{}`.** 10 regex usan `v`, ninguna con operaciones de conjuntos, clases
  anidadas, `\q{}` ni propiedades de strings. En este corpus, el `v` completo no tiene uso;
  su valor es de conformidad (test262), no de uso.
- **Contadores > 100.** 16 regex en todo el corpus y solo 2 fuera del presupuesto de
  desenrollado. No justifican tocar la Pike VM.

## 5. Recomendación provisional (no es una decisión)

1. **Partir F5.**
   - **F5a:** modo `u` en la VM de T0 (code points), tablas y `\p` (General_Category,
     Script/Script_Extensions, binarias). Cubre ~56–60 % de T1 sin el atípico.
   - **F5b:** case folding con `u` y con `i` no ASCII, empezando por el folding de
     conjuntos (clases negadas, `\s`/`\W`, rangos), que es lo que más usan las regex
     escritas a mano; los literales no ASCII bajo `i` (el atípico) salen del mismo trabajo.
   - **F5c o posterior:** `v` completo (operaciones de conjuntos, anidación, `\q{}`,
     propiedades de strings). Uso medido: cero; se justifica por test262.
2. **Contadores grandes: diferir** (fuera de F5; F7 o cuando haya un caso real). Mantener
   el desenrollado con presupuesto y `PatternTooLarge`.
3. **Revisar el orden F5/F6a.** La decisión de F0c se apoyaba en T1 ≈ 30 %. Sin el paquete
   atípico, T1 (3,9 %) y T2 (4,4 %) pesan parecido y T2 está en más paquetes (28,6 % frente
   a 21,4 %). Ninguna de las dos reglas de §5.6 se dispara (T2 < 15 %, T1 < 30 %), así que
   los datos no obligan a cambiar el orden, pero **ya no lo sostienen con claridad**. A
   favor de F5a primero: es la parte barata y reutiliza la VM de T0. A favor de F6a: T2
   aparece en más paquetes. Es una decisión para el usuario.

## 6. Limitaciones

- Un solo corpus (500 paquetes populares de npm; 262 con regex) y solo JavaScript (`.js`,
  `.mjs`, `.cjs`); sin TypeScript sin compilar ni regex construidas en tiempo de ejecución.
- Frecuencia estática, no de ejecución.
- La sensibilidad a un solo paquete muestra que la métrica por ocurrencias es frágil con
  este tamaño de corpus; la de "paquetes que usan el Tier" es más robusta frente a datos
  generados.
- Las categorías se detectan sobre el AST de regexpp con criterios conservadores (p. ej.
  toda clase negada bajo `i` cuenta como folding de conjuntos, aunque en la práctica pueda
  no necesitar tablas nuevas).
- No se midió qué fracción del folding de conjuntos necesita la clausura completa de
  folding y cuál se resuelve con reglas simples; eso lo tendría que medir F5b.
