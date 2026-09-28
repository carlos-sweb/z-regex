# Cierre de F5a: pendientes y análisis

Documento de cierre de F5a, antes de F6a. Solo análisis: no hay cambios de código. Las
cifras salen de la rama `claude/trusting-ride-po3bt8` (commits `10ae137`, `372df0b`,
`1fc70ab`) y de herramientas del scratchpad (diferencial `t1diff`, árbitro con Node 22 /
V8 12.4), descritas en cada sección.

## 1. Qué entregó F5a

| Commit | Contenido | Resultado |
|---|---|---|
| `10ae137` F5a(1) | Tablas regeneradas desde UCD 17.0.0 (fijado; copia `unicodetools` del Consortium) con `PropertyAliases.txt` y `DerivedNormalizationProps.txt`: alias cortos de binarias, alias de valores de General_Category, alias extra de Script, `LC`, `Changes_When_NFKC_Casefolded` | test262 2856 → 2966/3017 (110 entradas de `property-escapes/generated`) |
| `372df0b` F5a(2) | `Cn`/`Unassigned`, `C` con Cn, `Script=Unknown` (`sc`/`scx`), `Katakana_Or_Hiragana` vacío | 2966 → **2974/3017** (98,6 %), igual en UTF-16 y WTF-8 |
| `1fc70ab` F5a(3) | Los patrones T1 cuyas features T1 son solo `u` y `\p{…}` van a la VM de T0 (modo code point); `force_tier = .unicode`; sin análisis de prefiltros en `u`/`v` | 6.716 de 14.061 patrones T1 de los corpus a la VM; `execAt` +67 % a +117 % en los casos T1 del bench; `differential-v8` −6 divergencias, 0 nuevas (`diff-F5a.json`) |

Compilación de los T1 enrutados: 2,1–2,6× frente a `.expert` en los patrones mínimos
(`\p{L}` 0,81 frente a 0,37 µs), 1,2–1,9× en los mayores; aceptado con el nuevo límite de
§7.2 ("≤ 2× o ≤ +2 µs"). Binario (`.so`, con strip): ReleaseFast 933.504 → 965.552 B
(+3,4 %), ReleaseSmall 520.296 → 552.120 B (+6,1 %).

## 2. Bugs previos (encontrados en F5a, no introducidos por F5a)

### Bug A: `\p{…}` sin `u` se lee como propiedad

- **Sintaxis:** `/\p{L}/`, `/\P{Lu}/`, `/[\p{L}]/`, sin `u` ni `v`.
- **zregex hoy:** `lexer.zig:1021` (`parseUnicodeProperty`) solo cae a la letra `p` cuando
  no hay un `{Nombre}` bien formado; con `{Nombre}` bien formado devuelve el token de
  propiedad **sin consultar `unicode_mode`**. Efectos: `/\p{L}/` iguala letras;
  `/\p{Bogus}/` da `UnknownUnicodeProperty` (error de compilación); `analyze()` clasifica
  el patrón como T1 cuando es T0, y desde F5a(3) corre en la VM con la misma lectura
  (la misma que el backtracker).
- **V8:** `\p` es la letra `p` y `{L}` es texto: `/\p{L}/.test("p{L}")` es `true`,
  `/\p{L}/.test("a")` es `false`.
- **Spec:** sin `u`, Annex B (B.1.2) admite `\p` como IdentityEscape; `{L}` no es un
  cuantificador válido y se lee como literal (ExtendedPatternCharacter). zregex ya
  acepta `p{L}` como literal, así que la corrección sería local al lexer (y cambiaría la
  clasificación de esos patrones a T0). *Estimación, no verificada con código.*
- **Uso real:** 0 patrones en el corpus npm de F0c. 11.992 en el corpus sintético de
  F2c (derivado de test262 y del fuzz). test262 no tiene ningún `\p{…}` sin `u`.
- **Severidad:** baja en uso, alta en conformidad (cambia el resultado de un patrón válido
  y rechaza otros válidos).
