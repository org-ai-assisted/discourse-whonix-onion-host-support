# discourse-multi-hostname-canonical

Discourse plugin that makes a single instance emit per-host URLs when it
serves more than one hostname (typical case: clearnet + Tor onion
mirror).

## What it solves

Upstream Discourse hard-codes `Discourse.current_hostname` to
`RailsMultisite::ConnectionManagement.current_hostname`, which returns
`host_names.first` of the database connection config -- always the
first configured hostname, regardless of which one served the request.

For an instance serving both a clearnet and an onion host, that means
the onion vhost emits canonical URLs, `og:url`, `og:image`, favicon,
apple-touch-icon and Discourse-generated redirect `Location` headers
that all point at the clearnet host -- a deanonymisation vector that
historically had to be papered over with nginx `sub_filter`
response-body rewrites.

This plugin makes those URL emission paths use the actual request
host. With it installed:

- Per-vhost canonical / og:url / og:image / favicon / apple-touch-icon
  all match the host the request came in on.
- Redirect `Location` headers stay on the visited host.
- `sub_filter` rewrites are no longer required.

## How it works

Three small pieces, ~50 LOC total.

1. **Rack middleware** stashes `env[Rack::HTTP_HOST]` into
   `Thread.current[:discourse_request_hostname]` per request. By the
   time it runs, the upstream `Middleware::EnforceHostname` has already
   validated the host against `host_names` and canonicalised it (or
   replaced it with the canonical, if not in the list).
2. **`Discourse.current_hostname` override** prepended on the singleton
   class: reads the thread-local first, falls back to upstream
   behaviour. `SiteSetting.force_hostname` keeps its existing
   precedence.
3. **`SiteIconManager` cache bypass**: the eight icon `*_url` methods
   recompute fresh per request rather than serving the hostname-
   agnostic `DistributedCache` value (otherwise the first vhost to hit
   poisons the cache for the other).

The middleware is inserted via a `Rails::Railtie` at
`before: :build_middleware_stack`, immediately after
`Middleware::EnforceHostname`.

## Requirements

- **`DISCOURSE_BACKUP_HOSTNAME` must be set** in `containers/app.yml`
  to the second hostname (the onion, for the typical use case).
  Upstream Discourse pushes `backup_hostname` into the database
  connection's `host_names` array
  (`app/models/global_setting.rb:151-157`), which is what
  `Middleware::EnforceHostname` checks against. Without this, the
  upstream middleware rewrites the second host to the canonical before
  this plugin's middleware ever sees it.
- **`SiteSetting.force_hostname` must remain unset (`""`)**. If set,
  it short-circuits `Discourse.current_hostname` before the
  thread-local is consulted, and the plugin has no effect. Verify
  with:
  ```ruby
  rails r 'puts SiteSetting.force_hostname.inspect'  # => ""
  ```

## Installation (discourse_docker / official Docker image)

In `containers/app.yml`:

```yaml
env:
  DISCOURSE_HOSTNAME: forums.whonix.org
  DISCOURSE_BACKUP_HOSTNAME: forums.dds6qkxpwdeubwucdiaord2xgbbeyds25rbsgr73tbfpqpt4a6vjwsyd.onion

hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/org-ai-assisted/discourse-whonix-onion-host-support.git
```

Then `./launcher rebuild app`.

## Verification

After install + rebuild, on each vhost:

```bash
UA="Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
CLEAR=forums.whonix.org
ONION=forums.dds6qkxpwdeubwucdiaord2xgbbeyds25rbsgr73tbfpqpt4a6vjwsyd.onion
ROUTES=(/ /latest /categories /about /latest.json /categories.json
        /t/1.json /site.json /about.json /manifest.webmanifest
        /opensearch.xml /sitemap.xml)
for r in "${ROUTES[@]}"; do
  echo "=== $r (onion) ==="
  torsocks curl -s -A "$UA" "http://${ONION}${r}" \
    | grep -oE "${CLEAR}|${ONION}" | sort | uniq -c
done
```

Every onion response must have zero `${CLEAR}` matches.

## History

This repo previously hosted a much smaller plugin (Jan 2019, by Miguel
Jacq) that monkey-patched `Middleware::EnforceHostname` with a
hard-coded pair of hostnames. That plugin allowed Discourse to accept
the onion `Host:` header, but did not fix per-host URL emission --
canonical URLs, `og:url`, favicon, redirect `Location` headers all
still pointed at the clearnet host. The dist-encrypted nginx config
papered over this with `sub_filter` response-body rewrites.

The current plugin uses the documented `DISCOURSE_BACKUP_HOSTNAME` env
var for host acceptance (no monkey-patch) and adds per-host URL
emission, making the nginx `sub_filter` rules redundant. It is
project-agnostic -- the same file is also published at
`org-ai-assisted/discourse-kicksecure-onion-host-support` for the
Kicksecure forums.

## License

Same as the original plugin (matches the LICENSE file in this repo).
