import Foundation

/// What `mod_api_docs` answers: everything an agent needs to write a mod in one go. Keep it in
/// step with ModAPI.swift.
@MainActor
enum ModDocs {
    static var text: String {
        let commands = CommandRegistry.shared.commands.map { "- `\($0.id)` — \($0.title)" }.joined(separator: "\n")
        let themes = Palette.available.map { "`\($0.id)`" }.joined(separator: ", ")
        let colorKeys = ((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Palette.all[0]))) as? [String: Any] ?? [:])
            .filter { $0.value is NSNumber && !($0.value is Bool) }.keys.sorted().joined(separator: ", ")
        return guide + """

        ## Commands available now

        \(commands)
        - `editor.<NSTextView selector>` — a text command in the focused code pane, e.g. `editor.moveWordForward:`, \
        `editor.moveToBeginningOfLine:`, `editor.moveToEndOfDocument:`, `editor.deleteBackward:`, `editor.selectAll:`, \
        `editor.centerSelectionInVisibleArea:`.

        ## Theme ids and color keys

        Built-in palettes (for `base`): \(themes).
        Color keys (hex "#RRGGBB"): \(colorKeys).
        """
    }

    private static let guide = """
    # Writing a Vet mod

    Vet is a native macOS code-review IDE. A mod is a folder Vet loads at once (no restart): a `mod.json`
    and, for behavior, a `main.js` run in JavaScriptCore (no DOM, no Node, no `require`; ES2023 is fine).
    Install it with `install_mod` — the reply says whether it loaded or gives the error and line; fix and
    install again. `mod_logs` shows console output and runtime errors. Mods are reloaded fresh whenever any
    mod changes, so keep state in variables (or `vet.storage` for what must survive).

    Scope: "user" mods apply to every project (~/Library/Application Support/Vet/mods/<id>); "project" mods
    only to the open project (<project>/.vet/mods/<id>) and win over a user mod with the same id. Use
    "project" only when the user says the mod is just for this project.

    ## mod.json

    ```json
    {
      "id": "focus-keys",
      "name": "Focus Keys",
      "version": "1.0",
      "description": "One line on what it does.",
      "main": "main.js",
      "keymap": [
        { "key": "cmd+shift+e", "command": "app.findInFiles" },
        { "key": "ctrl+j", "command": "app.nextChange", "when": "diff" }
      ],
      "themes": [
        { "id": "dusk", "name": "Dusk", "base": "ink", "colors": { "keyword": "#C792EA", "background": "#16161E" } }
      ]
    }
    ```

    - `main` is optional (defaults to main.js if present). A mod may be only keymap and themes.
    - Keys: modifiers `cmd`, `ctrl`, `alt` (`opt`), `shift`, joined with `+`, then one key: a character
      (`k`, `/`, `[`), an uppercase letter meaning shift (`G`), or a name: escape, enter, tab, space,
      backspace, delete, up, down, left, right, home, end, pageup, pagedown, f1…f12.
    - `when`: `always` (default), `code` (any code pane focused), `editor` (the file editor), `diff` (the
      diff's panes), `notCode` (focus outside code). Bindings without cmd/ctrl/alt never fire while the
      user types in a search field or a prompt. Mod bindings win over Vet's menu shortcuts.
    - `args` (optional, strings) are passed to the command.
    - Themes appear in View ▸ Theme. `base` is the palette to start from; `colors` override its keys.

    ## Code panes

    Vet has two kinds of code pane, both AppKit text views: the file editor (`"editor"`) and the diff's
    right side, the working copy you can edit (`"diff"`); the diff's left side is the old version
    (`"diffOld"`, read-only). In the diff, lines are display lines: folded unchanged lines and note cards
    occupy rows of their own and refuse edits. A deleted file's diff is read-only.

    Positions: `{line, ch}` with both counted from 0 (ch in UTF-16 units), or a number = offset into the
    pane's text. Functions that return a position give `{line, ch, offset}`.

    ## The `vet` object (main.js)

    ### Keys
    - `vet.keys.onKey(fn)` — `fn(e)` runs for every key pressed in a code pane, before Vet handles it.
      Return `true` to swallow the key. `e` = `{key, combo, chars, cmd, ctrl, alt, shift, repeat, pane}`:
      `key` is what was typed (`"j"`, `"G"`, `":"`, `"$"`) or the key's name (`"escape"`, `"enter"`,
      `"backspace"`, `"up"`…; with cmd/ctrl it's the base key, e.g. ctrl+d → `"d"`); `combo` is the
      normalized form (`"ctrl+d"`, `"shift+g"`); `pane` is `"editor"`, `"diff"` or `"diffOld"`.
      Handlers of all mods are asked in order until one returns true. If a handler throws, the key is not
      swallowed (and the error goes to the log).
    - `vet.keys.bind(key, commandIdOrFunction, when?)` — like a keymap entry, from code.

    ### Commands
    - `vet.commands.list()` → `[{id, title}]`.
    - `vet.commands.run(id, ...args)` → true if the command exists. See "Commands available now".
    - `vet.commands.register(id, title, fn)` → the full id (`"<mod id>.<id>"` unless id has a dot). The
      command shows in Search Everywhere (double Shift) and can be bound.

    ### Editor (the focused code pane, or the last one that had focus)
    - `available()`, `kind()` → "editor" | "diff" | "diffOld", `editable()`.
    - `text()`, `lineCount()`, `line(n)` (without its newline).
    - `cursor()` → position; `setCursor(pos)` or `setCursor(line, ch)` (clamped to the line, scrolls to it).
    - `selection()` → `{start, end, text}`; `select(from, to)` (the caret ends at `to`).
    - `offsetOf(pos)`, `positionOf(offset)`.
    - `insert(text)` replaces the selection; `replace(from, to, text)`. Both go through the text view's
      normal typing path (undo, the diff's guards) and return false if refused (read-only pane, a fold row).
    - `group(fn)` — everything `fn` changes is one undo step (use it for `dd`, `p`, multi-edit commands).
    - `undo()`, `redo()`, `save()`, `focus()`.
    - `perform("moveWordForward:")` — any NSTextView command.
    - `find(query, {from, backward, regex})` → `{start, end, text}` or null; wraps around; smart case
      (an all-lowercase query ignores case). `findAll(query)` → `[{start, end}]` offsets.
    - `highlight([{start, end}, …])` marks ranges (offsets) like search matches; `highlight([])` clears.
    - `scrollTo(pos)`, `visibleLines()` → `{first, last}`.
    - `caret("bar" | "block" | "underline")` — the caret's shape in that pane. Vet restores the bar when
      the mod unloads.

    ### UI (Vet draws it; mods only describe it)
    - `vet.ui.prompt({prefix, text, placeholder, onChange(text), onSubmit(text), onCancel(text)})` — a glass
      line at the bottom of the code that takes focus (one at a time). Enter submits, Escape cancels,
      Backspace on an empty line cancels. Focus returns to the code pane after.
    - `vet.ui.closePrompt()`.
    - `vet.ui.toast(text)` — a short message at the bottom of the window.
    - `vet.ui.panel(id, {title, blocks})` — a glass panel at the top right; calling again with the same id
      replaces it. Blocks: `{type: "heading"|"text"|"code"|"row"|"button"|"divider", text, detail, onClick}`
      (`row` shows text with detail on the right; `row`/`button` call `onClick`). `vet.ui.closePanel(id)`.

    ### Events and the rest
    - `vet.on("focus", e => …)` — a code pane got focus (`e.pane`).
    - `vet.on("fileOpened", e => …)` — `{path, pane}` when a file or diff opens.
    - `vet.clipboard.read()`, `vet.clipboard.write(text)` — the system clipboard.
    - `vet.storage.get(key)`, `vet.storage.set(key, value)` — JSON values kept across reloads and launches.
    - `vet.project()` → the project's path; `vet.file()` → the open file relative to it.
    - `vet.log(...)`, `console.log/info/warn/error` → the mod's log. `setTimeout(fn, ms)`, `clearTimeout(id)`.
    - A script that runs longer than 1.5 s at a time is stopped (the error is logged).

    ## Example: a tiny modal mod

    ```js
    let on = false;
    vet.commands.register("toggle", "Toggle Jump Keys", () => {
      on = !on;
      vet.editor.caret(on ? "block" : "bar");
      vet.ui.toast(on ? "Jump keys on" : "Jump keys off");
    });
    vet.keys.bind("ctrl+;", "jump-keys.toggle");
    vet.keys.onKey(e => {
      if (!on || e.cmd || e.ctrl) return false;
      if (e.key === "n") { vet.commands.run("app.nextChange"); return true; }
      if (e.key === "p") { vet.commands.run("app.previousChange"); return true; }
      if (e.key === "/") {
        vet.ui.prompt({ prefix: "/", onSubmit: q => {
          const hit = vet.editor.find(q);
          if (hit) vet.editor.setCursor(hit.start); else vet.ui.toast("Not found: " + q);
        }});
        return true;
      }
      return false;
    });
    ```
    """
}