- **Fase:** fix menor antes de F5b, o dentro de F5b (toca la clasificación de T1).
- **Estado: corregido antes de F6a** (commit "fix: \p without u is an identity escape;
  gc= takes only General_Category values"). Sin `u`/`v`, el lexer devuelve el escape de
  identidad antes de leer `{…}`. La condición es `code_units` (el "sin `u`/`v`" del
  patrón), no `unicode_mode`: el parser lo apaga en su lectura especulativa tras `[` y
  tras un `]` anidado, y `v` no lo activa. En los corpus de F2c (12.005 filas con
  `\p`/`\P` sin `u`/`v`): 4.471 pasan de T1 a T0; 31 pasan a SyntaxError (`[\p{L}-z]`,
  `[É-\p{Lu}]`…: el rango queda invertido, y V8 rechaza los 31 con "Range out of
  order"); 669 siguen en T1 por otra razón (661 `i` Unicode, 8 contadores grandes). En
  npm (F0c), 0. Los 18 patrones sin `u` de las 29 divergencias de §3 pasan a T0.

### Bug B: `[\p{L}--a]` con `v` se rechaza

- **Sintaxis:** una resta de conjuntos cuyo operando derecho es un solo carácter.
- **zregex hoy:** `InvalidClassSetOperand` (`parser.zig:1044`, `parseClassSetOperand`).
  `[\p{L}--[a]]` sí compila.
- **V8:** acepta `/[\p{L}--a]/v` y `/[\p{L}--[a]]/v`.
- **Spec:** ClassSetOperand incluye ClassSetCharacter, así que `a` es un operando válido.
- **Severidad:** baja (0 usos de operaciones de conjuntos en npm; los tests de `v` de
  test262 están saltados).
- **Fase:** F5c.

### Bug C: `\p{gc=Alphabetic}` se acepta

- **Sintaxis:** el prefijo `gc=`/`General_Category=` seguido del nombre completo de una
  propiedad binaria.
- **zregex hoy:** se acepta. Está en la resolución del nombre
  (`properties.resolveUnicodeProperty`: tras quitar el prefijo, `stringToEnum` acepta
  cualquier valor del enum, binarias incluidas), no en el lowering ni en un early error
  aparte. Los alias cortos de binarias sí se rechazan con prefijo (`\p{gc=Alpha}`).
- **V8:** SyntaxError.
- **Spec:** `General_Category=` solo admite valores de General_Category (tabla de
  valores de ECMA-262); con otro valor es un early error.
- **test262:** ningún caso con `gc=` y una binaria; los 146 tests no generados de
  `property-escapes` pasan.
- **Severidad:** baja.
- **Fase:** fix menor, F5c o antes.
- **Estado: corregido antes de F6a** (el mismo commit que A). Con prefijo solo se aceptan
  valores de General_Category y sus alias (`LC`, `Cn`/`Unassigned`, `Letter`, `punct`…,
  como V8); las binarias, `ASCII`, `Any` y `Assigned` dan SyntaxError.

### Punto D: índice en mitad de un par de surrogates con `u`

- **Caso:** sujeto UTF-16, patrón con `u`, `execAt` con un índice que cae en el
  surrogate de cola de un par.
- **zregex hoy (los dos motores):** toma el índice como posición y ve un surrogate de
  cola suelto.
- **V8 y spec:** RegExpBuiltinExec toma "el carácter que se obtuvo del elemento
  lastIndex", es decir, el par entero: la búsqueda empieza en el inicio del par.
- **test262:** `exec/u-lastindex-adv.js` no está en el baseline de la suite de motor.
- **Severidad:** media para un host JS que implemente `lastIndex` sobre `execAt`; no la
  mide ningún gate actual.
- **Fase:** por decidir (es contrato de `execAt`, F3; candidato a F7 o antes si un host
  lo pide).

### Punto E: `\u{…}` sin `u` se lee como escape de code point

Encontrado al verificar el fix de A (diferencial de slots del corpus de F2c, árbitro
V8), no corregido.

- **Sintaxis:** `/\u{1F600}/`, `/\u{2}/`, sin `u` ni `v`.
- **zregex hoy (los dos motores):** `lexer.zig:1126` (`parseUnicodeEscape`) acepta
  `\u{H+}` como code point también sin `u`: `/\u{1F600}/` iguala `😀`.
- **V8 y spec:** sin `u`, `\u{` no es RegExpUnicodeEscapeSequence; `\u` es la letra `u`
  (Annex B, IdentityEscape) y `{1F600}` es texto; `{2}` sí es un cuantificador:
  `/\u{2}/.test("uu")` es `true`, `/\u{1F600}/.test("u{1F600}")` es `true`.
- **Dónde se vio:** 11 ejecuciones de 2 patrones del corpus de F2c:
  `/\u{1F600}|(\p{Script=Greek}|…)*ß/m` (7; pasa a T0 con el fix de A) y
  `/[a-f0-9\w\s]\u{1F600}(?<n0>\B)*/` (4; ya era T0 y ya salían antes del fix). Los dos
  motores leen `😀` y V8 no (en el primero el backtracker agota pasos; en el segundo
  difieren solo en la captura vacía de `(\B)*`, la clase de iteración vacía ya
  conocida).
- **Severidad:** la misma clase que A (conformidad; uso real probablemente bajo).
- **Fase:** fix menor, como A, cuando se decida.

## 3. Las 29 divergencias VM contra backtracker

**Método.** `t1diff` (scratchpad): cada patrón T1 enrutado a la VM por F5a(3) (6.716, de
los corpus de F2c y npm) contra el backtracker forzado, en todos los slots, cada índice,
sticky y no, UTF-16 y WTF-8: 5.520.552 ejecuciones. Difieren 29 patrones, en 3.260
ejecuciones por encoding (las mismas en los dos; la re-ejecución tras el último cambio de
F5a(3) dio un archivo idéntico). Árbitro: V8 con la flag `d` para los índices de los
grupos, en tres pasos:

1. Directo: 947 ejecuciones.
2. `\p{…}` sin `u` (V8 lo lee como letra): cada `\p`/`\P` se sustituye por la clase
   explícita que calcula V8 con `/\p{…}/u` sobre 0..0xFFFF, exacta en modo code unit
   (que es el de zregex sin `u`, surrogates incluidos), y se ejecuta sin `u`: 2.270.
3. Índice en mitad de un par con `u` (punto D): el surrogate de cabeza se sustituye por
   U+FFFF para que V8 vea el mismo surrogate de cola suelto que zregex (ninguno de esos
   patrones distingue U+FFFF de un surrogate): 43 (48 contando las que el paso 1 ya
   había resuelto).

**Resultado.**

| Grupo | Patrones | Ejecuciones |
|---|---|---|
| (a) V8 da la razón a la VM | **29** | **3.260** |
| (b) V8 da la razón al backtracker | 0 | 0 |
| (c) V8 no puede arbitrar | 0 | 0 |

Todas las diferencias son de capturas o de límites en patrones con grupos cuantificados
que pueden igualar vacío: el backtracker no reinicia los grupos en cada iteración y
acepta iteraciones vacías, lo mismo que F4b encontró en T0 (V8 dio allí la razón a la VM
en 4.471 + 270.101 ejecuciones y 0 al backtracker). Uno de los casos está fijado como
test con el valor de V8 (`tests/t0_tests.zig`, "a group reset per iteration").

Los 29 patrones (flags tras la barra; "directo", "clase" y "par" = paso del arbitraje):

| Patrón | Ejecuciones | Paso |
|---|---|---|
| `/(\.{0})*\p{Nd}\D[\wéa-f\s]{2,}?\|/s` | 2 | clase |
| `/-{0,1}?(\D*)+(.)/u` | 184 | directo + par |
| `/\p{Script=Greek}+(?:(é\t(?:\S{2,}\.É{1,3})\|))*/` | 14 | clase |
| `/(?<n0>\/*é\W?\|\x41?σ{0,1})*ß/u` | 3 | directo |
| `/\p{Nd}*0\|(\t{0}){0,1}[À-Ö\wÉa]/` | 165 | clase |
| `/([0-9](?:(\t?){1,}b{0}\p{Script=Greek}{2,}ſ)\|k{0,1}){0,1}/` | 304 | clase |
| `/((?<n0>(?:😀\/ß\/)ß{1,}\|…)+k\p{ASCII}[^\]éa]{1,3}\|)?(?:\x41σ(k{0,1})(\S*\b)\|[^z\p{Lu}]a{2,})*\n{0,1}?/` | 306 | clase |
| `/\p{Script=Greek}(?<n0>\u{1F600}é_\.\|){0,1}/` | 14 | clase |
| `/[-a-fÀ-Ö]\u{1F600}\/{0,1}(\p{scx=Latin}+_*)*\|((?:aé\|)?(?<n0>σ{1,3}\p{Script=Greek})\|)((?<n1>Σ) {1,3}\|){0,1}/` | 306 | clase |
| `/(\s*?){1,3}[^a0-9\w]\|(\p{L}{0}?éσ{1,}?\|k^){2}/` | 9 | clase |
| `/(ß{0,1}?😀\0-\|)?\|(\W^)\W/u` | 306 | directo + par |
| `/.{2}^\p{Script=Greek}\|\S\p{ASCII}(?<n0>_{2}?Z{1,3}\|){0,1}/` | 122 | clase |
| `/É*\/*(?<n0>\P{Lu}*?\|É\w{1,}?)?/` | 306 | clase |
| `/\P{Lu}(?:(\b\|ſ_){1,}?){0,1}/` | 103 | clase |
| `/(\t[\p{Lu}Aa]\|)*\p{L}{1,3}/u` | 176 | directo + par |
| `/\P{Lu}(σ{1,}?\|[\SéÀ-Ö]*?)*0/su` | 2 | directo |
| `/$\/?\|b??\/{0,1}?(?<n0>(\p{Nd}\p{L}\|)?\|σ{1,3}[É\d]{2,}\s)/` | 252 | clase |
| `/(a??)*\p{ASCII}{0,1}?0/` | 14 | clase |
| `/(\*{1,3}?)\W{1,3}[^éA\p{Lu}\S]{2}?\|\u{1F600}(\b)*/u` | 10 | directo |
| `/(?<n0>\p{Script=Greek}?)+/` | 12 | clase |
| `/((?:(\s??\ba{0,1}?\|\S){2})?\p{Nd})/` | 6 | clase |
| `/[-À-ÖA]\|(Σ*?){1,3}/su` | 2 | directo |
| `/[\p{Lu}0-9\dÀ-Ö]*?(\B\Bσ??)*\|\D\*/su` | 170 | directo + par |
| `/É(\*??)?/u` | 3 | directo |
| `/[^](\p{ASCII}?)?\|\0/su` | 118 | directo + par |
| `/(\s[\w\p{Lu}À-Öé]?\|Z{0,1}?){1,3}.\S{2}/` | 13 | clase |
| `/(\n{0}?\|_\B\s)?😀{1,}?/su` | 16 | directo + par |
| `/(\p{L}{0,1}s{0})*/s` | 152 | clase |
| `/[^--\d]{0}(\p{scx=Latin}\|)*/` | 170 | clase |

(Un patrón aparece abreviado con `…`; completo en la salida de `t1diff`.) 18 de los 29
no tienen `u`: eran T1 solo por el bug A, y con su fix pasan a T0 (`t1diff` queda en
11 patrones, los 11 con `u`).

## 4. Qué queda para F5b

Folding Unicode con `i`, que hoy sigue en el backtracker:

- literales no ASCII bajo `i` (`/é/i`, el caso del paquete atípico de F0c);
- folding de conjuntos: clases negadas, `\s`/`\W`/`\S` bajo `i`, rangos no ASCII y
  `\p{…}` dentro de clases (hoy no se pliegan: limitación conocida);
- `iu`/`iv` sobre texto ASCII (`s`/`ſ`, `k`/K Kelvin), que `analyze()` manda a T1;
- `\w`/`\b` bajo `ui`;
- Canonicalize correcto: `toUppercase` simple sin `u`, simple case folding con `u`, como
  órbitas generadas desde `CaseFolding.txt` (hoy solo hay parejas de `UnicodeData.txt`).

## 5. Qué queda para F5c

- `v` completo: los 275 tests de `unicodeSets` siguen saltados por
  `scripts/test262/features.json` (`"regexp-v-flag": "F5"`);
- `\q{…}` (no existe en el parser) y propiedades de strings (`RGI_Emoji`, …), con datos
  de `emoji-sequences.txt` y `emoji-zwj-sequences.txt`;
- el bug B (el C se corrigió antes de F6a);
- el patrón T1 que queda en `diff-F5a.json` (1 de 471).

## 6. Qué queda para F7

- Contadores grandes (16 regex con `{n,m}` > 100 en el corpus; 2 sobre el presupuesto de
  desenrollado): se mantiene `PatternTooLarge`.
- Coste fijo de `tier0.compile` (tablas de clausuras, `follow`): afecta a T0 desde F4a y
  a T1 desde F5a; no bloqueante.
- El punto D, si no se adelanta.
