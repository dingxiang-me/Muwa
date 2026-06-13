<p align="center">
<img width="1920" height="1080" alt="muwa-techcrunch-1" src="https://github.com/user-attachments/assets/d7905005-71fe-41ba-b69f-e8968af29b5c" />
</p>

<h1 align="center">Muwa</h1>

<p align="center">
  <strong>Own your AI.</strong><br>
  Agents, memory, tools, and identity that live on your Mac. Built purely in Swift. Fully offline. Open source.
</p>

<p align="center">
  <a href="https://github.com/dingxiang-me/Muwa/releases/latest"><img src="https://img.shields.io/github/v/release/dingxiang-me/Muwa?sort=semver" alt="Release"></a>
  <a href="https://github.com/dingxiang-me/Muwa/releases"><img src="https://img.shields.io/github/downloads/dingxiang-me/Muwa/total" alt="Downloads"></a>
  <a href="https://github.com/dingxiang-me/Muwa/blob/main/LICENSE"><img src="https://img.shields.io/github/license/dingxiang-me/Muwa" alt="License"></a>
  <a href="https://github.com/dingxiang-me/Muwa/stargazers"><img src="https://img.shields.io/github/stars/dingxiang-me/Muwa?style=social" alt="Stars"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%20(Apple%20Silicon)-black?logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/OpenAI%20API-compatible-0A7CFF" alt="OpenAI API">
  <img src="https://img.shields.io/badge/Anthropic%20API-compatible-0A7CFF" alt="Anthropic API">
  <img src="https://img.shields.io/badge/Ollama%20API-compatible-0A7CFF" alt="Ollama API">
  <img src="https://img.shields.io/badge/MCP-server-0A7CFF" alt="MCP Server">
  <img src="https://img.shields.io/badge/Apple%20Foundation%20Models-supported-0A7CFF" alt="Foundation Models">
  <a href="https://huggingface.co/MuwaAI"><img src="https://img.shields.io/badge/%F0%9F%A4%97%20Hugging%20Face-MuwaAI-FFD21E" alt="Hugging Face"></a>
  <img src="https://img.shields.io/badge/PRs-welcome-brightgreen" alt="PRs Welcome">
</p>

<p align="center">
  <a href="https://github.com/dingxiang-me/Muwa/releases/latest/download/Muwa.dmg">Download for Mac</a> ·
  <a href="https://docs.muwa.ai">Docs</a> ·
  <a href="https://huggingface.co/MuwaAI">Models</a> ·
  <a href="https://discord.gg/muwa">Discord</a> ·
  <a href="https://x.com/MuwaAI">Twitter</a> ·
  <a href="https://github.com/dingxiang-me/muwa-tools">Plugin Registry</a>
</p>

---

## Inference is all you need. Everything else can be owned by you.

Models are getting cheaper and more interchangeable by the day. What's irreplaceable is the layer around them -- your context, your memory, your tools, your identity. Others keep that layer on their servers. Muwa keeps it on your machine.

Muwa is the AI harness for macOS. It sits between you and any model -- local or cloud -- and provides the continuity that makes AI personal: agents that remember, execute autonomously, run real code, and stay reachable from anywhere. The models are interchangeable. The harness is what compounds.

Works fully offline with local models. Connect to any cloud provider when you want more power. Nothing leaves your Mac unless you choose.

Native Swift on Apple Silicon. No Electron. No compromises. MIT licensed.

## Install

```bash
brew install --cask muwa
```

