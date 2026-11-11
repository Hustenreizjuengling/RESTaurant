# The RESTaurant exchange format

Version 1. A JSON document that describes ORDS RESTful services: modules with their templates, handlers and
parameters, and optionally roles and privileges.

The machine readable definition is the JSON schema
[`schema/restaurant-ords-v1.schema.json`](schema/restaurant-ords-v1.schema.json).

## Design

- **No ids and no schema name.** Elements are identified by their natural key: a module by its name, a template by
  its URI template, a handler by its method, a parameter by its name. A document can be imported into any schema.
- **Canonical.** RESTaurant always writes the keys in the order shown here, sorts lists by the natural key, leaves
  out properties without a value, indents with two spaces and puts every value on its own line. The same services
  always produce the same bytes, on every database version.
- **Source as lines.** `source` is an array of strings, one per line of code, so a change in a handler is a change
  of the affected lines in a diff. The lines are joined with a line feed on import.
- **Forgiving on import.** Key order does not matter, defaults are applied, `source` may also be a single string.
  Properties RESTaurant does not know are ignored.

## Document

```json
{
  "format": "restaurant-ords",
  "version": 1,
  "meta": { },
  "roles": [ ],
  "privileges": [ ],
  "modules": [ ]
}
```

| Property | Type | | Description |
|---|---|---|---|
| `format` | string | required | Always `restaurant-ords` |
| `version` | integer | required | Version of the format, currently `1`. A document with a higher version is rejected. |
| `meta` | object | optional | Details about the export, see below. Only written when *Add export details* is switched on. Ignored on import. |
| `roles` | array of strings | optional | Names of roles to create |
| `privileges` | array | optional | Privileges, see below |
| `modules` | array | optional | Modules, see below |

`meta` has the properties `generator` (name and version of the tool), `exportedAt` (UTC time in ISO 8601 format),
`schema` (source schema) and `ordsVersion`.

## Module

```json
{
  "name": "kitchen.v1",
  "basePath": "/kitchen/v1/",
  "itemsPerPage": 50,
  "status": "PUBLISHED",
  "originsAllowed": "https://app.example.com",
  "comments": "Back office services",
  "templates": [ ]
}
```

