/* RESTaurant - client side behaviour: service tree, list filters, copy buttons,
   code fields and the request console. No external libraries are used. */
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

    /* ---------- code fields: line numbers, tab key indents ---------- */
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
            addLineNumbers(area);
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
                    if (type.indexOf("json") >= 0) {
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
