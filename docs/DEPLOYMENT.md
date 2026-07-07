# Lokrel Website Deployment

Last checked: 2026-07-07

## Current Hosts

- GitHub Pages preview: `https://lokrel.github.io/lokrel/`
- Alibaba Cloud ECS public IP: `8.155.29.226`
- ECS instance: `i-f8z3uij4zdxki8ghk1ka`, region `cn-heyuan`, instance name `doutingyou.com`

## DNS

Alibaba Cloud DNS authoritative records currently seen:

- `www.lokrel.com` `A` `8.155.29.226`
- `lokrel.com` apex: missing `@` `A` record
- `doutingyou.com` and `www.doutingyou.com` point to `8.155.29.226`

Add this record when the apex should go live:

```text
Host: @
Type: A
Value: 8.155.29.226
TTL: 10 minutes
```

## Server Layout

- doutingyou site root: `/usr/share/nginx/html`
- lokrel site root: `/usr/share/nginx/lokrel`
- doutingyou nginx config: `/etc/nginx/conf.d/doutingyou.conf`
- lokrel nginx config: `/etc/nginx/conf.d/lokrel.conf`
- doutingyou certificate: `/etc/letsencrypt/live/doutingyou.com/`

Use Alibaba Cloud Workbench for root access. Local SSH key access was not available when this was checked.

## Refresh Lokrel Site

```bash
set -euo pipefail
site_dir=/usr/share/nginx/lokrel
mkdir -p "$site_dir/assets"
curl -fsSL https://raw.githubusercontent.com/Lokrel/lokrel/main/docs/index.html -o "$site_dir/index.html.tmp"
curl -fsSL https://raw.githubusercontent.com/Lokrel/lokrel/main/docs/assets/lokrel-icon.png -o "$site_dir/assets/lokrel-icon.png.tmp"
mv "$site_dir/index.html.tmp" "$site_dir/index.html"
mv "$site_dir/assets/lokrel-icon.png.tmp" "$site_dir/assets/lokrel-icon.png"
chown -R root:root "$site_dir"
chmod 755 "$site_dir" "$site_dir/assets"
chmod 644 "$site_dir/index.html" "$site_dir/assets/lokrel-icon.png"
nginx -t
systemctl reload nginx
```

Verify on the server:

```bash
curl -I -H 'Host: www.lokrel.com' http://127.0.0.1/
```

Expected result: `HTTP/1.1 200 OK`.

## Public Access Note

As of 2026-07-07, nginx serves the lokrel site correctly inside the ECS host, but public requests to `www.lokrel.com` are blocked before they reach nginx:

```text
HTTP/1.1 403 Forbidden
Server: Beaver
```

`doutingyou.com` works on the same IP, so this is likely Alibaba Cloud's ICP filing / domain access layer for the new unfiled domain. HTTPS for lokrel should be configured after the domain is allowed through Alibaba Cloud or by using a DNS-01 certificate flow.
