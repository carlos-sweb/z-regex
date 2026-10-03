# Roadmap hacia 1.0 (aprobado el 2026-09-29)

## Qué es cerrar z-regex

Una **1.0 con la API congelada**, sin resultados incorrectos silenciosos conocidos,
conformidad completa hasta ES2023 y documentación honesta. No el 100 % de ECMA-262: F5c
completo (`\q{…}`, propiedades de strings, `v` con `i`) no entra.

> **Corrección (cierre de E1, `c5aa744`):** «conformidad completa hasta ES2023» no es exacto.
> Tras E1 falta, del lookbehind (ES2018), el que se evalúa hacia atrás bajo `u`/`v` y el que
> lleva un lookaround dentro de un cuerpo hacia atrás; los dos son `UnsupportedFeature` y van
> a 1.x. La 1.0 cubre hasta ES2023 salvo esos dos casos: sin `u`/`v` solo falta el lookaround
> dentro de un lookbehind hacia atrás; con `u`/`v`, además, el lookbehind hacia atrás. De
> ES2024, `v` parcial; de ES2025, los nombres de grupo duplicados (los modificadores no).

**Regla del freeze:** toda sintaxis válida que zregex no implementa es
`error.UnsupportedFeature` (C API: `ZREGEXP_ERROR_UNSUPPORTED`, código 9). Así, lo que
llegue en 1.x solo quita casos de error y nunca añade errores nuevos: es aditivo.

## Etapas

| Etapa | Contenido | Días | Sale |
|---|---|---|---|
| **E0** | Errores honestos: `\q{…}` bajo `v` y los demás casos válidos no implementados dan `UnsupportedFeature`, y `v` aplica los early errors de `u`. `\k<nombre>` con nombres duplicados mira el grupo que participó (hallado con Node 24). Badge y README honestos. D2: medir test262 con Node 24 | 2–3 | v0.5.1 |
| **E1** | P1 (inventario de opcodes que consumen) → P2 (oráculo sin V8) → P3 (spike, decide si se sigue) → F6b completo. LookLinear hacia atrás, a 1.x | 13–17 | v0.6.0 |
| **F7c** (antes E3) | API (namespace `internal`, quitar `Optimizer`, `opt_level` y `LOOP`, contrato en `docs/API.md`), `v` con `i` honesto, documentación (`ARCHITECTURE.md`, `PROJECT_STRUCTURE.md`, `KNOWN_LIMITATIONS.md` dividido en `LIMITATIONS.md` e `HISTORY.md`), benchmarks re-medidos, gate. Plan: `docs/plans/F7c.md` | 7–9 | **v0.7.0** |
| **T0 J+C+B** | Rendimiento de T0 sin cambios de API: `x+` sin cuerpo duplicado (J), Shift-And (C), salto al literal interno (B). Planes: `T0-J.md`, `T0-CB.md` | — | **v0.7.1** |
| **T0-A** | El DFA de T0 (ida e inverso, en compilación, con tope), con asserts y en code point, sin cambios de API. Planes: `T0-A.md`, `T0-A-precheck.md` | — | **v0.8.0** |
| **Producción** | 1–3 meses de uso real sobre v0.8.0 (0.8.x con arreglos), sin cambios de API | — | — |
| **1.0** | Si la producción no pide cambios de API: la misma API, con el freeze ya en vigor desde 0.7.0 | — | **v1.0.0** |
| 1.1+ | Bug B y encadenado de `v`, LookLinear hacia atrás, lookbehind hacia atrás bajo `u`/`v`, lookarounds anidados en un lookbehind hacia atrás | — | — |

**E2 (modificadores ES2025) no se hace:** decisión del 2026-09-29, pendientes hasta nuevo
aviso (`docs/plans/F7.md`, Decisiones 4). Desde E0 son `UnsupportedFeature`.

**Secuencia:** F7c → v0.7.0 → T0 J+C+B → v0.7.1 → T0-A → v0.8.0 → producción (1–3 meses) → v1.0.0. **Hasta v0.7.0:** 22–29 días de trabajo. Lo que queda tras 1.0: `ROADMAP_COMPLETE.md`.

## Por qué este orden

- **E0 primero:** es lo más barato, quita el único resultado incorrecto silencioso conocido
  y fija los nombres de error, del que depende el freeze.
- **E1 después:** es obligatorio (el lookbehind es ES2018) y es el mayor riesgo, así que
  conviene saber pronto si el spike falla.
- **F7c al final:** congela y describe lo construido, y sale como v0.7.0, no como 1.0.
- **Producción antes de 1.0:** el freeze rige desde v0.7.0; la 1.0 llega cuando el uso real
  confirma la API, no cuando termina la documentación.
- **En paralelo:** D2 durante E0; los benchmarks mientras se escribe la documentación de F7c.

## Puntos de parada si se acaba el presupuesto

1. **Tras E0 (v0.5.1):** shippable y honesto, sin resultados incorrectos conocidos. Es la
   parada mínima.
2. **Tras P3:** si el spike dice que no, se para con B′ y se documenta el lookbehind
   variable como `UnsupportedFeature`.
3. **Tras E1 (v0.6.0):** lookbehind completo en modo code-unit (fijo, variable, con capturas,
   con backreferences). ES2018 sin `u`; ES2023 sin lookbehind bajo `u`/`v` y sin lookarounds
   anidados. Esas dos van a 1.x.
4. **Tras F7c (v0.7.0):** la API congelada y documentada.
5. **Tras la producción (v1.0.0):** el cierre.

## Forma de trabajo

Plan → implementación → gate → reporte → commit solo con la luz verde del usuario.
