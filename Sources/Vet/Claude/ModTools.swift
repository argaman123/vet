import Foundation

/// The MCP tools for mods: an agent reads `mod_api_docs`, writes a mod with `install_mod`, and
/// reads the result (or the error) in the reply.
@MainActor
enum ModTools {
    static func make() -> [MCPServer.Tool] {
        let str: [String: Any] = ["type": "string"]
        let scope: [String: Any] = ["type": "string", "enum": ["user", "project"],
                                    "description": "\"user\" (default): every project. \"project\": only the open project (<project>/.vet/mods)."]
        let host = ModHost.shared
        return [
            .init("mod_api_docs", "How to write a Vet mod: the folder format, mod.json, the `vet` script API (keys, commands, editor, UI, themes) and examples. Read this before install_mod.",
                  schema: ["type": "object", "properties": [:] as [String: Any]]) { _ in
                (ModDocs.text, false)
            },
            .init("list_mods", "The installed Vet mods: id, name, scope, status (loaded, disabled or failed with the error), runtime error counts.",
                  schema: ["type": "object", "properties": [:] as [String: Any]]) { _ in
                let list = host.summary()
                guard !list.isEmpty else { return ("No mods installed. User mods folder: \(host.userFolder.path)", false) }
                let data = (try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                return (String(decoding: data, as: UTF8.self), false)
            },
            .init("install_mod", """
                Install or replace a Vet mod. Vet writes the files into the mod's folder and loads it at once \
                (no restart). The reply says whether it loaded, or the error with its line, so you can fix and \
                call again. `files` maps paths inside the mod folder to their text; it must include mod.json.
                """,
                  schema: ["type": "object", "required": ["id", "files"], "properties": [
                    "id": ["type": "string", "description": "Lowercase id, also the folder name (\"vim\")."],
                    "scope": scope,
                    "files": ["type": "object", "additionalProperties": str,
                              "description": "{\"mod.json\": \"…\", \"main.js\": \"…\"}"],
                  ] as [String: Any]]) { args in
                guard let id = args["id"] as? String, let files = args["files"] as? [String: Any] else { return ("id and files are required.", true) }
                var texts: [String: String] = [:]
                for (k, v) in files {
                    if let s = v as? String { texts[k] = s }
                    else if let data = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted]) { texts[k] = String(decoding: data, as: UTF8.self) } // mod.json given as an object
                    else { return ("files[\"\(k)\"] must be text.", true) }
                }
                return host.install(id: id, scope: ModHost.Scope(rawValue: args["scope"] as? String ?? "user") ?? .user, files: texts)
            },
            .init("remove_mod", "Uninstall a Vet mod (its folder is deleted; whatever it changed goes away at once).",
                  schema: ["type": "object", "required": ["id"], "properties": ["id": str, "scope": scope] as [String: Any]]) { args in
                guard let id = args["id"] as? String else { return ("id is required.", true) }
                return host.remove(id: id, scope: (args["scope"] as? String).flatMap(ModHost.Scope.init))
            },
            .init("mod_logs", "A mod's log: console.log/vet.log output and every error (with line and stack), newest last.",
                  schema: ["type": "object", "required": ["id"], "properties": ["id": str] as [String: Any]]) { args in
                guard let id = args["id"] as? String, let mod = host.mods.first(where: { $0.id == id }) else { return ("There's no mod \"\(args["id"] as? String ?? "")\".", true) }
                return (mod.log.isEmpty ? "(empty)" : mod.log.joined(separator: "\n"), false)
            },
            .init("set_mod_enabled", "Switch a mod on or off (as its checkmark in Vet's Mods menu does).",
                  schema: ["type": "object", "required": ["id", "enabled"], "properties": ["id": str, "enabled": ["type": "boolean"]] as [String: Any]]) { args in
                guard let id = args["id"] as? String, let on = args["enabled"] as? Bool else { return ("id and enabled are required.", true) }
                guard host.mods.contains(where: { $0.id == id }) else { return ("There's no mod \"\(id)\".", true) }
                host.setEnabled(id, on)
                return host.report(id, verb: on ? "Switched on" : "Switched off")
            },
        ]
    }
}
