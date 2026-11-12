/* RESTaurant - client side behaviour: service tree, list filters, copy buttons,
   code editor and the request console. Nothing is loaded from outside of APEX. */
(function () {
    "use strict";

    var TREE_STATE = "restaurant.tree.open";

    function each(root, selector, fn) {
        Array.prototype.forEach.call((root || document).querySelectorAll(selector), fn);
    }

    /* ---------- service tree ---------- */
    function readOpen() {
        try {
            return JSON.parse(window.sessionStorage.getItem(TREE_STATE) || "[]");
        } catch (e) {
            return [];
        }
    }

    function initTree(tree) {
        var open = readOpen();

        function store() {
            var keys = [];
            each(tree, ".rst-node--module.is-open", function (node) {
                keys.push(node.getAttribute("data-key"));
            });
            try {
                window.sessionStorage.setItem(TREE_STATE, JSON.stringify(keys));
            } catch (e) { /* storage is optional */ }
        }

        each(tree, ".rst-node--module", function (node) {
            if (open.indexOf(node.getAttribute("data-key")) >= 0) {
                node.classList.add("is-open");
            }
        });
        store();

        tree.addEventListener("click", function (event) {
            var toggle = event.target.closest(".rst-node-toggle");
            if (toggle) {
                toggle.closest(".rst-node").classList.toggle("is-open");
                store();
            }
        });

        var search = tree.querySelector(".rst-tree-search");
        if (search) {
            search.addEventListener("input", function () {
                var term = search.value.trim().toLowerCase();
                each(tree, ".rst-node--module", function (module) {
                    var moduleHit = module.querySelector(".rst-node-label").textContent.toLowerCase().indexOf(term) >= 0,
                        anyHit = false;
                    each(module, ".rst-node--template", function (template) {
                        var hit = !term || moduleHit || template.textContent.toLowerCase().indexOf(term) >= 0;
                        template.classList.toggle("is-filtered", !hit);
                        anyHit = anyHit || hit;
                    });
                    module.classList.toggle("is-filtered", !!term && !moduleHit && !anyHit);
                    if (term && (anyHit || moduleHit)) {
                        module.classList.add("is-open");
                    }
                });
            });
        }

        var current = tree.querySelector(".is-current");
        if (current && current.scrollIntoView) {
            current.scrollIntoView({ block: "nearest" });
        }
    }

    /* ---------- quick filter for tables ---------- */
    function initFilter(input) {
        var table = document.querySelector(input.getAttribute("data-target"));
        if (!table) {
            return;
        }
        input.addEventListener("input", function () {
            var term = input.value.trim().toLowerCase();
            each(table, "tbody tr", function (row) {
                row.style.display = !term || row.textContent.toLowerCase().indexOf(term) >= 0 ? "" : "none";
            });
        });
    }

    /* ---------- copy to clipboard ---------- */
    function copyText(text, button) {
        function done() {
            if (button) {
                button.classList.add("is-done");
                window.setTimeout(function () { button.classList.remove("is-done"); }, 1500);
            }
        }
        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text).then(done);
            return;
        }
        var area = document.createElement("textarea");
        area.value = text;
        area.setAttribute("readonly", "");
        area.style.position = "fixed";
        area.style.opacity = "0";
        document.body.appendChild(area);
        area.select();
        try {
            document.execCommand("copy");
            done();
        } catch (e) { /* nothing we can do */ }
        document.body.removeChild(area);
    }

    function initCopy() {
        document.addEventListener("click", function (event) {
            var button = event.target.closest(".rst-copy");
            if (!button) {
                return;
            }
            var source = button.getAttribute("data-copy-from"),
                element = source ? document.querySelector(source) : null;
            copyText(element ? (element.value !== undefined ? element.value : element.textContent) : button.getAttribute("data-copy") || "", button);
        });
    }

    /* ---------- code editor ----------
       Large code fields become a Monaco editor. Monaco ships with APEX, it is the
       editor of the App Builder, so nothing is downloaded from elsewhere. Should
       it not be available, the field stays a text area with line numbers. */
    var monacoReady,
        SQL_KEYWORDS = ("select from where and or not null is in like between exists case when then else end as on join left right " +
            "inner outer full cross natural using group by order having union all minus intersect except insert into values update " +
            "set delete merge matched distinct unique fetch first next row rows only offset with recursive connect start prior level " +
            "rownum nulls last asc desc over partition within for of nowait returning pivot unpivot lateral apply " +
            "begin declare exception if elsif loop while exit continue return raise procedure function cursor open close type record " +
            "table index subtype pragma commit rollback savepoint execute immediate bulk collect forall constant default out nocopy " +
            "goto others true false is rowtype reverse authid deterministic new limit lock mode share exclusive grant revoke create " +
            "alter drop truncate replace view sequence trigger package body synonym").split(" "),
        SQL_FUNCTIONS = ("nvl nvl2 coalesce nullif decode to_char to_number to_date to_timestamp to_clob to_blob trunc round floor ceil " +
            "abs mod power substr instr length upper lower initcap trim ltrim rtrim lpad rpad replace translate concat count sum min " +
            "max avg median listagg row_number rank dense_rank lag lead first_value last_value json_object json_array json_arrayagg " +
            "json_objectagg json_value json_query json_table json_serialize json_exists sys_context sys_guid regexp_like " +
            "regexp_replace regexp_substr regexp_instr regexp_count cast extract greatest least add_months months_between last_day " +
            "sysdate systimestamp current_date current_timestamp user sqlcode sqlerrm dual utl_raw dbms_lob dbms_output " +
            "apex_json apex_util apex_string ords owa_util htp").split(" "),
        SQL_TYPES = ("varchar2 varchar nvarchar2 char nchar number integer int pls_integer binary_integer simple_integer float " +
            "binary_float binary_double date timestamp interval clob nclob blob bfile raw long rowid urowid boolean json xmltype " +
            "sys_refcursor vector").split(" ");

    function defineSql(monaco) {
        ["sql", "plsql"].forEach(function (id) {
            monaco.languages.register({ id: id });
            monaco.languages.setLanguageConfiguration(id, {
                comments: { lineComment: "--", blockComment: ["/*", "*/"] },
                brackets: [["(", ")"], ["[", "]"]],
                autoClosingPairs: [
                    { open: "(", close: ")" },
                    { open: "[", close: "]" },
                    { open: "'", close: "'", notIn: ["string", "comment"] }
                ],
                surroundingPairs: [{ open: "(", close: ")" }, { open: "'", close: "'" }, { open: "\"", close: "\"" }]
            });
            monaco.languages.setMonarchTokensProvider(id, {
                ignoreCase: true,
                defaultToken: "",
                keywords: SQL_KEYWORDS,
                functions: SQL_FUNCTIONS,
                types: SQL_TYPES,
                tokenizer: {
                    root: [
                        [/--.*$/, "comment"],
                        [/\/\*/, "comment", "@comment"],
                        [/n?q'\[/, "string", "@quotedBracket"],
                        [/n?q'\{/, "string", "@quotedBrace"],
                        [/n?q'\(/, "string", "@quotedParen"],
                        [/'/, "string", "@string"],
                        [/"[^"]*"/, "identifier"],
                        [/:[a-zA-Z][\w$#]*/, "variable.predefined"],
                        [/\d+(\.\d+)?([eE][+-]?\d+)?/, "number"],
                        [/[a-zA-Z][\w$#]*/, {
                            cases: {
                                "@keywords": "keyword",
                                "@types": "type",
                                "@functions": "predefined",
                                "@default": "identifier"
                            }
                        }],
                        [/[()\[\]]/, "@brackets"],
                        [/[;,.]/, "delimiter"],
                        [/[<>=!|+\-*\/%:@^]+/, "operator"]
                    ],
                    comment: [
                        [/[^*\/]+/, "comment"],
                        [/\*\//, "comment", "@pop"],
                        [/[*\/]/, "comment"]
                    ],
                    string: [
                        [/[^']+/, "string"],
                        [/''/, "string.escape"],
                        [/'/, "string", "@pop"]
                    ],
                    quotedBracket: [[/\]'/, "string", "@pop"], [/[^\]]+|\]/, "string"]],
                    quotedBrace: [[/\}'/, "string", "@pop"], [/[^}]+|\}/, "string"]],
                    quotedParen: [[/\)'/, "string", "@pop"], [/[^)]+|\)/, "string"]]
                }
            });
        });
    }

    function loadMonaco() {
        if (!monacoReady) {
            monacoReady = new Promise(function (resolve, reject) {
                var apexApi = window.apex || {},
                    version = apexApi.libVersions && apexApi.libVersions.monacoEditor,
                    root, link;
                if (!version || !apexApi.env || !apexApi.env.APEX_FILES) {
                    reject(new Error("Monaco is not available"));
                    return;
                }
                root = apexApi.env.APEX_FILES + "libraries/monaco-editor/" + version + "/monaco-editor.min";
                link = document.createElement("link");
                link.rel = "stylesheet";
                link.href = root + ".css";
                document.head.appendChild(link);
                import(root + ".js").then(function (module) {
                    defineSql(module.monaco);
                    resolve(module.monaco);
                }, reject);
            });
        }
        return monacoReady;
    }

    function isDark() {
        var color = window.getComputedStyle(document.body).backgroundColor.match(/\d+/g) || [255, 255, 255];
        return (0.299 * color[0] + 0.587 * color[1] + 0.114 * color[2]) < 128;
    }

    function codeLanguage(area) {
        return area.getAttribute("data-rst-language") || "sql";
    }

    function createEditor(area, monaco) {
        var host = document.createElement("div"),
            label = document.querySelector("label[for='" + area.id + "']"),
            editor;
        host.className = "rst-monaco";
        host.style.height = Math.max(area.offsetHeight, 260) + "px";
        area.parentNode.insertBefore(host, area);
        area.classList.add("rst-code-source");
        editor = monaco.editor.create(host, {
            value: area.value,
            language: codeLanguage(area),
            theme: isDark() ? "vs-dark" : "vs",
            ariaLabel: label ? label.textContent : "Source",
            automaticLayout: true,
            fixedOverflowWidgets: true,
            minimap: { enabled: false },
            scrollBeyondLastLine: false,
            renderLineHighlight: "line",
            fontSize: 13,
            tabSize: 4,
            insertSpaces: true
        });
        editor.onDidChangeModelContent(function () {
            area.value = editor.getValue();
            area.dispatchEvent(new Event("input", { bubbles: true }));
        });
        area.rstEditor = { monaco: monaco, editor: editor };
        if (area.rstCheck) {
            showCheck(area, area.rstCheck);
        }
    }

    function addLineNumbers(area) {
        var editor = document.createElement("div"),
            gutter = document.createElement("div"),
            count = 0;

        function update() {
            var lines = area.value.split("\n").length, text = "", i;
            if (lines !== count) {
                for (i = 1; i <= lines; i += 1) {
                    text += i + "\n";
                }
                gutter.textContent = text;
                count = lines;
            }
            gutter.style.height = area.clientHeight + "px";
            gutter.scrollTop = area.scrollTop;
        }

        editor.className = "rst-editor";
        gutter.className = "rst-gutter";
        gutter.setAttribute("aria-hidden", "true");
        area.parentNode.insertBefore(editor, area);
        editor.appendChild(gutter);
        editor.appendChild(area);
        area.addEventListener("input", update);
        area.addEventListener("scroll", update);
        if (window.ResizeObserver) {
            new window.ResizeObserver(update).observe(area);
        }
        update();
    }

    function initCode(area) {
        area.setAttribute("spellcheck", "false");
        area.setAttribute("autocapitalize", "off");
        area.setAttribute("autocomplete", "off");
        if (area.rows >= 8) {
            loadMonaco().then(function (monaco) {
                createEditor(area, monaco);
            }).catch(function () {
                addLineNumbers(area);
            });
        }
        area.addEventListener("keydown", function (event) {
            if (event.key !== "Tab" || event.ctrlKey || event.altKey || event.metaKey) {
                return;
            }
            var start = area.selectionStart,
                end = area.selectionEnd,
                value = area.value,
                lineStart = value.lastIndexOf("\n", start - 1) + 1,
                block, changed;
            event.preventDefault();
            if (start === end && !event.shiftKey) {
                area.setRangeText("    ", start, end, "end");
            } else {
                block = value.substring(lineStart, end);
                changed = event.shiftKey ? block.replace(/^ {1,4}/gm, "") : block.replace(/^/gm, "    ");
                area.setRangeText(changed, lineStart, end, "select");
            }
            area.dispatchEvent(new Event("input", { bubbles: true }));
        });
    }

    /* ---------- result of the compile check ---------- */
    function checkElement(area) {
        var group = area.closest(".apex-item-group") || area.parentNode,
            element = group.querySelector(".rst-check");
        if (!element) {
            element = document.createElement("button");
            element.type = "button";
            element.className = "rst-check";
            element.setAttribute("aria-live", "polite");
            group.appendChild(element);
            element.addEventListener("click", function () {
                goToCheck(area);
            });
        }
        return element;
    }

    // moves the cursor to the reported position
    function goToCheck(area) {
        var check = area.rstCheck, lines, offset, i;
        if (!check || check.status !== "ERROR" || !check.line) {
            return;
        }
        if (area.rstEditor) {
            area.rstEditor.editor.revealLineInCenter(check.line);
            area.rstEditor.editor.setPosition({ lineNumber: check.line, column: check.column || 1 });
            area.rstEditor.editor.focus();
            return;
        }
        lines = area.value.split("\n");
        offset = 0;
        for (i = 0; i < check.line - 1 && i < lines.length; i += 1) {
            offset += lines[i].length + 1;
        }
        area.focus();
        area.setSelectionRange(offset + (check.column || 1) - 1, offset + (lines[check.line - 1] || "").length);
    }

    function showCheck(area, check) {
        var element = checkElement(area),
            markers = [],
            model, word;
        area.rstCheck = check;
        element.className = "rst-check is-" + check.status.toLowerCase();
        element.disabled = check.status !== "ERROR";
        if (check.status === "OK") {
            element.textContent = "No errors found";
        } else if (check.status === "ERROR") {
            element.textContent = (check.line ? "Line " + check.line + ", column " + (check.column || 1) + ": " : "") + check.message;
        } else if (check.status === "CHECKING") {
            element.textContent = "Checking ...";
        } else {
            element.textContent = check.message || "";
        }
        element.style.display = element.textContent ? "" : "none";
        if (area.rstEditor && check.status !== "CHECKING") {
            model = area.rstEditor.editor.getModel();
            if (check.status === "ERROR" && check.line) {
                word = model.getWordAtPosition({ lineNumber: Math.min(check.line, model.getLineCount()), column: check.column || 1 });
                markers.push({
                    severity: area.rstEditor.monaco.MarkerSeverity.Error,
                    message: check.message,
                    startLineNumber: check.line,
                    startColumn: word ? word.startColumn : (check.column || 1),
                    endLineNumber: check.line,
                    endColumn: word ? word.endColumn : model.getLineMaxColumn(Math.min(check.line, model.getLineCount()))
                });
            }
            area.rstEditor.monaco.editor.setModelMarkers(model, "restaurant", markers);
        }
    }

    // used by the pages
    window.restaurant = {
        // language of a code field: sql, plsql, javascript or json
        setLanguage: function (itemId, language) {
            var area = document.getElementById(itemId);
            if (area) {
                area.setAttribute("data-rst-language", language);
                if (area.rstEditor) {
                    area.rstEditor.monaco.editor.setModelLanguage(area.rstEditor.editor.getModel(), language);
                }
            }
        },
        // shows the result of a compile check below the field and in the editor
        showCheck: function (itemId, status, line, column, message) {
            var area = document.getElementById(itemId);
            if (area) {
                showCheck(area, {
                    status: status || "EMPTY",
                    line: parseInt(line, 10) || null,
                    column: parseInt(column, 10) || null,
                    message: message || ""
                });
            }
        }
    };

    /* ---------- request console ---------- */
    function initConsole(box) {
        var method = box.getAttribute("data-method"),
            url = box.querySelector(".rst-try-url"),
            headers = box.querySelector(".rst-try-headers"),
            body = box.querySelector(".rst-try-body"),
            send = box.querySelector(".rst-try-send"),
            result = box.querySelector(".rst-try-result"),
            code = box.querySelector(".rst-try-code"),
            meta = box.querySelector(".rst-try-info"),
            responseHeaders = box.querySelector(".rst-try-response-headers"),
            output = box.querySelector(".rst-try-output");

        function parseHeaders(text) {
            var list = {};
            text.split(/\r?\n/).forEach(function (line) {
                var index = line.indexOf(":");
                if (index > 0) {
                    list[line.substring(0, index).trim()] = line.substring(index + 1).trim();
                }
            });
            return list;
        }

        function show(status, statusText, info, headerText, text) {
            result.classList.add("is-visible");
            code.textContent = status + (statusText ? " " + statusText : "");
            code.className = "rst-try-code " + (status >= 200 && status < 300 ? "is-ok" : status >= 300 && status < 400 ? "is-redirect" : "is-error");
            meta.textContent = info;
            responseHeaders.textContent = headerText;
            output.textContent = text;
        }

        send.addEventListener("click", function () {
            var started = window.performance.now(),
                options = { method: method, headers: parseHeaders(headers.value), credentials: "omit", cache: "no-store" };
            if (body && body.value && method !== "GET" && method !== "DELETE") {
                options.body = body.value;
                if (!Object.keys(options.headers).some(function (name) { return name.toLowerCase() === "content-type"; })) {
                    options.headers["Content-Type"] = "application/json";
                }
            }
            send.disabled = true;
            window.fetch(url.value, options).then(function (response) {
                return response.text().then(function (text) {
                    var lines = [], pretty = text, type = response.headers.get("content-type") || "";
                    response.headers.forEach(function (value, name) { lines.push(name + ": " + value); });
                    // PL/SQL handlers often print JSON without saying so in the content type
                    if (type.indexOf("json") >= 0 || /^\s*[{[]/.test(text)) {
                        try { pretty = JSON.stringify(JSON.parse(text), null, 2); } catch (e) { /* keep the text */ }
                    }
                    show(response.status, response.statusText,
                        Math.round(window.performance.now() - started) + " ms · " + text.length + " characters" + (type ? " · " + type : ""),
                        lines.join("\n"), pretty);
                });
            }).catch(function (error) {
                show(0, "Request failed", String(error), "", "The request could not be sent. Check the URL and whether the browser blocks it.");
            }).then(function () {
                send.disabled = false;
            });
        });

        var curl = box.querySelector(".rst-try-curl");
        if (curl) {
            curl.addEventListener("click", function () {
                var parts = ["curl -i -X " + method],
                    list = parseHeaders(headers.value);
                Object.keys(list).forEach(function (name) {
                    parts.push("-H '" + (name + ": " + list[name]).replace(/'/g, "'\\''") + "'");
                });
                if (body && body.value && method !== "GET" && method !== "DELETE") {
                    if (!Object.keys(list).some(function (name) { return name.toLowerCase() === "content-type"; })) {
                        parts.push("-H 'Content-Type: application/json'");
                    }
                    parts.push("--data '" + body.value.replace(/'/g, "'\\''") + "'");
                }
                parts.push("'" + url.value.replace(/'/g, "'\\''") + "'");
                copyText(parts.join(" "), curl);
            });
        }
    }

    function init() {
        each(document, ".rst-tree", initTree);
        each(document, ".rst-filter", initFilter);
        each(document, "textarea.rst-code, .rst-code textarea", initCode);
        each(document, ".rst-try", initConsole);
        initCopy();
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", init);
    } else {
        init();
    }
})();
