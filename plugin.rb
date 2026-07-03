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
#   Part B -- per-host CSP. Discourse's CSP middleware keys both the base_url
#   protocol (lib/content_security_policy/middleware.rb) and the
#   upgrade-insecure-requests directive (lib/content_security_policy/default.rb)
#   off the GLOBAL SiteSetting.force_https. With force_https on (as any HTTPS
#   clearnet site has it), the http:// onion vhost therefore receives an
#   https:// base_url AND upgrade-insecure-requests -- which forces every
#   subresource fetch to https and breaks the onion. Part B scopes force_https
#   to false for the duration of CSP building on .onion requests only, so the
#   onion emits Discourse's own nonce / strict-dynamic CSP with http origins
#   and no upgrade-insecure-requests. Clearnet is unaffected.
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
# Part B: per-host CSP (force_https treated as false on .onion requests)
# ---------------------------------------------------------------------------

module ::OnionCspRequestScope
  # Wrap the CSP middleware: for a .onion request, mark a thread-local for the
  # duration of super (which builds and sets the CSP header). Nothing outside
  # CSP building observes the flag, so force_https keeps its normal effect on
  # redirects, secure cookies, etc.
  def call(env)
    host = Rack::Request.new(env).host.to_s
    return super unless host.end_with?(".onion")

    Thread.current[:csp_onion_request] = true
    begin
      super
    ensure
      Thread.current[:csp_onion_request] = nil
    end
  end
end

module ::OnionForceHttpsScope
  # While building CSP for a .onion request, report force_https as false so the
  # base_url protocol resolves via request.ssl? (http for the onion vhost) and
  # upgrade-insecure-requests is omitted. Untouched otherwise.
  #
  # Signature-agnostic: Discourse's generated SiteSetting accessor is called
  # with arguments in some code paths, so accept and forward everything to
  # super (a fixed 0-arg override crashed boot with ArgumentError).
  def force_https(*args, **kwargs, &blk)
    return false if Thread.current[:csp_onion_request]
    super
  end
end

after_initialize do
  ::ContentSecurityPolicy::Middleware.prepend(::OnionCspRequestScope)
  ::SiteSetting.singleton_class.prepend(::OnionForceHttpsScope)
end
