# Embedded server UI

A single self-contained binary: axum serves the routes, rust-embed bakes assets and locale
catalogs into the executable, fluent localizes per request, and Tailwind builds the CSS.

Crates (from the workspace menu):

```toml
axum          = { workspace = true, features = ["http1", "json", "tokio", "query", "form"] }
axum-extra    = { workspace = true, features = ["cookie", "typed-header"] }
tower         = { workspace = true, features = ["util"] }
tower-http    = { workspace = true, features = ["timeout", "request-id", "set-header"] }
rust-embed    = { workspace = true, features = ["mime-guess", "deterministic-timestamps"] }
mime_guess    = { workspace = true }
askama        = { workspace = true, features = ["derive"] }
i18n-embed    = { workspace = true, features = ["fluent-system", "rust-embed"] }
i18n-embed-fl = { workspace = true }
unic-langid   = { workspace = true, features = ["macros"] }
```

## Router & state

```rust
use std::sync::Arc;
use axum::{routing::get, Router};
use tower_http::timeout::TimeoutLayer;
use std::time::Duration;

#[derive(Clone)]
pub struct AppState {
    pub store: crate::db::Store,
}

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/", get(handlers::index))
        .route("/static/{*path}", get(static_handler))
        .layer(axum::middleware::from_fn(i18n::negotiate_layer))
        .layer(TimeoutLayer::new(Duration::from_secs(30)))
        .with_state(state)
}
```

## Embedded static assets (rust-embed)

```rust
use axum::{extract::Path, http::{header, StatusCode}, response::{IntoResponse, Response}};
use rust_embed::Embed;

#[derive(Embed)]
#[folder = "static/"]
struct Assets;

pub async fn static_handler(Path(path): Path<String>) -> Response {
    let Some(file) = Assets::get(&path) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let mime = mime_guess::from_path(&path).first_or_octet_stream();
    let cache = match mime.type_().as_str() {
        "image" | "font" => "public, max-age=86400",
        _ => "no-cache",
    };
    (
        [
            (header::CONTENT_TYPE, mime.as_ref()),
            (header::CACHE_CONTROL, cache),
        ],
        file.data,
    )
        .into_response()
}
```

`static/` is created by the Tailwind build (below) and embedded at compile time, so the
binary ships with no external files.

## Localization (fluent via i18n-embed)

Catalogs live under `i18n/<lang>/` and are embedded like static assets:

```
crates/<name>-server/
  i18n/
    en-US/main.ftl
    fr-FR/main.ftl
```

```fluent
# i18n/en-US/main.ftl
app-name = Notes
notes-empty = No notes yet.
notes-count = { $count ->
    [one] { $count } note
   *[other] { $count } notes
}
```

Build a loader once and negotiate the language per request with a middleware that stores the
selected loader in a task-local:

```rust
use i18n_embed::{fluent::{fluent_language_loader, FluentLanguageLoader}, LanguageLoader};
use std::sync::{Arc, LazyLock};
use unic_langid::langid;

#[derive(rust_embed::RustEmbed)]
#[folder = "i18n/"]
struct Localizations;

static LOADER: LazyLock<FluentLanguageLoader> = LazyLock::new(|| {
    let loader = fluent_language_loader!();
    loader.load_languages(&Localizations, &[langid!("en-US")]).expect("load en-US");
    loader
});

tokio::task_local! {
    static REQUEST_LOADER: Arc<FluentLanguageLoader>;
}

pub async fn negotiate_layer(
    req: axum::http::Request<axum::body::Body>,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let requested = req
        .headers()
        .get(axum::http::header::ACCEPT_LANGUAGE)
        .and_then(|v| v.to_str().ok())
        .map(parse_accept_language)
        .unwrap_or_default();

    let loader = Arc::new(LOADER.select_languages(&requested).unwrap_or_else(|_| LOADER.clone()));
    REQUEST_LOADER.scope(loader, next.run(req)).await
}

/// Translate the current request's language. Use `i18n-embed-fl`'s `fl!` for args.
pub fn t(id: &str) -> String {
    REQUEST_LOADER
        .try_with(|l| l.get(id))
        .unwrap_or_else(|_| LOADER.get(id))
}
```

> Validate at startup that the fallback catalog loaded and contains a known key, so a missing
> `.ftl` fails fast instead of rendering message ids to users.

## Templates (askama)

```rust
use askama::Template;

#[derive(Template)]
#[template(path = "index.html")]
struct IndexTemplate {
    notes: Vec<app_common::Note>,
}
```

```html
<!-- templates/index.html -->
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <link rel="stylesheet" href="/static/css/output.css">
  <title>{{ crate::i18n::t("app-name") }}</title>
</head>
<body class="bg-slate-50 text-slate-900">
  <main class="mx-auto max-w-2xl p-8">
    {% if notes.is_empty() %}
      <p class="text-slate-500">{{ crate::i18n::t("notes-empty") }}</p>
    {% else %}
      <ul class="space-y-2">
        {% for note in notes %}<li class="rounded border p-3">{{ note.title }}</li>{% endfor %}
      </ul>
    {% endif %}
  </main>
</body>
</html>
```

## Tailwind pipeline

```css
/* styles/input.css */
@import "tailwindcss";
```

```js
// tailwind.config.js
export default {
  content: ["./templates/**/*.html", "./src/**/*.rs"],
};
```

Build to the embedded `static/` dir (the `Makefile` has `css-build`/`css-dev`):

```bash
tailwindcss -i styles/input.css -o static/css/output.css --minify   # make css-build
tailwindcss -i styles/input.css -o static/css/output.css --watch    # make css-dev
```

`static/css/output.css` is gitignored (it's generated) but **must exist at compile time** so
`rust-embed` can bake it in. Run `make css-build` before `cargo build` — wire it into your
release build (a `build.rs` step or the `Makefile`'s `build` target depending on `css-build`).
