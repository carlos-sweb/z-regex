# zregex - Motor Moderno de Expresiones Regulares para Zig

[![Licencia: MIT](https://img.shields.io/badge/Licencia-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-402%2F402-brightgreen)](#)
[![Zig](https://img.shields.io/badge/zig-0.16.0-orange)](https://ziglang.org/)

[🇺🇸 English Version](README.md)

Un motor de expresiones regulares potente y rico en características, escrito en Zig con sintaxis similar a JavaScript y protección contra ReDoS.

## ✨ Características

- **🚀 Alto Rendimiento**: Máquina virtual basada en bytecode con ejecución optimizada
- **🛡️ Protección contra ReDoS**: Límites integrados de profundidad de recursión y pasos para prevenir backtracking catastrófico
- **📝 Sintaxis Compatible con JavaScript**: 168/168 (100%) de aprobación en una muestra de conformidad derivada de test262 (`zig build test-conformance`) — una medición real pero sesgada/pequeña, no un porcentaje de conformidad completo; ver [Known Limitations](docs/KNOWN_LIMITATIONS.md) para el desglose verificado característica por característica, y el [Plan de Compatibilidad ECMAScript](docs/ECMASCRIPT_COMPATIBILITY_PLAN.md) para el camino al 100%; ambos documentos disponibles solo en inglés
- **🔧 Cero Dependencias**: Implementación pura en Zig
- **✅ Bien Probado**: 402 tests exhaustivos que aseguran confiabilidad

## 🎯 Características Soportadas

### Assertions (100% Compatible con JS)
- ✅ `(?=...)` Lookahead positivo
- ✅ `(?!...)` Lookahead negativo
- ✅ `(?<=...)` Lookbehind positivo
- ✅ `(?<!...)` Lookbehind negativo

### Grupos (100% Compatible con JS)
- ✅ `(...)` Grupos de captura
- ✅ `(?:...)` Grupos sin captura
- ✅ `\1` a `\9` Referencias hacia atrás
- ✅ `(?<nombre>...)` Grupos de captura nombrados
- ✅ `\k<nombre>` Referencias nombradas

### Cuantificadores (100% Compatible con JS + Extensiones)
- ✅ `*`, `+`, `?` Cuantificadores básicos
- ✅ `*?`, `+?`, `??` Cuantificadores lazy
- ✅ `{n}`, `{n,}`, `{n,m}` Cuantificadores contados
- ✅ `{n}?`, `{n,}?`, `{n,m}?` Cuantificadores contados lazy
- ✅ `*+`, `++`, `?+` Cuantificadores posesivos (extensión)

### Clases de Caracteres
- ✅ `[abc]`, `[^abc]` Conjuntos de caracteres
- ✅ `[a-z]`, `[A-Z0-9]` Rangos de caracteres
- ✅ `[*&$.^+?(){}|]` Metacaracteres de regex como literales dentro de una clase
- ✅ `[a-c\d]` Clases abreviadas (`\d`/`\w`/`\s`/`\D`/`\W`/`\S`) como miembros de una clase
- ✅ `[^]` Clase vacía negada ("coincide con cualquier cosa", incluyendo salto de línea)
- ✅ `.` Cualquier carácter (excepto nueva línea)
- ✅ `\d`, `\D` Dígitos / no-dígitos
- ✅ `\w`, `\W` Caracteres de palabra / no-palabra
- ✅ `\s`, `\S` Espacios en blanco / no-espacios
- ✅ `\p{L}`, `\p{Lu}`, `\p{Letter}`, `\P{L}`, ... Escapes de propiedades Unicode General_Category
- ✅ `\p{White_Space}`, `\p{Alphabetic}`, `\p{Math}`, `\p{Dash}`, `\p{Hex_Digit}`, `\p{ID_Start}`, `\p{Emoji}`, `\p{ASCII}`, `\p{Any}`, `\p{Bidi_Mirrored}`, `\p{Assigned}`, y 39 más (50 en total, ver [Known Limitations](docs/KNOWN_LIMITATIONS.md)) Escapes de propiedades binarias Unicode
- ✅ `\p{Script=Greek}`, `\p{sc=Han}`, `\p{Script=Latin}`, `\p{Script=Grek}` (alias corto), ... (los 174 scripts de Unicode + alias cortos) Escapes de propiedad Script de Unicode
- ✅ `\p{Script_Extensions=Latin}`, `\p{scx=Grek}`, ... Escapes de propiedad Script_Extensions de Unicode (membresía por codepoint más amplia que Script, ej. acentos combinantes)
- ✅ `[\p{L}\d]`, `[\P{Alphabetic}a-z]`, `[^\p{L}\d]` `\p{...}`/`\P{...}` como miembro de una clase de caracteres (General_Category, propiedad binaria, Script, o Script_Extensions; hasta 4 por clase)
- ✅ `[A--B]`, `[A&&B]` (con `CompileOptions.v`) Operaciones de conjuntos en clases de caracteres — diferencia e intersección, una por clase (`[\p{L}--[aeiou]]`, `[[a-z]&&[^x]]`)

### Anclajes
- ✅ `^` Inicio de cadena
- ✅ `$` Fin de cadena
- ✅ `\b` Límite de palabra
- ✅ `\B` No-límite de palabra

## 📦 Instalación

### Uso como Librería Zig

Agrega a tu `build.zig.zon`:

```zig
.dependencies = .{
    .zregex = .{
        .url = "https://github.com/tuusuario/zregex/archive/refs/tags/v1.0.0.tar.gz",
        .hash = "...",
    },
},
```

En tu `build.zig`:

```zig
const zregex = b.dependency("zregex", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zregex", zregex.module("zregex"));
```

> **Nota sobre C/C++**: zregex es una librería Zig-first y no distribuye una API C/C++
> soportada (sin headers, sin librería wrapper, sin artefactos de build para linkeo
> externo). Sí exporta un ABI C simple (`src/c_api.zig`, compilado como librería
> compartida vía `zig build shared`) que las herramientas propias del proyecto usan vía
> FFI — ver [`ECMASCRIPT_COMPATIBILITY_PLAN.md`](docs/ECMASCRIPT_COMPATIBILITY_PLAN.md)
> Fase 8 (en inglés). Si querés llamar a zregex desde C o C++, sos libre de escribir tus
> propios bindings contra esos símbolos exportados; no se provee ni mantiene ninguno acá.

## 🚀 Inicio Rápido

### Ejemplo en Zig

```zig
const std = @import("std");
const regex = @import("zregex");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Compilar un patrón regex
    var re = try regex.Regex.compile(allocator, "hola (mundo)");
    defer re.deinit();

    // Buscar una coincidencia
    const text = "hola mundo";
    const result = try re.find(text);
    if (result) |match| {
        defer match.deinit();

        std.debug.print("Match: {s}\n", .{match.group(text)});
        std.debug.print("Grupo 1: {s}\n", .{match.getCapture(1, text).?});
    }
}
```

## 📚 Documentación de la API

### API de Zig

#### `Regex.compile(allocator, pattern) !Regex`
Compila un patrón regex.

**Parámetros:**
- `allocator`: Asignador de memoria
- `pattern`: Cadena del patrón regex

**Retorna:** Objeto `Regex` compilado

**Ejemplo:**
```zig
var re = try Regex.compile(allocator, "\\d{3}-\\d{3}-\\d{4}");
defer re.deinit();
```

#### `regex.find(input) !?MatchResult`
Encuentra la primera coincidencia en la cadena de entrada.

**Parámetros:**
- `input`: Cadena donde buscar

**Retorna:** `MatchResult` si se encuentra, `null` en caso contrario

#### `regex.findAll(input) !std.ArrayListUnmanaged(MatchResult)`
Encuentra todas las coincidencias en la cadena de entrada.

#### Métodos de `MatchResult`
- `match.group(input) []const u8` — la subcadena completa coincidente
- `match.getCapture(index, input) ?[]const u8` — grupo de captura por número (base 1)
- `match.getNamedCapture(nombre, input) ?[]const u8` — grupo de captura por nombre, para
  grupos `(?<nombre>...)`; retorna `null` si el nombre no existe o el patrón no tiene grupos nombrados

#### `regex.test_(input) !bool`
Prueba si el patrón coincide con **toda** la cadena de entrada (coincidencia completa anclada, no búsqueda de subcadena — usa `find`/`findAll` para buscar subcadenas).

#### `regex.replace(allocator, input, replacement) ![]u8`
Reemplaza solo la primera coincidencia con `replacement` (como `String.prototype.replace` de JS con un regex no global). Retorna una cadena recién asignada (una copia de `input` si no hay coincidencia). `replacement` soporta la sintaxis de sustitución de JS: `$$` (`$` literal), `$&` (coincidencia completa), `` $` ``/`$'` (texto antes/después de la coincidencia), `$1`-`$99` (grupos de captura numerados), y `$<nombre>` (grupos de captura nombrados). Un grupo que existe en el patrón pero no participó se sustituye como cadena vacía; un `$N`/`$<nombre>` sin grupo correspondiente se deja como texto literal (igual que JS).

#### `regex.replaceAll(allocator, input, replacement) ![]u8`
Reemplaza todas las coincidencias con `replacement` (como `String.prototype.replaceAll` de JS). Misma sintaxis de sustitución que `replace`.

## 🔧 Compilar desde el Código Fuente

### Prerequisitos
- Zig 0.16.0 o posterior

### Pasos de Compilación

```bash
# Clonar el repositorio
git clone https://github.com/tuusuario/zregex.git
cd zregex

# Ejecutar tests
zig build test

# Compilar (instala la librería compartida usada internamente por el harness de
# conformidad -- ver la nota sobre C/C++ arriba; no es un artefacto de build soportado
# públicamente)
zig build

# Compilar para plataformas específicas
zig build -Dtarget=x86_64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=x86_64-macos
zig build -Dtarget=aarch64-linux
```

## ⚡ Rendimiento

zregex utiliza una máquina virtual basada en bytecode para matching eficiente de patrones:

- **Compilación Rápida**: Los patrones se compilan a bytecode optimizado
- **Ejecución Eficiente**: Interpretación directa de bytecode con overhead mínimo
- **Protección ReDoS**: Límites configurables previenen backtracking catastrófico
- **Eficiente en Memoria**: Gestión cuidadosa de memoria con arena allocators

### Benchmarks

```
Patrón: \d{3}-\d{3}-\d{4}
Entrada: "Llámame al 555-123-4567"
Tiempo: ~150ns por match

Patrón: (?<=\$)\d+
Entrada: "Precio: $100, $200, $300"
Tiempo: ~200ns por match
```

## 🛡️ Seguridad

### Protección contra ReDoS

zregex incluye protección integrada contra ataques de Denegación de Servicio por Expresiones Regulares (ReDoS):

- **Límite de Profundidad de Recursión**: Por defecto 1000 (configurable)
- **Límite de Pasos**: Por defecto 1,000,000 (configurable)
- **Detección Automática**: Los patrones que exceden los límites fallan gracefully

### Configuración

```zig
const options = regex.CompileOptions{
    .max_recursion_depth = 500,
    .max_steps = 100_000,
    .case_insensitive = true,
};

var re = try regex.Regex.compileWithOptions(allocator, pattern, options);
```

## 📖 Ejemplos de Patrones

### Validación de Email
```zig
const email_pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}";
```

### Matching de URL
```zig
const url_pattern = "(?:https?://)?(?:www\\.)?[a-zA-Z0-9.-]+\\.[a-z]{2,}(?:/\\S*)?";
```

### Número de Teléfono
```zig
const phone_pattern = "\\+?\\d{1,3}?[-.\\s]?\\(?\\d{1,4}\\)?[-.\\s]?\\d{1,4}[-.\\s]?\\d{1,9}";
```

### Tags HTML
```zig
const html_tag_pattern = "<(\\w+)[^>]*>.*?</\\1>";
```

### Extraer Precios
```zig
const price_pattern = "(?<=\\$)\\d+(?:\\.\\d{2})?";
```

### Validación de Contraseñas
```zig
// Al menos 8 caracteres, 1 mayúscula, 1 minúscula, 1 dígito
const password_pattern = "^(?=.*[a-z])(?=.*[A-Z])(?=.*\\d).{8,}$";
```

## 🤝 Contribuir

¡Las contribuciones son bienvenidas! Por favor, siéntete libre de enviar un Pull Request.

### Configuración de Desarrollo

```bash
# Clonar y compilar
git clone https://github.com/tuusuario/zregex.git
cd zregex
zig build test

# Ejecutar tests específicos
zig test src/regex.zig
```

### Estilo de Código
- Seguir las convenciones de la biblioteca estándar de Zig
- Agregar tests para nuevas características
- Actualizar documentación
- Ejecutar `zig fmt` antes de commitear

## 📄 Licencia

Este proyecto está licenciado bajo la Licencia MIT - ver el archivo [LICENSE](LICENSE) para detalles.

## 🙏 Agradecimientos

- Inspirado por JavaScript RegExp y PCRE
- Construido con [Zig](https://ziglang.org/)
- Gracias a todos los contribuidores

## 📬 Contacto

- GitHub Issues: [Reportar bugs o solicitar características](https://github.com/tuusuario/zregex/issues)
- Discussions: [Hacer preguntas y compartir ideas](https://github.com/tuusuario/zregex/discussions)

## 🗺️ Hoja de Ruta

### Completado ✅
- [x] Matching básico de caracteres
- [x] Clases y rangos de caracteres
- [x] Cuantificadores (greedy, lazy, possessive)
- [x] Grupos con y sin captura
- [x] Referencias hacia atrás
- [x] Assertions lookahead
- [x] Assertions lookbehind
- [x] Anclajes y límites de palabra
- [x] Protección ReDoS
- [x] Grupos de captura nombrados `(?<nombre>...)` y referencias `\k<nombre>`, incluyendo nombres duplicados en ramas de alternancia mutuamente excluyentes (ej. `(?<x>a)|(?<x>b)`)
- [x] `replace()`/`replaceAll()` en la API pura de Zig, incluyendo sustitución `$1`/`$&`/`` $` ``/`$'`/`$<nombre>`
- [x] Escapes de propiedades Unicode `\p{...}`/`\P{...}` (General_Category, ej. `\p{L}`, `\p{Lu}`, `\p{Letter}`; 50 propiedades binarias, ej. `\p{Alphabetic}`; los 174 scripts de Unicode + alias cortos vía `\p{Script=...}`/`\p{sc=...}`, ej. `\p{Script=Grek}`; Script_Extensions vía `\p{Script_Extensions=...}`/`\p{scx=...}`; y como miembro de una clase de caracteres, ej. `[\p{L}\d]`)
- [x] `case_insensitive` con folding del par de mayúsculas/minúsculas de un carácter literal no-ASCII (standalone o como único miembro de una clase, ej. `café`/`CAFÉ`, `[é]`/`É`)
- [x] Flag `v` (`CompileOptions.v`): operaciones de conjuntos en clases de caracteres `[A--B]`/`[A&&B]`, una por clase, ej. `[\p{L}--[aeiou]]`, `[[a-z]&&[^x]]`

### En Progreso 🚧
- [ ] Flag `u` (`CompileOptions.unicode`): rechaza un escape no reconocido como error de compilación; `\x`/`\u`/`\c`/`\k`/`\p` mal formados y referencias hacia atrás inválidas todavía no son estrictos
- [ ] Flag `v`: operaciones de conjuntos encadenadas/anidadas, literales multi-string `\q{...}`, puntuadores reservados propios de `v`, estrictez completa de `u`
- [ ] Soporte completo UTF-8/UTF-16

### Futuro 🔮
- [ ] Patrones condicionales `(?(condición)sí|no)`
- [ ] Patrones recursivos
- [ ] Compilación JIT
- [ ] Soporte para target WASM
- [ ] Optimizaciones de rendimiento

## 📊 Estadísticas del Proyecto

- **Líneas de Código**: ~11,000
- **Cantidad de Tests**: 402 tests exhaustivos
- **Tasa de Éxito de Tests**: 100%
- **Compatibilidad JavaScript**: 168/168 (100%) en una muestra de conformidad derivada de test262 (ver [Known Limitations](docs/KNOWN_LIMITATIONS.md) para lo que esta medición cubre y lo que no)
- **Plataformas Soportadas**: Linux, macOS, Windows, *BSD
- **Dependencias**: Cero (Zig puro)
- **Lenguaje**: Zig 0.16.0+

## 🏆 Comparación de Características

| Característica | zregex | JavaScript | PCRE2 | RE2 |
|----------------|---------|------------|-------|-----|
| Lookahead | ✅ | ✅ | ✅ | ✅ |
| Lookbehind | ✅ | ✅ | ✅ | ❌ |
| Referencias atrás | ✅ | ✅ | ✅ | ❌ |
| Grupos sin captura | ✅ | ✅ | ✅ | ✅ |
| Cuantificadores lazy | ✅ | ✅ | ✅ | ✅ |
| Cuantificadores posesivos | ✅ | ❌ | ✅ | ❌ |
| Protección ReDoS | ✅ | ❌ | ❌ | ✅ |
| Unicode | 🚧 | ✅ | ✅ | ✅ |

---

**Hecho con ❤️ usando Zig**

**Versión**: 0.1.0
**Estado**: Desarrollo Activo
**Versión de Zig**: 0.16.0+
