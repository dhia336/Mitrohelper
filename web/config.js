// API '' = same site (one Worker serves both). TS = Turnstile SITE key (public); '' disables the CAPTCHA.
// On localhost and any host containing 'staging' we use Cloudflare's dummy INVISIBLE key (always passes) so tests need no real challenge;
// the matching test Worker must use the dummy SECRET 1x0000000000000000000000000000000AA (or no TURNSTILE_SECRET). Everything else = production key.
window.CFG={API:'',TS:/^(localhost|127\.0\.0\.1|.*staging.*)$/.test(location.hostname)?'1x00000000000000000000BB':'0x4AAAAAAFlm_A4hyYrAQoBw'};
