use axum::extract::DefaultBodyLimit;
use axum::{
    body::Body,
    extract::{Host, Multipart, State},
    headers::Authorization,
    http::{Request, Response, StatusCode},
    response::IntoResponse,
    routing::post,
    Router, TypedHeader,
};
use clap::Parser;
use flate2::read::GzDecoder;
use headers::authorization::Bearer;
use random_word::Lang;
use serde::Serialize;
use std::{fs, path::PathBuf};
use tar::Archive;
use tower_http::services::ServeDir;
use tracing::{info, warn};

#[derive(Debug, Clone, Parser)]
#[command(author, version, about, long_about = None)]
struct Config {
    #[arg(long, env = "PV_DATA_DIR", default_value = "data")]
    data_dir: String,

    #[arg(long, env = "PV_BASE_DOMAIN", default_value = "localhost:3000")]
    base_domain: String,

    #[arg(long, env = "PV_API_TOKEN")]
    api_token: String,

    #[arg(long, env = "PV_USE_HTTPS", default_value = "false")]
    use_https: bool,
}

#[derive(Serialize)]
struct UploadResponse {
    preview_url: String,
}

#[tokio::main]
async fn main() {
    // Parse config
    let config = Config::parse();

    // Initialize tracing subscriber
    tracing_subscriber::fmt()
        .with_target(false)
        .with_thread_ids(true)
        .with_level(true)
        .with_file(true)
        .with_line_number(true)
        .init();

    // Create data directory if it doesn't exist
    fs::create_dir_all(&config.data_dir).expect("Failed to create data directory");

    let app = Router::new()
        .route("/upload", post(upload_handler))
        .layer(DefaultBodyLimit::max(1024 * 1024 * 50))
        .fallback(handle_subdomain)
        .with_state(config.clone());

    info!(
        "Server running on {}://{}",
        if config.use_https { "https" } else { "http" },
        config.base_domain,
    );
    axum::Server::bind(&"0.0.0.0:3000".parse().unwrap())
        .serve(app.into_make_service())
        .await
        .unwrap();
}

async fn upload_handler(
    State(config): State<Config>,
    Host(host): Host,
    TypedHeader(auth): TypedHeader<Authorization<Bearer>>,
    mut multipart: Multipart,
) -> impl IntoResponse {
    // Check authorization
    if auth.0.token() != config.api_token {
        warn!("Invalid authorization token");
        return (
            StatusCode::UNAUTHORIZED,
            axum::Json(UploadResponse {
                preview_url: "Unauthorized".to_string(),
            }),
        );
    }

    // Check that request is coming from base domain
    if host.as_str() != config.base_domain {
        warn!("Invalid host attempted upload: {}", host.as_str());
        return (
            StatusCode::NOT_FOUND,
            axum::Json(UploadResponse {
                preview_url: "Invalid host".to_string(),
            }),
        );
    }

    while let Some(field) = multipart.next_field().await.unwrap() {
        if let Some("file") = field.name() {
            let data = field.bytes().await.unwrap();

            // Generate random subdomain
            let subdomain = generate_subdomain();
            let dir_path = PathBuf::from(&config.data_dir).join(&subdomain);
            fs::create_dir_all(&dir_path).unwrap();

            // Extract tar.gz
            let decoder = GzDecoder::new(&data[..]);
            let mut archive = Archive::new(decoder);
            archive.unpack(&dir_path).unwrap();

            let scheme = if config.use_https { "https" } else { "http" };
            let preview_url = format!("{}://{}.{}", scheme, subdomain, config.base_domain);
            return (StatusCode::OK, axum::Json(UploadResponse { preview_url }));
        }
    }

    (
        StatusCode::BAD_REQUEST,
        axum::Json(UploadResponse {
            preview_url: "No file provided".to_string(),
        }),
    )
}

async fn handle_subdomain(
    State(config): State<Config>,
    Host(hostname): Host,
    request: Request<Body>,
) -> impl IntoResponse {
    info!("Handling subdomain request: {} {:?}", hostname, request);
    // Return early if base domain
    if hostname == config.base_domain {
        warn!("Request to base domain without path");
        return StatusCode::NOT_FOUND.into_response();
    }

    // Parse the hostname
    let host_parts: Vec<&str> = hostname.split('.').collect();

    // Check if it's a valid subdomain request
    if host_parts.len() < 2 || host_parts[1..].join(".") != config.base_domain {
        warn!("Invalid hostname format: {}", hostname);
        return StatusCode::NOT_FOUND.into_response();
    }

    let subdomain = host_parts[0];

    // Validate subdomain contains only alphanumeric chars, hyphens
    if !subdomain.chars().all(|c| c.is_alphanumeric() || c == '-') {
        warn!("Invalid subdomain characters: {}", subdomain);
        return StatusCode::NOT_FOUND.into_response();
    }

    let dir_path = PathBuf::from(&config.data_dir).join(subdomain);

    // Check if subdomain directory exists
    if !dir_path.exists() {
        warn!("Subdomain directory not found: {}", subdomain);
        return StatusCode::NOT_FOUND.into_response();
    }

    // Serve the static files from the subdomain directory
    info!("Serving static files from: {}", dir_path.display());
    let mut serve_dir = ServeDir::new(dir_path).append_index_html_on_directories(true);
    match serve_dir.try_call(request).await {
        Ok(response) => response.into_response(),
        Err(e) => {
            tracing::warn!("Error serving static files: {}", e);
            Response::builder()
                .status(StatusCode::NOT_FOUND)
                .body(Body::empty())
                .unwrap()
                .into_response()
        }
    }
}

fn generate_subdomain() -> String {
    format!(
        "{}-{}-{}",
        random_word::gen(Lang::En),
        random_word::gen(Lang::En),
        random_word::gen(Lang::En)
    )
}
