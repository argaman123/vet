<div align="center">

<img src="docs/images/icon.png" width="96" alt="Vet icon">

# Vet

**Your usual IDE was built for typing code. Vet is built for the AI era.**

You don't write the code anymore, your agent does. Vet is the IDE for guiding it and staying in control of what it writes.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![MCP](https://img.shields.io/badge/MCP-any%20agent-D97757)
![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial-blue)

![Vet reviewing a change](docs/images/review.png)

</div>

## Why

Every IDE you know was built to make writing code better. They are huge, packed with features for typing faster, and they were great at it.

But you no longer write the code. Your agent does, and you are still using an IDE made for a job you stopped doing.

Vet is built for this era. AI code isn't always right, so you still want control over every line of it, without the weight of an editor made for writing. Everything in Vet is there for one thing: guiding your agent, and making that as seamless as possible. It talks to the agent directly over [MCP](https://modelcontextprotocol.io), and it is small, fast and native: SwiftUI and AppKit, no Electron, no dependencies.

## A session, start to finish

### 1. Ask your agent for something

Open your project in Vet and work with your agent the way you always do. It finds Vet on its own and starts listening for you.

> add rate limiting to the API, tighter on sign-in

### 2. It hands you a review order

When the agent is done, it doesn't leave you with a pile of changed files. It tells Vet what to read and in which order, and the sidebar becomes a numbered **Review Order**.

![The review order](docs/images/review-order.png)

### 3. Each file opens with its story

Every file starts with the agent's short description of what changed in it and why, so you know what you are looking at before you read a line.