Or download the latest `.dmg` from [Releases](https://github.com/dingxiang-me/Muwa/releases/latest). After installing, launch from Spotlight (`⌘ Space` → "Muwa") or the CLI:

```bash
muwa-cli ui       # Open the chat UI
muwa-cli serve    # Start the server
muwa-cli status   # Check status
```

> Requires macOS 15.5+ and Apple Silicon.

## Agents

Agents are the core of Muwa. Each one gets its own prompts, memory, and visual theme -- a research assistant, a coding partner, a file organizer, whatever you need. Tools and skills are automatically selected via RAG search based on the task at hand -- no manual configuration needed. Everything else in the harness exists to make agents smarter, faster, and more capable over time.

Agents can also opt into a private encrypted database and a single self-scheduled next run -- see [Agent DB & Self-Scheduling](docs/AGENT_DB.md).

### Agent Loop

Every chat is an agent loop. Pick a working folder and the agent gets file, search, and git tools. Toggle the sandbox and it gets shell access in an isolated Linux VM. The model writes a markdown todo list, executes against it, and closes out with a verified summary -- all in the same chat window. See the [Agent Loop Guide](docs/AGENT_LOOP.md).

### Sandbox

Agents execute code in an isolated Linux VM powered by Apple's [Containerization](https://developer.apple.com/documentation/containerization) framework. Full dev environment -- shell, Python, Node.js, compilers, package managers -- with zero risk to your Mac.

Each agent gets its own Linux user and home directory. The VM connects back to Muwa (inference, memory, secrets) via a vsock bridge -- sandboxed but not disconnected. Extend with simple JSON plugin recipes, no Xcode or code signing required.

```
┌────────────────┐       ┌────────────────────────────┐
│    Muwa     │       │   Linux VM (Alpine)        │
│                │       │                            │
│  Sandbox Mgr ──┼───────┤→ /workspace  (VirtioFS)    │
│  Host API   ←──┼─vsock─┤→ muwa-host bridge       │
│                │       │                            │
│                │       │  agent-alice  (Linux user) │
│                │       │  agent-bob    (Linux user) │
└────────────────┘       └────────────────────────────┘
```

> Requires macOS 26+ (Tahoe). See the [Sandbox Guide](docs/SANDBOX.md) for configuration, built-in tools, and plugin authoring.

### Memory

Three layers -- identity, pinned facts, and per-session episodes -- plus a transcript fallback. Agents distill conversations once at session end (not on every turn), score what matters by salience, and surface at most one compact slice per request based on what you're actually asking. A background consolidator decays, merges, and evicts so memory stays sharp instead of bloating. Most turns inject ~800 tokens or less; many inject zero. See the [Memory Guide](docs/MEMORY.md).

### Privacy Filter

When you send to a cloud model, an on-device classifier — OpenAI's `openai/privacy-filter` (Apache-2.0, 1.5B params / 50M active sparse-MoE), served via the MLX conversion `mlx-community/openai-privacy-filter-bf16` (~2.8 GB) — detects names, emails, phones, URLs, addresses, dates, account numbers, and free-form secrets, alongside deterministic regex for SSN, credit cards, IBAN, AWS keys, GitHub tokens, and your own custom patterns. Each detection is shown in a review sheet with a scrubbed preview before sending; approved entities are swapped for stable `[PERSON_1]` / `[EMAIL_2]` placeholders, and streaming replies are unscrubbed back on the fly so the chat reads naturally. **Fail-closed**: if the post-scrub scan finds anything that leaked, the send is blocked. Verify wire-level redaction in the **Insights** panel — it captures the exact bytes the cloud saw. See the [Privacy Filter Guide](docs/PRIVACY_FILTER.md).

### Identity

Every participant -- human, agent, device -- gets a secp256k1 cryptographic address. Authority flows from your master key (iCloud Keychain) down to each agent in a verifiable chain of trust. Create portable access keys (`osk-v1`), scope per-agent, revoke anytime. See [Identity docs](docs/IDENTITY.md).

### Relay

Expose agents to the internet via secure WebSocket tunnels through `agent.muwa.ai`. Unique URL per agent based on its crypto address. No port forwarding, no ngrok, no configuration.

### Secure Channel

When two Muwa agents talk -- across your LAN or across the world through the relay -- the conversation is **end-to-end encrypted**: a forward-secret X25519 handshake authenticated by each agent's crypto identity, with every request, streamed token, and access key sealed in ChaCha20-Poly1305. The relay becomes a blind pipe that forwards ciphertext it cannot open; a man-in-the-middle cannot complete a handshake; replayed or truncated traffic is detected and refused; and there is no plaintext fallback an attacker can force. Zero configuration -- pairing is all it takes. See the [Secure Channel docs](docs/SECURE_CHANNEL.md).

## Models

The harness is model-agnostic. Swap freely -- your agents, memory, and tools stay intact.

### Local

Run Gemma 4, Qwen3.6, GPT-OSS, Llama, and more on Apple Silicon with optimized MLX inference. Muwa maintains its own [optimized model library on Hugging Face](https://huggingface.co/MuwaAI) with curated quantizations for the best quality-to-size ratio on Apple Silicon. Models stored at `~/MLXModels` (override with `OSU_MODELS_DIR`). Fully private, fully offline.

### Liquid Foundation Models

Muwa supports [Liquid AI's LFM](https://www.liquid.ai/models) family -- on-device models built on a non-transformer architecture optimized for edge deployment. Fast decode, low memory footprint, and strong tool calling out of the box.

### Apple Foundation Models

On macOS 26+, use Apple's on-device model as a first-class provider. Pass `model: "foundation"` in API requests. Tool calling maps through Apple's native interface automatically. Zero inference cost, fully private.

### Cloud

Connect to OpenAI, Anthropic, Gemini, xAI/Grok, [Venice AI](https://venice.ai), OpenRouter, Ollama, or LM Studio. Venice provides uncensored, privacy-focused inference with no data retention. Context and memory persist across all providers.

## MCP

Muwa is a full MCP (Model Context Protocol) server. Give any MCP-compatible client access to your tools with the command-based stdio bridge:

```json
{
  "mcpServers": {
    "muwa": {
      "command": "muwa-cli",
      "args": ["mcp"]
    }
  }
}
```

`muwa-cli mcp` starts a stdio MCP server for the client and proxies tool discovery/calls to your local Muwa HTTP server. In the other direction, Muwa can also act as an MCP client and aggregate tools from URL-based remote MCP providers. One-tap connect to ~25 well-known providers (Linear, Notion, GitHub, Vercel, Supabase, Sentry, Stripe, Cloudflare, ...) with auto OAuth 2.1 + Dynamic Client Registration, or paste an API key. The Remote MCP Providers UI is for HTTP/SSE MCP endpoints; it does not launch third-party `command`/`args` stdio providers. See the [Remote MCP Providers Guide](docs/REMOTE_MCP_PROVIDERS.md) for details.

## Tools & Plugins

```bash
muwa-cli tools install muwa.browser       # Install from registry
muwa-cli tools list                       # List installed
muwa-cli tools create MyPlugin --swift    # Create a plugin
muwa-cli tools dev com.acme.my-plugin     # Dev with hot reload
```

20+ native plugins: Mail, Calendar, Vision, macOS Use, XLSX, PPTX, Browser, Music, Git, Filesystem, Search, Fetch, and more. Plugins target the v3 host API surface — register HTTP routes, serve web apps, persist data in SQLite, dispatch agent tasks, and call inference through any model. Older v1/v2 plugins continue to load unchanged. See the [Plugin Authoring Guide](docs/plugins/README.md).

Document attachments keep structure where the file format exposes it: CSV/TSV tables, XLSX workbooks, PPTX decks, PDF page anchors, and rich document sections are parsed through the document adapter registry before they reach the agent.

## More

**Skills & Methods** -- Skills import reusable AI capabilities from GitHub repos or files, compatible with [Agent Skills](https://agentskills.io/). Full Claude plugins (skills, scheduled agents, slash commands, MCP providers, and `CLAUDE.md` context) can be imported from any GitHub repo and managed as a single bundle. Methods are learned workflows that agents save and reuse over time. All are automatically selected via RAG search -- no manual configuration needed. See [Skills Guide](docs/SKILLS.md) and [Claude Plugins](docs/CLAUDE_PLUGINS.md).

**Automation** -- Schedules run recurring tasks in the background. Watchers monitor folders and trigger agents on file changes.

**Voice** -- On-device transcription via FluidAudio on Apple's Neural Engine. Voice input in chat, VAD mode with wake-word activation, and a global hotkey to transcribe into any app. No audio leaves your Mac. See [Voice Input Guide](docs/VOICE_INPUT.md).

**Shortcuts, Spotlight & Siri** -- Muwa ships App Intents, so "Ask Muwa" and "Run Muwa Agent" are available system-wide the moment you install -- no setup. Ask your active agent and get the reply inline, or kick off a custom agent in the background. See [App Intents Guide](docs/APP_INTENTS.md).

**Developer Tools** -- Server explorer, MCP tool inspector, inference monitoring, plugin debugging. See [Developer Tools Guide](docs/DEVELOPER_TOOLS.md). For the inference scheduler, model leases, continuous-batching engine, and feature flags that tune them, see [Inference Runtime](docs/INFERENCE_RUNTIME.md).

## Telemetry

Muwa collects **anonymous, aggregated usage analytics** via [Aptabase](https://aptabase.com), an [open-source](https://github.com/aptabase/aptabase), privacy-first analytics project. We collect this only to understand broad user trends and preferences (how the app is used and where people run into friction) so we can make it better. It **never** includes your chats, prompts, files, model outputs, or keys. There are no accounts or device profiles, so events aren't tied to you.

For the exact, exhaustive list of every event and property we capture — and an explicit list of what we never collect — see [Telemetry & KPIs](docs/TELEMETRY.md).

### Crash reporting

**Crash and app-hang reporting** via [Sentry](https://sentry.io) is a **separate, independent** switch from usage analytics. Unlike analytics it's **opt-out** — on by default and active from launch — because crash reports carry no personal information and are what let us fix real bugs; you can turn it off anytime in **Settings → Privacy → Send Crash Reports**. It's limited to crash and hang diagnostics — no performance tracing, profiling, failed-request capture, network breadcrumbs, screenshots, or personal information; we drop the user object and device hostname from every event, on top of disabling PII. It needs a DSN to be configured, so like analytics it's off by default in source builds.

### Local development

Telemetry is **off by default in source builds**: with no key, the SDK is never initialized and every event is a silent no-op, so you can build and contribute without any of this. To enable it locally:

1. Create `App/Muwa/Secrets.xcconfig` (gitignored — never commit it) with the keys you want:
   - `APTABASE_APP_KEY = A-XX-...` — your Aptabase app key (analytics).
   - `SENTRY_DSN` — your Sentry project DSN (crash reporting). Optional; omit it to leave crash reporting off. **Escape the scheme slashes**: an `.xcconfig` treats `//` as a comment, so a raw `https://…` DSN gets silently truncated to `https:`. Add a slash variable and reference it:

     ```
     SENTRY_SLASH = /
     SENTRY_DSN = https:$(SENTRY_SLASH)$(SENTRY_SLASH)yourPublicKey@o123.ingest.sentry.io/456
     ```

2. In Xcode, add `Secrets.xcconfig` to the project (**no** target membership), then under **Project → Info → Configurations → Debug → Muwa** set "Based on Configuration File" to **Secrets**.
3. Clean build (⇧⌘K) and relaunch.

The keys flow `Secrets.xcconfig` → `$(APTABASE_APP_KEY)` / `$(SENTRY_DSN)` build settings → `AptabaseAppKey` / `SentryDSN` in `Info.plist`. Debug builds report to Aptabase's **Debug** bucket (enable the Debug view on the dashboard to see them) and to Sentry's `debug` environment, so local testing never pollutes production data.

## Compatible APIs

Drop-in endpoints for existing tools:

| API       | Endpoint                                      |
| --------- | --------------------------------------------- |
| OpenAI    | `http://127.0.0.1:1337/v1/chat/completions`   |
| Anthropic | `http://127.0.0.1:1337/anthropic/v1/messages` |
| Ollama    | `http://127.0.0.1:1337/api/chat`              |

All prefixes supported (`/v1`, `/api`, `/v1/api`). Full function calling with streaming tool call deltas. `/chat/completions` keeps **strict OpenAI semantics** -- it returns `tool_calls` and the client executes them, so Muwa drops in cleanly behind harnesses that already manage their own tool loop. For server-side autonomous loops use `POST /agents/{id}/run`; to expose Muwa tools to remote MCP harnesses use `/mcp/tools` + `/mcp/call`. See [OpenAI API Guide](docs/OpenAI_API_GUIDE.md) for tool calling, streaming, and SDK examples. Building a macOS app that connects to Muwa? See the [Shared Configuration Guide](docs/SHARED_CONFIGURATION_GUIDE.md).

## CLI

```bash
muwa-cli serve --port 1337              # Start on localhost
muwa-cli serve --port 1337 --expose     # Expose on LAN
muwa-cli ui                             # Open the chat UI
muwa-cli status                         # Check status
muwa-cli stop                           # Stop the server
```

Homebrew auto-links the CLI, or symlink manually:

```bash
ln -sf "/Applications/Muwa.app/Contents/MacOS/Muwa" "$(brew --prefix)/bin/muwa-cli"
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   The Harness                       │
├──────────┬──────────┬────────────┬──────────────────┤
│ Agents   │ Memory   │ Agent Loop │ Automation       │
├──────────┴──────────┴────────────┴──────────────────┤
│              MCP Server + Client                    │
├──────────┬──────────┬───────────┬───────────────────┤
│ MLX      │ OpenAI   │ Anthropic │ Ollama / Others   │
│ Runtime  │ API      │ API       │                   │
├──────────┴──────────┴───────────┴───────────────────┤
│      Plugin System (v1 / v2 ABI) · Native Plugins   │
├──────────┬──────────┬───────────┬───────────────────┤
│ Identity │ Relay    │ Tools     │ Skills · Methods  │
├──────────┴──────────┴───────────┴───────────────────┤
│  Sandbox VM (Alpine · Apple Containerization)       │
│  vsock bridge · VirtioFS · per-agent isolation      │
└─────────────────────────────────────────────────────┘
```

Most features are accessible through the Management window (`⌘ ⇧ M`).

## Build from Source

```bash
git clone https://github.com/dingxiang-me/Muwa.git
cd muwa
open Muwa.xcworkspace
```

Build and run the `Muwa` target. Requires Xcode 16+ and macOS 15.5+.

### Git Hooks (lefthook)

Install [lefthook](https://github.com/evilmartians/lefthook) to set up the hooks that verify quality of the code:

```bash
brew install lefthook
lefthook install
```

This installs a `pre-push` hook that runs `swift-format` over the `Packages/` directory before each push.

## Project Structure

```
muwa/
├── App/                          # macOS app target (SwiftUI entry point, assets, entitlements)
├── Packages/
│   ├── MuwaCore/              # Core library — all app logic
│   │   ├── Models/               # Data types, DTOs, configuration stores
│   │   ├── Services/             # Business logic (actors and stateless types)
│   │   ├── Managers/             # UI-facing state holders (@MainActor, observable)
│   │   ├── Views/                # SwiftUI views, organized by feature
│   │   ├── Networking/           # HTTP server, routing, relay
│   │   ├── Storage/              # SQLite databases
│   │   ├── Identity/             # Cryptographic identity and access keys
│   │   ├── Tools/                # MCP tools, plugin ABI, tool registry
│   │   ├── Folder/               # Working-folder context, file ops, batch tool
│   │   ├── Utils/                # Cross-cutting utilities
│   │   └── Tests/                # Unit and integration tests
│   ├── MuwaCLI/               # CLI (muwa-cli command)
│   └── MuwaRepository/        # Plugin registry and installation
├── docs/                         # Feature guides and documentation
├── scripts/                      # Build, release, and benchmark scripts
├── sandbox/                      # Sandbox VM Dockerfile
└── assets/                       # DMG packaging assets
```

See [CONTRIBUTING.md](docs/CONTRIBUTING.md) for the architecture guide and layer definitions.

## Contributing

Muwa is actively developed and we welcome contributions: bug fixes, new plugins, documentation, UI/UX improvements, and testing.

Check out [Good First Issues](https://github.com/dingxiang-me/Muwa/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22), read the [Contributing Guide](CONTRIBUTING.md), or join [Discord](https://discord.gg/muwa). See [docs/FEATURES.md](docs/FEATURES.md) for the full feature inventory.

> [!NOTE]
> **🌐 Help translate Muwa.** We're looking for contributors to localize the app into **Spanish**, **Korean**, **Japanese**, and **Traditional Chinese** -- these locales are already wired up in Xcode, so you can start translating right away. See [docs/TRANSLATORS.md](docs/TRANSLATORS.md) for how to contribute and the contributor leaderboard.

## Community

- [Discord](https://discord.gg/muwa) -- chat, feedback, show-and-tell
- [Twitter](https://x.com/MuwaAI) -- updates and demos
- [Hugging Face](https://huggingface.co/MuwaAI) -- optimized models for Apple Silicon
- [Community Calls](https://lu.ma/muwa) -- bi-weekly, open to everyone
- [Blog](https://muwa.ai/blog) -- long-form thinking on personal AI
- [Docs](https://docs.muwa.ai) -- guides and tutorials
- [Plugin Registry](https://github.com/dingxiang-me/muwa-tools) -- browse and contribute tools

## License

[MIT](LICENSE)

---

<p align="center">
  Muwa, Inc. · <a href="https://muwa.ai">muwa.ai</a>
</p>
