# name: discourse-multi-hostname-canonical
# about: emit Discourse URLs and CSP keyed to the current request host
# version: 0.2
# authors: Kicksecure
# url: https://github.com/Kicksecure/discourse-multi-hostname-canonical
# .
# A single Discourse instance serving BOTH a clearnet vhost and an onion
# vhost needs two per-host fixes. This plugin bundles both, project-agnostic
# (no hostname is hardcoded; the onion is recognised by its .onion suffix and
# the clearnet host is whatever DISCOURSE_HOSTNAME is):
# .
#   Part A -- per-host URL emission. Makes Discourse emit canonical,
#   base_url, og:url, og:image, favicon, apple-touch-icon and redirect
#   Location URLs keyed to the matched request host, instead of always
#   host_names.first. Needs DISCOURSE_BACKUP_HOSTNAME=<onion> in
#   containers/app.yml (populates database.yml host_names with the onion).
# .
#   Part B -- per-host CSP. Discourse's CSP adds upgrade-insecure-requests when
#   SiteSetting.force_https is on (as any HTTPS clearnet site has it), which
#   forces every subresource fetch to https and breaks the http:// onion vhost.
#   Part B removes ONLY that directive, and ONLY for the onion host, by editing
#   the built CSP directives (NOT by overriding force_https, which would affect
#   redirects / cookies / URL generation for the whole request). Clearnet is
#   unaffected. The onion is identified by Part A's already-validated per-request
#   hostname, so Part B inherits Part A's EnforceHostname prerequisite and stays
#   inert without it.
# .
# SiteSetting.force_hostname keeps its upstream precedence -- if set, Part A's
# thread-local short-circuits and the URL fix does not take effect.

# ---------------------------------------------------------------------------
# Part A: per-host URL emission
# ---------------------------------------------------------------------------

module ::MultiHostnameThreadLocal
  KEY = :discourse_request_hostname

  def current_hostname
    SiteSetting.force_hostname.presence ||
      Thread.current[KEY] ||
      super
  end
end

class ::MultiHostnameMiddleware
  KEY = ::MultiHostnameThreadLocal::KEY

  def initialize(app)
    @app = app
  end

  def call(env)
    host_with_port = env[Rack::HTTP_HOST]
    if host_with_port
      Thread.current[KEY] = host_with_port.sub(/:\d+\z/, "")
    end
    @app.call(env)
  ensure
    Thread.current[KEY] = nil
  end
end

::Discourse.singleton_class.prepend(::MultiHostnameThreadLocal)

module ::MultiHostnameIconRecompute
  %i[
    digest_logo mobile_logo mobile_logo_dark large_icon manifest_icon
    favicon apple_touch_icon opengraph_image
  ].each do |name|
    define_method("#{name}_url") do
      icon = public_send(name)
      icon ? full_cdn_url(icon.url) : ""
    end
  end
end

# SiteIconManager isn't constant-loaded yet during plugin activation;
# defer the prepend until after Rails finishes booting.
after_initialize do
  ::SiteIconManager.singleton_class.prepend(::MultiHostnameIconRecompute)
end

# Register the Part A middleware before Rails freezes the stack. It MUST run
# AFTER upstream Middleware::EnforceHostname so env[HTTP_HOST] is already
# validated against host_names -- otherwise an attacker-controlled Host would
# propagate into canonical / og:url / redirect Location / email links (a
# host-injection vector). If EnforceHostname is absent (SKIP_ENFORCE_HOSTNAME=1
# or another component removed it), disable rather than install unsafely.
class ::MultiHostnameRailtie < Rails::Railtie
  WARN_MSG =
    "[discourse-multi-hostname-canonical] " \
    "Middleware::EnforceHostname not present in the middleware stack; " \
    "URL-emission fix disabled. Host validation is a prerequisite -- without " \
    "it, stashing env[HTTP_HOST] would be a host-injection vector. " \
    "Unset SKIP_ENFORCE_HOSTNAME (or set it to 0) to enable."

  initializer "multi_hostname_canonical.add_middleware",
              before: :build_middleware_stack do |app|
    if defined?(Middleware::EnforceHostname)
      begin
        app.config.middleware.insert_after \
          Middleware::EnforceHostname,
          ::MultiHostnameMiddleware
      rescue RuntimeError => e
        raise unless e.message.include?("No such middleware to insert after")
        warn WARN_MSG
      end
    else
      warn WARN_MSG
    end
  end
end

# ---------------------------------------------------------------------------
# Part B: per-host CSP (drop upgrade-insecure-requests on .onion requests)
# ---------------------------------------------------------------------------

# With SiteSetting.force_https on (any HTTPS clearnet site), Discourse's CSP adds
# `upgrade-insecure-requests`, which forces every subresource fetch to https and
# breaks an http:// onion vhost. We remove ONLY that directive, and ONLY for the
# onion host.
#
# Design (addresses three failure modes of a force_https override):
#   * We do NOT override SiteSetting.force_https. Scoping a force_https=false
#     around the CSP middleware's `call` would span the whole downstream
#     `@app.call`, wrongly affecting redirects, secure-cookie flags and URL
#     generation for the entire request -- not just CSP. Editing the built CSP
#     directives touches only the header.
#   * The host is Part A's already-VALIDATED per-request hostname
#     (Thread.current[:discourse_request_hostname], stashed by
#     MultiHostnameMiddleware from env[HTTP_HOST] AFTER Middleware::EnforceHostname
#     validated it) -- NOT the spoofable Rack::Request#host / X-Forwarded-Host.
#   * If EnforceHostname is unavailable, Part A does not install its middleware,
#     so the thread-local stays nil and Part B is inert: an attacker-supplied
#     `*.onion` Host header cannot activate it. (Same prerequisite as Part A.)
#
# Only upgrade-insecure-requests depends on the request scheme in Discourse's
# DEFAULT CSP; base_url is not interpolated into any default directive
# (script-src is 'strict-dynamic' 'wasm-unsafe-eval'; other sources are 'self' /
# 'none' / 'blob:'), so no per-host http origin rewrite is needed.
module ::OnionCspDropUpgradeInsecure
  # Signature-agnostic (forward everything to super): the upstream
  # ContentSecurityPolicy::Default#initialize signature has varied across
  # Discourse versions (e.g. base_url:), and a hard-coded keyword list would
  # raise ArgumentError and break CSP generation site-wide on an upgrade.
  def initialize(*args, **kwargs, &blk)
    super
    host = Thread.current[::MultiHostnameThreadLocal::KEY].to_s.downcase.chomp(".")
    @directives.delete(:upgrade_insecure_requests) if host.end_with?(".onion")
  end
end

after_initialize do
  ::ContentSecurityPolicy::Default.prepend(::OnionCspDropUpgradeInsecure)
end
