# Changelog

## 1.1.1

Found by playing the whole application through, see `tests/e2e`.

- Removing the privilege of a module on the module page makes the module public again
- The legacy source types *Query One Row* and *Feed* can be selected
- AutoREST objects that are disabled stay in the list and can be enabled again
- Messages appear at the bottom of the window and no longer cover the buttons of the page header
- Opening a module, template or handler that was deleted in the meantime leads to the module list
- An export without a selected module is reported on the page
- The menu entry *Export* opens the export with its defaults
- End-to-end walkthrough of the application in `tests/e2e`

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
