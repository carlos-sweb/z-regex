# Roadmap hacia 1.0 (aprobado el 2026-09-29)

## Qué es cerrar z-regex

Una **1.0 con la API congelada**, sin resultados incorrectos silenciosos conocidos,
conformidad completa hasta ES2023 y documentación honesta. No el 100 % de ECMA-262: F5c
completo (`\q{…}`, propiedades de strings, `v` con `i`) no entra.

**Regla del freeze:** toda sintaxis válida que zregex no implementa es
`error.UnsupportedFeature` (C API: `ZREGEXP_ERROR_UNSUPPORTED`, código 9). Así, lo que
llegue en 1.x solo quita casos de error y nunca añade errores nuevos: es aditivo.

## Etapas

| Etapa | Contenido | Días | Sale |
|---|---|---|---|
| **E0** | Errores honestos: `\q{…}` bajo `v` y los demás casos válidos no implementados dan `UnsupportedFeature`, y `v` aplica los early errors de `u`. `\k<nombre>` con nombres duplicados mira el grupo que participó (hallado con Node 24). Badge y README honestos. D2: medir test262 con Node 24 | 2–3 | v0.5.1 |
| **E1** | P1 (inventario de opcodes que consumen) → P2 (oráculo sin V8) → P3 (spike, decide si se sigue) → F6b completo. LookLinear hacia atrás, a 1.x | 13–17 | v0.6.0 |
| **E3** | F7c: API (namespace `internal`, quitar `Optimizer`, `opt_level` y `LOOP`, regla de errores), documentación (`ARCHITECTURE.md`, `PROJECT_STRUCTURE.md`, `KNOWN_LIMITATIONS.md` dividido en limitaciones e historial, `README.es.md`), benchmarks re-medidos, gate | 7–9 | **v1.0.0** |
| 1.1+ | Bug B y encadenado de `v`, LookLinear hacia atrás, laxitud de sintaxis bajo `v` | — | — |

**E2 (modificadores ES2025) no se hace:** decisión del 2026-09-29, pendientes hasta nuevo
aviso (`docs/plans/F7.md`, Decisiones 4). Desde E0 son `UnsupportedFeature`.

**Total hasta 1.0:** 22–29 días.

## Por qué este orden

- **E0 primero:** es lo más barato, quita el único resultado incorrecto silencioso conocido
  y fija los nombres de error, del que depende el freeze.
- **E1 después:** es obligatorio (el lookbehind es ES2018) y es el mayor riesgo, así que
  conviene saber pronto si el spike falla.
- **E3 al final:** congela y describe lo construido.
- **En paralelo:** D2 durante E0; los benchmarks mientras se escribe la documentación de E3.

## Puntos de parada si se acaba el presupuesto

1. **Tras E0 (v0.5.1):** shippable y honesto, sin resultados incorrectos conocidos. Es la
   parada mínima.
2. **Tras P3:** si el spike dice que no, se para con B′ y se documenta el lookbehind
   variable como `UnsupportedFeature`.
3. **Tras E1 (v0.6.0):** ES2023 completo, sin freeze.
4. **Tras E3 (v1.0.0):** el cierre.

## Forma de trabajo

Plan → implementación → gate → reporte → commit solo con la luz verde del usuario.
