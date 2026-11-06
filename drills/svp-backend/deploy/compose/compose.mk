# Failure drills on the running stack (deploy/compose/drills/). They stop, kill and start
# containers through $(COMPOSE), run rpk inside the Redpanda container and only SELECT from
# svp_video, svp_engagement and svp_feed; every service runs again when a drill ends, passed or not.
# measure-freshness also produces fake follow events to Redpanda (tools/fakefollows) and removes
# them with unfollow events when it ends. drill-rate-limit and drill-upload-cleanup recreate the
# gateway or video-service with drill-only settings and put the defaults back when they end.
# Every script (smoke too) deletes the per-IP register rate limit keys in Redis db 10 first: lab
# only, since every run registers from the one Docker bridge address.
# N defaults to 5, but to 100 for measure-explore-cache.
N ?= 5
FOLLOWERS ?= 10000
# A drill recreates services (the drill-only settings, and the restore when it ends), so it runs
# compose with the telemetry state the stack was started with: on a stack from `make up OBS=off`
# (its Go services run with OTEL_SDK_DISABLED=true) telemetry stays off, instead of coming back on
# halfway through an overhead measurement. The inspect template prints
# `off` or nothing, never another setting of the containers.
TELEMETRY_OFF_RUNNING = $(shell ids=`$(COMPOSE) ps -q`; test -z "$$ids" || env -u DOCKER_DEFAULT_PLATFORM docker inspect \
	--format '{{range .Config.Env}}{{if eq . "OTEL_SDK_DISABLED=true"}}off{{end}}{{end}}' $$ids | grep -m 1 -x off)
DRILL_COMPOSE = $(if $(TELEMETRY_OFF_RUNNING),$(COMPOSE_UP_off),$(COMPOSE))

drill-kill-worker: env-required ## Kill media-worker mid-transcode, restart it; check the video still goes READY, once
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/kill-worker.sh $(SMOKE_URL)

drill-duplicates: env-required ## Replay transcode.completed and video.uploaded with rpk group seek; check nothing changes
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/duplicate-events.sh $(SMOKE_URL)

drill-duplicates-feed: env-required ## Replay view.recorded, user.followed and video.ready; check counters and feed rows do not change
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/duplicate-feed-events.sh $(SMOKE_URL)

drill-engagement-down: env-required ## Stop engagement-service; check the breaker opens (likes 503 in < 100 ms), the feed answers without stats, the breaker closes on restart
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/engagement-down.sh $(SMOKE_URL)

drill-rate-limit: env-required ## Rate limits: 429 RATE_LIMITED with Retry-After, UP-7 TOO_MANY_UPLOADS; with Redis unreachable the fallback still limits logins
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/rate-limit.sh $(SMOKE_URL)

measure-explore-cache: env-required ## N (default 100, max 150) concurrent explore requests on an empty cache read Postgres once, a second wave never
	COMPOSE='$(DRILL_COMPOSE)' N='$(if $(filter file,$(origin N)),100,$(N))' deploy/compose/drills/measure-explore-cache.sh $(SMOKE_URL)

drill-upload-cleanup: env-required ## Abandon an upload with a 20 s limit; check it goes FAILED and its object is deleted, a completed one is untouched
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/upload-cleanup.sh $(SMOKE_URL)

# The two observability drills need the stack of `make up OBS=lgtm`. They read Prometheus, Tempo and
# Loki through Grafana's datasource proxy, Alertmanager's API and GlitchTip's API, with the
# read-only token SENTRY_AUTH_TOKEN read from .env and never printed.
drill-alert-to-sentry: env-required ## OBS=lgtm: stop feed-service; time the page alert, then find its trace (Tempo), log line (Loki) and GlitchTip event; T4 - T1 under 5 min
	COMPOSE='$(DRILL_COMPOSE)' deploy/compose/drills/alert-to-sentry.sh $(SMOKE_URL)

# Game day, on the stack of `make up OBS=lgtm` with a READY video:
# engagement-service stopped under the background load of k6 profile local (K6_IMAGE, held SVP_K6_HOLD, default 60m),
# T0 and T1 (the CircuitBreakerOpen page in Alertmanager) timed, the on-call's marks from another terminal; the stack is
# put back and the timeline, report and k6 summary written to .k6/gameday-<time>/ when it ends. LOCAL LAB ONLY: resets
# the register rate limit like the drills above.
M ?=
gameday: env-required ## OBS=lgtm: game day, engagement-service stopped under k6 load; times the page, waits for the on-call (runbook only) until make gameday-end or Ctrl-C; .k6/gameday-<time>/
	COMPOSE='$(DRILL_COMPOSE)' K6_IMAGE='$(K6_IMAGE)' deploy/compose/drills/gameday.sh start $(SMOKE_URL)

gameday-mark: ## Mark the running game day's timeline: M=diagnosed|mitigated|recovered
	deploy/compose/drills/gameday.sh mark '$(M)'

gameday-end: ## End the running game day: put the stack back, stop the load, print the report
	deploy/compose/drills/gameday.sh end

measure-ready: env-required ## Time CompleteUpload to READY for N (default 5) 60 s 1080p videos; p50, max, worker CPU/RAM
	COMPOSE='$(DRILL_COMPOSE)' N='$(N)' deploy/compose/drills/measure-ready.sh $(SMOKE_URL)

measure-freshness: env-required ## Time video.ready to the last timeline row for N (at most 10) videos to FOLLOWERS (default 10000) fake followers
	COMPOSE='$(DRILL_COMPOSE)' N='$(N)' FOLLOWERS='$(FOLLOWERS)' deploy/compose/drills/measure-freshness.sh $(SMOKE_URL)
