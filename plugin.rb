# name: discourse-multi-hostname-canonical
# about: emit Discourse URLs keyed to the current request host
# version: 0.1
# authors: Whonix
# url: https://github.com/org-ai-assisted/discourse-whonix-onion-host-support
# .
# Replaces the host-pair-hardcoded EnforceHostname monkey-patch with a
# project-agnostic mechanism that makes Discourse emit per-host URLs
# (canonical, Discourse.base_url, redirects, og:url, og:image, favicon,
# apple-touch-icon, etc.) for any host in the validated host_names list.
# .
# Combined with DISCOURSE_BACKUP_HOSTNAME=<onion> in containers/app.yml
# (which populates database.yml host_names with the onion), this lets a
# single Discourse instance serve clearnet AND onion vhosts with each
# vhost emitting URLs keyed to the matched request host -- eliminating
# the need for nginx sub_filter response-body rewrites.
# .
# Three pieces:
#   1. A Rack middleware stashes env[Rack::HTTP_HOST] into a thread-
#      local at the start of every request. By the time it runs, the
#      upstream EnforceHostname middleware has already validated the
#      host against RailsMultisite host_names and canonicalised it.
#   2. We prepend a module onto Discourse's singleton class so
#      Discourse.current_hostname reads the thread-local first, falling
#      back to upstream behaviour (which returns host_names.first
#      regardless of the request host).
#   3. SiteIconManager memoises fully-qualified favicon / apple-touch-
#      icon / og:image URLs in a hostname-agnostic DistributedCache.
#      When requests alternate between clearnet and onion vhosts the
#      cache becomes poisoned. We bypass the cache for these keys.
# .
# SiteSetting.force_hostname keeps its precedence as in upstream -- if
# set, this plugin's thread-local short-circuits and the fix doesn't
# take effect.

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

# Register the middleware before Rails freezes the stack. A Railtie
# inserted while the plugin file is being evaluated runs at the right
# initialisation phase.
#
# Insertion ordering is a security property: our middleware must run
# AFTER upstream Middleware::EnforceHostname so that env[HTTP_HOST] has
# already been validated against host_names. Without that validation,
# stashing the raw Host header into Thread.current would let an
# attacker-controlled value propagate into canonical / og:url /
# redirect Location / email-link emission -- a host-injection vector.
# So if EnforceHostname is unavailable (SKIP_ENFORCE_HOSTNAME=1 made
# upstream skip the require, or another component removed it from the
# stack), we disable the plugin and warn loudly rather than fall back
# to installing the middleware in an unsafe position.
class ::MultiHostnameRailtie < Rails::Railtie
  WARN_MSG =
    "[discourse-multi-hostname-canonical] " \
    "Middleware::EnforceHostname not present in the middleware stack; " \
    "plugin disabled. Host validation is a prerequisite -- without it, " \
    "stashing env[HTTP_HOST] would be a host-injection vector. " \
    "Unset SKIP_ENFORCE_HOSTNAME (or set it to 0) to enable the plugin."

  initializer "multi_hostname_canonical.add_middleware",
              before: :build_middleware_stack do |app|
    if defined?(Middleware::EnforceHostname)
      begin
        app.config.middleware.insert_after \
          Middleware::EnforceHostname,
          ::MultiHostnameMiddleware
      rescue RuntimeError => e
        # ActionDispatch::MiddlewareStack#insert_after raises a bare
        # RuntimeError ("No such middleware to insert after: ...") when
        # the target middleware is missing from the stack. Re-raise
        # any other RuntimeError so unrelated failures are not
        # swallowed.
        raise unless e.message.include?("No such middleware to insert after")
        warn WARN_MSG
      end
    else
      # SKIP_ENFORCE_HOSTNAME=1 made upstream skip the require so the
      # constant is undefined.
      warn WARN_MSG
    end
  end
end