| Property | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Unique name of the module |
| `basePath` | string | required | Base path. A leading and a trailing slash are added if they are missing. |
| `itemsPerPage` | integer | `25` | Default pagination size |
| `status` | string | `PUBLISHED` | `PUBLISHED` or `NOT_PUBLISHED` |
| `originsAllowed` | string | | Comma separated list of allowed origins |
| `comments` | string | | |
| `partial` | boolean | `false` | See [partial modules](#partial-modules) |
| `templates` | array | `[]` | Templates, sorted by `uriTemplate` |

## Template

```json
{
  "uriTemplate": "dishes/:id",
  "priority": 0,
  "etagType": "HASH",
  "comments": "A single dish",
  "handlers": [ ]
}
```

| Property | Type | Default | Description |
|---|---|---|---|
| `uriTemplate` | string | required | URI template or route pattern, relative to the base path |
| `priority` | integer | `0` | 0 (low) to 9 (high) |
| `etagType` | string | `HASH` | `HASH`, `QUERY` or `NONE` |
| `etagQuery` | string | | Required for the ETag type `QUERY`, not written otherwise |
| `comments` | string | | |
| `handlers` | array | `[]` | Handlers, sorted by `method` |

## Handler

```json
{
  "method": "POST",
  "sourceType": "plsql/block",
  "mimesAllowed": "application/json",
  "source": [
    "begin",
    "    insert into dishes (name, course, price)",
    "    values (:name, :course, :price)",
    "    returning dish_id into :id;",
    "end;"
  ],
  "parameters": [ ]
}
```

| Property | Type | Default | Description |
|---|---|---|---|
| `method` | string | required | `GET`, `POST`, `PUT` or `DELETE` |
| `sourceType` | string | required | See the table below |
| `itemsPerPage` | integer | | Pagination size, overrides the module |
| `mimesAllowed` | string | | Comma separated list of accepted content types |
| `mleEnvironment` | string | | MLE environment of a JavaScript handler |
| `comments` | string | | |
| `source` | array of strings, or string | required | The query or the code |
| `parameters` | array | `[]` | Parameters, sorted by `name` |

| `sourceType` | Meaning | Methods |
|---|---|---|
| `json/collection` | Collection query | GET |
| `json/item` | Collection query, one row | GET |
| `resource/lob` | Media resource | GET |
| `plsql/block` | PL/SQL block | all |
| `mle/javascript` | MLE JavaScript | all |
| `json/query` | Query, legacy format | GET |
| `csv/query` | Query as CSV | GET |
| `json/query;type=single` | Query, one row, legacy format | GET |
| `json/query;type=feed` | Feed | GET |

`source` is written as an array of lines. Should a line be longer than 4000 characters, the whole source is written
as one string instead.

## Parameter

```json
{
  "name": "X-ORDS-STATUS-CODE",
  "bindVariable": "status",
  "sourceType": "HEADER",
  "paramType": "INT",
  "accessMethod": "OUT"
}
```

| Property | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Name of the header, URI parameter or response property |
| `bindVariable` | string | | Bind variable in the source. Unique within the handler. |
| `sourceType` | string | `HEADER` | `HEADER`, `URI` or `RESPONSE` |
| `paramType` | string | `STRING` | `STRING`, `INT`, `DOUBLE`, `BOOLEAN`, `LONG`, `TIMESTAMP`, `RESULTSET` or a type your ORDS version supports |
| `accessMethod` | string | `IN` | `IN`, `OUT` or `INOUT` |
| `comments` | string | | |

## Privilege

```json
{
  "name": "kitchen.manage",
  "label": "Kitchen management",
  "description": "Maintain dishes and see reservations",
  "roles": [ "kitchen_staff" ],
  "patterns": [ "/kitchen/internal/*" ],
  "modules": [ "kitchen.v1" ]
}
```

| Property | Type | Description |
|---|---|---|
| `name` | string, required | Name without whitespace |
| `label`, `description`, `comments` | string | |
| `roles` | array of strings | Roles of which a caller needs one. Built-in roles such as `SQL Developer` can be named; they are not listed under `roles` of the document. |
| `patterns` | array of strings | Protected URL patterns |
| `modules` | array of strings | Names of the protected modules |

A privilege is exported with all of its module links, also to modules that are not part of the document. On import,
modules that do not exist in the target schema are ignored and module links the privilege already has there are kept.

OAuth clients are not part of the format. Their secrets cannot be read from ORDS, so a client has to be registered
again in the target schema.

## Partial modules

The export of a single template or handler is still a document with one module. The module carries its attributes as
context, contains only the exported template (with only the exported handler, for a handler export) and is marked:

```json
{
  "name": "menu.v1",
  "basePath": "/menu/v1/",
  "itemsPerPage": 25,
  "status": "PUBLISHED",
  "partial": true,
  "templates": [
    {
      "uriTemplate": "dishes/:id",
      "priority": 0,
      "etagType": "HASH",
      "handlers": [ ]
    }
  ]
}
```

Importing a partial module

- adds or updates the templates and handlers it contains,
- never removes anything, whatever import mode is chosen,
- does not change the attributes of a module that already exists,
- creates the module from the context attributes if it does not exist.

## Several documents

A ZIP archive may contain any number of documents in files that end in `.json`. They are combined before the import:
roles and privileges by name, modules by name. If a module appears in more than one file, later files add to it.
The archive RESTaurant writes has one file per module in `modules/` and `security.ords.json` for roles and
privileges.

## How an import decides what changed

Both sides are brought into the canonical form and compared:

- a **module** is changed when one of its own attributes differs,
- a **template** is changed when one of its own attributes differs,
- a **handler** is changed when anything in it differs, including its source and its parameters.

In merge mode only new and changed elements are written. Because of the way the ORDS API works, writing a template
also writes its handlers again, and a module whose own attributes changed is written completely.

## Compatibility

New optional properties can be added to version 1; readers ignore what they do not know. A change that an older
reader would misunderstand increases `version`.
