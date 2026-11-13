# DevDeck

[English](README.md)

Panel de control nativo para macOS (SwiftUI) que responde **“¿de dónde viene toda esta carga?”** y te deja actuar en un clic. Vive en una ventana, en la barra de menú, en una isla en vivo arriba de la pantalla y en un lanzador flotante. Interfaz en español, inglés y portugués; tema claro, oscuro o el del sistema.

## Qué hace

| Sección | Qué ves y qué puedes hacer |
|---|---|
| **Memoria y swap** | Si el swap está **dormido** (inofensivo) o **activo** (te frena), lectura/escritura por segundo, crecimiento MB/min, RAM comprimida y ratio, detección de *thrashing*, quién tiene memoria fuera de RAM (estimado) y quién lee del disco, y un plan concreto de qué cerrar. |
| **Historial** | Un resumen por minuto durante siete días: memoria y swap en el tiempo, quién usaba la memoria en cada minuto, los momentos en que llegó al límite y qué creció justo antes, y los procesos cuya memoria solo crece (posibles fugas), con la recomendación de reiniciarlos. |
| **Resumen** | RAM, presión de memoria, swap, CPU, disco. Gráfico apilado de memoria **por origen** (proyecto, agente de IA, navegador, Docker, app). Mayores consumidores con botón de cerrar. |
| **Puertos** | Cada puerto en escucha con el **proyecto, servidor (Next.js, Vite, tsx…) y contenedor Docker** que hay detrás (los puertos de Docker se mapean al proyecto por la etiqueta de compose). Abrir, reiniciar, detener. |
| **Proyectos** | Proyectos corriendo y descubiertos en disco. Por proyecto: servicios (árboles de procesos), puertos, RAM en el tiempo, contenedores, **límite de RAM**, cachés, scripts de `package.json`, comandos recordados y logs. |
| **Carga por origen** | Todos los procesos atribuidos a quien los lanzó. Los servidores MCP cuentan para el agente que los lanzó, no para el proyecto. Los Chrome headless muestran **quién los lanzó**. |
| **Cachés y disco** | `.next`, `node_modules`, `.turbo`, `target`, `.venv`… por proyecto, más cachés globales (npm, pnpm, uv, Homebrew, Xcode, Playwright, transcripts de agentes…) con su forma correcta de limpiar. |
| **Agentes de IA** | Qué agentes hay instalados y cuáles corren. **Trabajando ahora**: cada sesión abierta con su carpeta, si está trabajando o en espera, RAM, CPU, tokens y los **subagentes** que lanzó (activos y terminados). **Cuentas y límites**: las cuentas de Claude Code con su uso de 5 h, 7 días y por modelo, y cambio de cuenta con confirmación (vía [claude-swap](#agentes-de-ia) si está instalado); cuenta y plan de Codex. Tokens por día, por modelo y por proyecto de Claude Code, Codex, Devin, OpenCode y Gemini CLI. |
| **Herramientas** | Comandos de limpieza y mantenimiento listos para ejecutar (Docker, npm, pnpm, bun, yarn, uv, pip, Gradle, Homebrew, Xcode), solo de lo que tienes instalado. El copiloto puede proponerlos. |
| **Límites y alertas** | Reglas con “sostenido N segundos” y cooldown: avisar, matar, reiniciar o pedir diagnóstico a la IA. |
| **Copiloto IA** | Lanzador de comandos (**⌥⌘D** desde cualquier app, atajo configurable): busca comandos, proyectos y puertos, ↑↓ y ↵, **⌘K** para acciones. Al preguntar trabaja un **agente por turnos**: muestra su plan, las herramientas de lectura que usa y la respuesta; toda acción sale como tarjeta con **Aprobar / Rechazar**. Las conversaciones se guardan en un historial y sus tarjetas se pueden aprobar más tarde. |
| **Isla en vivo** | Píldora arriba al centro (sale del notch en los MacBook). Al hacer clic abre tableros: **Sistema** (RAM, CPU y swap con su historial), **Agentes** (tokens por hora y sesiones abiertas), **Cuentas** (límites y cambio de cuenta en dos clics) y **Copiloto** (plan y decisiones pendientes, que se aprueban ahí mismo). Se elige el tablero inicial y si se muestra siempre, solo cuando pasa algo, o nunca. |

### Reiniciar sin perder nada
Al detectar un servidor de desarrollo, DevDeck guarda su **comando, carpeta y variables de entorno** (vía `KERN_PROCARGS2`). Reiniciar = SIGTERM ordenado al árbol → espera a que el puerto quede libre → relanza exactamente igual, con los logs en `~/Library/Application Support/DevDeck/logs`. “Limpiar `.next` y reiniciar” hace lo mismo pero borrando la caché en medio.

### El copiloto

El agente responde en turnos (pensamiento, plan, herramientas, respuesta). Las herramientas de **lectura** se ejecutan solas: mayores consumidores, procesos de un grupo, puertos, swap, cachés, uso de agentes e información de un proyecto. Las **acciones** nunca se ejecutan solas; aparecen como tarjeta y esperan tu aprobación:

| Acción | Qué hace |
|---|---|
| Cerrar un grupo / matar un proceso | SIGTERM ordenado, con verificación de que el PID sigue siendo el mismo proceso. |
| Reiniciar un servicio | Mismo comando, carpeta y entorno. |
| Limpiar una caché | Si está en uso, detiene los servicios, la borra y los relanza. |
| Avisar si un grupo pasa de N MB | Crea una alerta. No reduce la memoria. |
| Reducir la RAM de Docker | Cambia el tamaño de la VM de Docker Desktop y lo reinicia. |
| Ejecutar una herramienta | Cualquier receta de la sección Herramientas; la tarjeta muestra el comando exacto y, al terminar, su salida. |

Cada tarjeta muestra el resultado al terminar. Al reabrir una conversación del historial, las tarjetas pendientes se pueden aprobar y las ya decididas se pueden volver a proponer; las que apuntan a un PID solo se aplican si ese proceso sigue vivo.

### Seguridad
- Nunca toca procesos del sistema, de otros usuarios ni a sí mismo. Las dependencias de un proyecto corriendo cuentan como “en uso”.
- Las acciones propuestas por la IA se validan contra el snapshot vivo: solo grupos, PIDs y rutas de caché que existen.
- El piloto automático “Aplicar lo seguro” solo cierra Chrome headless y borra cachés de build regenerables de proyectos parados.
- Si un servidor de desarrollo se cierra sin que DevDeck lo haya parado, sale una alerta que dice cuál fue (y si lo cerró un vigilante de RAM externo).
- Al motor de IA se envía un resumen **redactado**: rutas con `~`, tokens y claves en argumentos enmascarados, nunca variables de entorno.

## Instalar

Descarga `DevDeck.zip` de la [última versión](https://github.com/SeanLuis/devdeck/releases/latest), descomprímelo y mueve `DevDeck.app` a Aplicaciones. Está firmada y notarizada por Apple, y funciona en Mac con Apple silicon e Intel (binario universal). Requiere macOS 14 o posterior.

DevDeck comprueba una vez al día si hay versión nueva y te muestra las novedades; nunca instala nada sin tu clic.

### Compilar desde el código

```bash
./scripts/bundle.sh        # compila en release, firma ad-hoc e instala en ~/Applications/DevDeck.app
open ~/Applications/DevDeck.app
```

Para compilar: Xcode 16 o posterior (Swift 6). `UNIVERSAL=1 ./scripts/bundle.sh` genera el binario para Apple silicon e Intel.

## IA

Tres motores, a elegir en **Ajustes → IA**:

- **Claude Code** (por defecto si está instalado): usa tu sesión de `claude`, sin API key. Se ejecuta sin herramientas, sin servidores MCP y sin guardar historial. Con el modelo “default” un turno tarda unos 25 s; `sonnet` o `haiku` responden antes.
- **Codex**: usa tu sesión de `codex`, en modo solo lectura.
- **OpenAI API**: pega la key y se valida contra la API (queda en `~/Library/Application Support/DevDeck/secrets.json`, permisos 600).

Otros ajustes: piloto automático, diagnóstico automático en alertas, máximo de acciones y privacidad (enviar o no líneas de comando). El copiloto responde en el idioma de la aplicación.

## Agentes de IA

Todo se lee de lo que cada agente guarda en este Mac; nada sale de él.

| Agente | De dónde salen los tokens |
|---|---|
| Claude Code | `~/.claude/projects/**.jsonl` (los subagentes, de `<sesión>/subagents/`). Sesiones abiertas: `~/.claude/sessions/`. |
| Codex | `~/.codex/sessions/**.jsonl` |
| Devin | `~/.local/share/devin/cli/sessions.db` |
| OpenCode | `~/.local/share/opencode/opencode.db` |
| Gemini CLI | `~/.gemini/tmp/*/chats/*.json` |

Los archivos se leen de forma incremental (solo lo nuevo). Los límites reales de Claude Code (5 h, 7 días, por modelo) y el cambio de cuenta vienen de [claude-swap](https://github.com/realiti4/claude-swap) (`cswap`) cuando está instalado; sin él se muestra la cuenta actual y los tokens medidos en las últimas 5 h, porque Claude Code no publica su límite en disco. Codex solo informa del plan y, cuando los incluye en sus registros, de los porcentajes.

## Notificaciones

Si macOS tiene bloqueadas las notificaciones de DevDeck, la app muestra su propio aviso arriba a la derecha. Para usar las del sistema: **Ajustes → Notificaciones → Activar en Ajustes del Sistema**.

## Desarrollo

```bash
swift build
swift test                                # incluye un test real de capturar → matar → relanzar
.build/debug/DevDeck --dump               # qué ve el clasificador, en texto
.build/debug/DevDeck --snapshot /tmp/s [--demo] [--light] [--lang en|pt] [--only agents,rules] [--height 2000] [--with-ai]   # renderiza las pantallas a PNG
.build/debug/DevDeck --agent-smoke "pregunta"   # una conversación completa del agente, en texto
.build/debug/DevDeck --engine-smoke       # diagnóstico y chat con Claude Code y Codex
.build/debug/DevDeck --usage-dump         # tokens, sesiones, subagentes y cuentas de los agentes
.build/debug/DevDeck --ai-smoke           # verifica key, modelos y streaming contra la API real
~/Applications/DevDeck.app/Contents/MacOS/DevDeck --notify-test   # estado real de las notificaciones
```

Estructura:
- `Sources/DevDeckCore`: escaneo de procesos y puertos con libproc, estadísticas del sistema, detección de proyectos y frameworks, Docker, cachés, reglas, control de procesos y cliente de IA. Sin UI y con tests.
- `Sources/DevDeck`: la app SwiftUI (ventana, barra de menú, isla, lanzador, notificaciones).

Idiomas: los textos se escriben en español dentro de `L("…")`; las traducciones están en `Sources/DevDeckCore/L10n+English.swift` y `L10n+Portuguese.swift`, con el texto en español como clave. Un test comprueba que no falte ninguna.

Datos en `~/Library/Application Support/DevDeck/`: `settings.json`, `rules.json`, `alerts.json`, `recipes.json` (600), `caches.json`, `conversations.json`, `secrets.json` (600) y `logs/`.
