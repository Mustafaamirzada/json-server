# json_server (no Redis)

A lightweight JSON REST API server for Dart, inspired by
[node-json-server](https://www.npmjs.com/package/json-server).

Point it at a JSON file and it serves each top-level key as a REST resource.
Data is kept in memory and changes are written back to the JSON file. This
version has no Redis dependency and is the fastest of the two versions.

## Usage

```sh
dart pub get
dart run bin/json_server.dart db.json
```

The API is then available at `http://localhost:3000`. A sample `db.json` is
included.

### Options

```text
-p, --port <port>   Port to listen on (default: 3000)
-H, --host <host>   Host to bind to (default: 0.0.0.0)
-w, --watch         Reload the database when the file changes
-h, --help          Show help
```

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