![A file's description](docs/images/file-summary.png)

### 4. Its notes wait on the lines that matter

As you arrive at a change, the agent's note about it opens beside it: why it did this, what to check, what it isn't sure about. For something you must not miss, it puts a pointer under the line.

![A note from the agent beside a change](docs/images/claude-note.png)

### 5. Approve change by change

`Space` approves the change you are on and glides to the next one, then to the next file. Every file shows how much of it you have been through.

- A mark belongs to the change itself: it survives edits elsewhere in the file and lapses if that change is edited again.
- Approving is only for you: it changes nothing in git, so nothing is staged or committed behind your back.
- Lock files and generated code can be marked **Unimportant**, so they are approved automatically and listed apart.

### 6. Not happy with something? Say it on the line

Press `⌘N`, write what you think, and send it with `⌘↩`. The agent wakes up and starts on it in the background. You keep reviewing.

![Writing a note](docs/images/your-note.png)

### 7. The answer comes back to the same line

The agent fixes the code or answers your question, and its reply appears where you asked. You never went back to the chat.

![The agent's reply to a note](docs/images/note-reply.png)

### 8. Ship it

When everything is approved, `⌘K` asks the agent to commit exactly the files you reviewed.

## Also in Vet

### Native glass

One window, dark, drawn in macOS's own materials: a floating glass sidebar over a work surface that fills the window, with every control, menu and message made of the same sheet. Code fades out before the window's edge instead of being cut by it.

### The parts of an IDE you need along the way

| | |
|---|---|
| ![Search Everywhere](docs/images/search-everywhere.png) | ![Find usages](docs/images/find-usages.png) |
| **Search Everywhere** (`⇧⇧`): files, symbols, actions and text in one panel. | **Code navigation**: go to definition, find usages with a preview, hover docs, inlay types and usage counts, for TypeScript, JavaScript, Python and Kotlin. |

![Run output and the built-in browser](docs/images/run-and-browser.png)

**Run and browser**: start your app, see its output, and open it in a built-in browser. The agent can read the output, the page and its console.

And: side-by-side or unified diff, an editor with autosave, find in files, branch switching and 11 themes.

## Install

### Download

1. Get `Vet-0.1.0.dmg` from the [latest release](../../releases/latest) and drag **Vet** to **Applications**.
2. Open it. Vet is not notarized by Apple, so macOS blocks the first launch: go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Vet.app
   ```

Requires macOS 26 or later on Apple silicon.

### Build from source

Needs Xcode 26 (or its Command Line Tools plus Xcode for the SwiftUI macros).

```bash
git clone https://github.com/argaman123/vet.git
cd vet
scripts/install.sh
```

This builds a release and installs it to `~/Applications/Vet.app`. `scripts/run.sh` builds and opens it without installing, and `scripts/make-dmg.sh` builds the disk image.

### Code navigation (optional)

Go to definition and find usages use language servers, which Vet does not bundle. This installs them into `~/Library/Application Support/Vet/servers` (needs Node):

```bash
scripts/install-language-servers.sh
```

## Use it with your agent

Vet runs an MCP server on `127.0.0.1:47821` while it is open. Any agent that can use a local MCP server over HTTP can connect, and the server itself tells the agent how to use Vet, so there is nothing to add to your prompts.

### Claude Code

1. In Vet, choose **Review → Connect Claude Code…** and click **Connect**. It runs this for you:

   ```bash
   claude mcp add --transport http --scope user vet http://127.0.0.1:47821/mcp
   ```

2. Open your project in Vet (`⌘O`).
3. Start a new Claude Code session in that project and work as usual.

From then on:

- When Claude finishes a change, Vet shows **Claude finished** and the review order.
- You review, approve, and send notes from Vet.
- Claude keeps a listener running in the background, so your notes reach it even while the chat is idle. If the note popover says no chat is listening, type `vet` once in your Claude chat.

### Codex, Cursor and other agents

Add Vet as an HTTP MCP server named `vet` with the URL `http://127.0.0.1:47821/mcp`. For OpenAI's Codex, that is two lines in `~/.codex/config.toml`:

```toml
[mcp_servers.vet]
url = "http://127.0.0.1:47821/mcp"
```

In Cursor and most other clients it is one entry in the MCP settings with the same URL.

The review order, notes, pointers, run output and browser work the same way. Waking an idle chat when you send a note depends on the agent being able to wait on a background command; where it can't, tell it "check Vet" and it reads your notes. The ChatGPT app itself only connects to servers on the internet, so with OpenAI use Codex.

### What the agent can do

| Tool | What it does |
|---|---|
| `set_review_plan` | Sets the review order, a summary per file, and notes on lines or symbols. |
| `get_notes` / `resolve_notes` | Reads your notes and answers them beside their lines. |
| `point_at_code` / `remove_pointer` | Puts a pointer under a line you must not miss, and takes it back. |
| `vet_status` | Lists the changed files and what you have reviewed. |
| `get_selection` | Reads the file and lines you are looking at ("this", "here"). |
| `open_in_vet` | Shows you a file or a line. |
| `run_app` / `stop_app` / `run_output` | Runs your app from a run configuration and reads its output. |
| `browser_view` | Reads the built-in browser: page text, console, and a screenshot. |
| `install_mod` and the other mod tools | Changes Vet itself: keys, themes, commands, panels. |

## Keyboard

| Keys | Action |
|---|---|
| `Space` or `⌘↩` | Approve the change and go to the next |
| `⌘↓` / `⌘↑` | Next / previous change |
| `⌥⌘U` | Next unreviewed file |
| `⌘N` | Add a note |
| `⌘↩` (in a note) | Send the note to Claude |
| `⌥⌘↩` | Send all unsent notes |
| `⌘←` / `⌘→` | Show / hide Claude's note on this change |
| `⌘K` | Ask Claude to commit the reviewed files |
| `⇧⇧` or `⇧⌘O` | Search Everywhere |
| `⇧⌘F` | Find in files |
| `⌘-click` | Go to definition |
| Force click | Find usages |
| `⌘1` `⌘2` `⌘3` | Changes, All Files, Browser |
| `⌘[` / `⌘]` | Back / forward |
| `⌘R` / `⌘.` | Run / stop |
| `⌘+` `⌘-` `⌘0` | Code text size |

## Mods

Vet can be changed from the inside. A mod is a small folder that binds keys, adds commands and themes, edits text, or shows its own panels, and it loads without a restart.

The quickest way to make one is to ask your agent:

> make a Vet mod that adds Vim keys

It reads the mod guide through MCP, writes the mod and installs it, and you see it working a moment later. A mod can be as small as this, which makes `⌥J` and `⌥K` move between changes and `⌥A` approve:

```json
{
  "id": "review-keys",
  "keymap": [
    { "key": "alt+j", "command": "app.nextChange" },
    { "key": "alt+k", "command": "app.previousChange" },
    { "key": "alt+a", "command": "app.approveAndNext" }
  ]
}
```

Add a `main.js` next to it for anything that needs code. Mods live in `~/Library/Application Support/Vet/mods`, or in a project's `.vet/mods` to share them with the repository.

## How it works

- **`Sources/VetCore`**: the diff engine, change fingerprints, fuzzy matching and search. No UI.
- **`Sources/Vet`**: the app. The diff and editor views are AppKit text views; the window, sidebar and panels are SwiftUI.
- **`Sources/Vet/Claude`**: the MCP server and its tools.
- **`.vet/`** in each project holds your review marks, notes, the review plan and run configurations. It ignores itself in git, so your repository is never changed.

There are no package dependencies.

## License

Vet is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md): you may use, change and share it for any noncommercial purpose.

Required Notice: Copyright Argaman Gez

Parts come from other projects under their own licenses; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Vet is an independent project, not affiliated with Anthropic, Microsoft or JetBrains.
