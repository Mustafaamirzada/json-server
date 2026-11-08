# json_server

A lightweight JSON REST API server for Dart, inspired by
[node-json-server](https://www.npmjs.com/package/json-server).

Point it at a JSON file and it serves each top-level key as a REST resource.
Data is kept in memory and changes are written back to the JSON file. This
version has no Redis dependency and is the fastest of the two versions.

## Install

Prebuilt binaries are available for Linux and macOS on x86_64 and arm64.

```sh
curl --proto '=https' --tlsv1.2 -sSfL https://raw.githubusercontent.com/Mustafaamirzada/json-server/main/install.sh | sh
```

This installs `json-server` into `~/.local/bin` (or `$XDG_BIN_HOME`). If that
directory is not on your `PATH`, the installer prints the line to add.

Install a specific release or choose another directory:

```sh
curl --proto '=https' --tlsv1.2 -sSfL https://raw.githubusercontent.com/Mustafaamirzada/json-server/main/install.sh \
  | sh -s -- --version v1.0.0 --install-dir /usr/local/bin
```

### Releasing

Push a version tag to build and publish the Linux and macOS binaries:

```sh
git tag v1.0.0
git push origin v1.0.0
```

## Usage

```sh
json-server db.json
```

The API is then available at `http://localhost:3000`. A sample `db.json` is
included.

### From source

```sh
dart pub get
dart run bin/json_server.dart db.json
```

### Options

```text
-p, --port <port>   Port to listen on (default: 3000)
-H, --host <host>   Host to bind to (default: 0.0.0.0)
-w, --watch         Reload the database when the file changes
-h, --help          Show help
```

### Request logging

Every request is printed to the console with a timestamp, client IP, HTTP
method, route, status code, and duration. Colors are used when the terminal
supports ANSI escapes.

```text
[14:32:07] 127.0.0.1       GET     /posts?published=true 200   2.4ms
[14:32:09] 127.0.0.1       POST    /posts                201   1.1ms
[14:32:12] 127.0.0.1       GET     /posts/999            404   0.3ms
```

When using the library directly, pass `logRequests: false` to disable it.

## Routes

| Method | Route | Description |
| --- | --- | --- |
| GET | `/posts` | List posts |
| GET | `/posts/1` | Get a post |
| POST | `/posts` | Create a post |
| PUT | `/posts/1` | Replace a post |
| PATCH | `/posts/1` | Update part of a post |
| DELETE | `/posts/1` | Delete a post |
| GET | `/posts/1/comments` | List comments belonging to post 1 |
| GET | `/db` | Read the whole database |
| GET | `/profile` | Read a singular resource |
| POST | `/profile` | Replace a singular resource |
| PUT/PATCH | `/profile` | Update a singular resource |

Changes made through `POST`, `PUT`, `PATCH`, and `DELETE` are written back to
the JSON file.

## Query parameters

- Filter by field: `/posts?title=Hello`
- Filter operators: `_ne`, `_gte`, `_lte`, `_like`
  (`/posts?views_gte=200`)
- Full-text search: `/posts?q=hello`
- Sort: `/posts?_sort=views&_order=desc`
- Pagination: `/posts?_page=2&_limit=10` (adds `X-Total-Count` response header)
- Slice: `/posts?_start=0&_end=10`
- Embed children: `/posts?_embed=comments`
- Expand parent: `/comments?_expand=post`

New resources get an auto-incremented `id` based on the existing maximum id.
CORS is enabled for all routes.
