# Static Site Preview Daemon (`sspd`)

A lightweight daemon for hosting temporary static site previews, primarily designed for CI/CD preview deployments. This project was created as a testbed for AI coding tools, so while functional, the code quality may not be production-ready.

## Overview

SSPD provides a simple way to host multiple static sites under subdomains of a base domain. Each preview site gets a randomly generated subdomain (e.g., `happy-green-tree.preview.example.com`).

```
Usage: sspd [OPTIONS] --api-token <API_TOKEN>

Options:
      --data-dir <DATA_DIR>        [env: PV_DATA_DIR=] [default: data]
      --base-domain <BASE_DOMAIN>  [env: PV_BASE_DOMAIN=] [default: localhost:3000]
      --api-token <API_TOKEN>      [env: PV_API_TOKEN=foo]
      --use-https                  [env: PV_USE_HTTPS=]
  -h, --help                       Print help
  -V, --version                    Print version
```

## Features

- Upload static sites via a simple API endpoint
- Automatic subdomain generation using random English words
- Serves static files with index.html fallback
- NixOS module included for easy deployment
- Basic authentication using API tokens
- Optional NGINX integration with automatic HTTPS support

## Usage

### API Endpoint

Upload your static site as a tar.gz archive (make sure there is no additional directory structure in the archive, use `tar -czf site.tar.gz -C /path/to/site .` to create the archive):

```bash
curl -X POST https://preview.example.com/upload \
     -H "Authorization: Bearer your-api-token" \
     -F "file=@site.tar.gz"
```

The response will include the preview URL:

```json
{
"preview_url": "https://happy-green-tree.preview.example.com"
}
```
### NixOS Configuration

```nix
{
    services.sspd = {
        enable = true;
        baseDomain = "preview.example.com";
        apiTokenFile = "/path/to/token-file";
    };
}
```

## Development Notes

This project was created to experiment with AI coding tools and serves as a demonstration of:
- Rust web service development with Axum
- NixOS module creation
- Basic file handling and static file serving
- Domain name handling and subdomain routing

The code may not follow all best practices and could benefit from:
- Better error handling
- Input validation
- Rate limiting
- Preview site cleanup
- Tests

## License

MIT


