# Changelog

## 1.1.0

- Source editor with syntax highlighting for SQL, PL/SQL and JavaScript, using the Monaco editor that ships with APEX
- Compile check: the database parses the source of a handler while you type, without running it, and the first
  error is marked with its line and column
- *Check Handlers* runs the compile check for a module or for all modules, for example after an import
- JSON editor for pasted exports on the import page

## 1.0.0

First release.

- Editor for modules, templates, handlers and parameters with a service tree
- Request console, source search, duplicate module
- Privileges, roles and OAuth clients
- AutoREST objects and schema settings
- Export as JSON, SQL script or ZIP archive for a schema, modules, a template or a handler
- Import with review, merge, replace and skip
- Command line installer
