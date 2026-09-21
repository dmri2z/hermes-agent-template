FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# Which hermes-agent revision to install. Accepts any git ref the upstream
# repo publishes — a release tag (recommended for reproducibility) or a
# branch name (`main`) for bleeding edge.
#
# To bump: check https://github.com/NousResearch/hermes-agent/releases for the
# newest tag (format `vYYYY.M.D`, optionally with a `.PATCH` suffix, e.g.
# `v2026.5.29.2`) and update the default below. Use `main` only if you accept
# that every rebuild can pull arbitrary new upstream commits.
ARG HERMES_REF=v2026.9.11

# Persist the build arg into the runtime env so the admin UI can display which
# Hermes release this image actually pins. Reading it (rather than hardcoding a
# version in the template) keeps the badge honest when someone overrides
# HERMES_REF as a Railway service variable to pin an older release — a Railway
# runtime variable simply shadows this ENV, so the UI still shows the truth.
ENV HERMES_REF=${HERMES_REF}

# tini = tiny init that we run as PID 1. Without it, hermes's grandchild
# processes (MCP stdio servers, git, bun, browser daemons spawned by tools)
# reparent to PID 1 when their parents exit and pile up as zombies. After
# weeks of uptime that exhausts the kernel's PID table → "fork: cannot
# allocate memory" and the container dies. tini reaps zombies in the
# background and forwards SIGTERM/SIGINT to our entrypoint so Railway's
# stop signal still triggers our graceful shutdown. Standard container init
# (same as Docker's `--init` flag and Kubernetes' pause container).
#
# Node.js is required only at build time to compile the Hermes React dashboard.
# We strip the source + apt lists afterwards to keep the image lean.
#
# Keep setup_22.x. v2026.8.3's new .npmrc sets engine-strict=true, so hermes'
# `node >=22.22.0` + `npm <11.10.0 || >=11.17.0` is now a hard EBADENGINE build
# failure, not a warning — setup_24.x bundles an npm that satisfies neither.
# procps (ps / pgrep / pkill) is installed EXPLICITLY, not inherited. hermes
# shells out to it for gateway PID ownership (hermes_cli/gateway.py: `ps -o
# ppid= -p`, `ps -Aww -o pid=,command=`), the dashboard's process view
# (dashboard_procs.py) and gitlock.py's `pgrep -x git`. Only the first guards
# with shutil.which(); the rest assume it exists. The base image tag is a
# moving target and a 2026-09 rebuild of it stopped shipping procps, which
# silently degraded those paths — pin the dependency here rather than trust
# whatever the upstream tag happens to contain.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates git tini procps && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# ── SQLite: replace the distro's 3.40.1 ───────────────────────────────────
# Debian bookworm ships SQLite 3.40.1, which fails hermes on two counts.
# NEITHER is fixable by redeploying — the version is pinned by the base
# image's distro, so it has to be overridden here.
#
#  1. The WAL-reset corruption bug (https://sqlite.org/wal.html#walresetbug).
#     `hermes doctor` flags every WAL database under $HERMES_HOME for this and
#     names 3.51.3+ / 3.50.7 / 3.44.6 as the fixed releases: a vulnerable
#     fresh-opener can unlink a live WAL/SHM out from under a running gateway.
#     hermes' own salvage lane (session_lost_and_found.py) refuses to run on a
#     vulnerable build for the same reason.
#
#  2. hermes' FTS write-health probe (_db_opens_cleanly in
#     hermes_state_repair.py) ends with `INSERT INTO <fts>(<fts>)
#     VALUES('flush')`. fts5 gained `flush` after 3.40.1, so on bookworm it
#     raises "SQL logic error" — identical to what a nonsense command returns,
#     verified against a brand-new empty fts5 table. `hermes doctor` therefore
#     reports "state.db FTS write corruption" against a perfectly healthy
#     database, `hermes sessions repair` reports success, and the next probe
#     fails again. Forever. Each round costs a gateway outage, and doctor's
#     advice ("restore from the backup copy beside state.db") names a file the
#     repair path never created — it aborts on its live-writer preflight,
#     before the backup step, whenever the gateway is up.
#
# CPython's _sqlite3 links libsqlite3.so.0 dynamically and /usr/local/lib
# precedes /lib/<triplet> in ld.so.conf, so installing a newer build there and
# running ldconfig overrides Debian's without rebuilding CPython.
#
# --soname=legacy is LOAD-BEARING: since the 3.48 switch to autosetup, the
# default is NO soname, which installs a bare libsqlite3.so that nothing
# linked against libsqlite3.so.0 will ever load. "legacy" restores
# libsqlite3.so.0, which ldconfig then symlinks. --all matches Debian's
# fts4 + fts5 + rtree; the CFLAGS cover the other build options Debian enables
# that callers may expect.
#
# Build deps are purged inside the same layer so the toolchain never lands in
# the image. The apt-mark dance around that purge is defensive, not cosmetic:
# a bare `--auto-remove` sweeps every auto-installed package nothing manual
# depends on, which can reap packages the base image shipped and hermes still
# needs, not just build-essential's own dependencies. Pinning the pre-existing
# auto set to manual for the duration confines the purge; the marks are
# restored afterwards so a later `apt autoremove` still behaves normally.
#
# To bump: take the tarball and its SHA3-256/SHA-256 from
# https://sqlite.org/download.html and keep it at or above 3.51.3.
ARG SQLITE_YEAR=2026
ARG SQLITE_VERSION=3530400
ARG SQLITE_SHA256=0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c
RUN apt-get update && \
    apt-mark showauto > /tmp/apt-auto-before.txt && \
    xargs -r -a /tmp/apt-auto-before.txt apt-mark manual > /dev/null && \
    apt-get install -y --no-install-recommends build-essential && \
    curl -fsSL -o /tmp/sqlite.tar.gz \
      "https://sqlite.org/${SQLITE_YEAR}/sqlite-autoconf-${SQLITE_VERSION}.tar.gz" && \
    echo "${SQLITE_SHA256}  /tmp/sqlite.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/sqlite.tar.gz -C /tmp && \
    cd "/tmp/sqlite-autoconf-${SQLITE_VERSION}" && \
    CFLAGS="-O2 -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_SECURE_DELETE" \
      ./configure --prefix=/usr/local --disable-static --all --soname=legacy && \
    make -j"$(nproc)" && \
    make install && \
    ldconfig && \
    cd / && \
    rm -rf /tmp/sqlite.tar.gz "/tmp/sqlite-autoconf-${SQLITE_VERSION}" && \
    apt-get purge -y --auto-remove build-essential && \
    xargs -r -a /tmp/apt-auto-before.txt apt-mark auto > /dev/null && \
    rm -f /tmp/apt-auto-before.txt && \
    rm -rf /var/lib/apt/lists/*

# Fail the BUILD rather than a 3am gateway restart if the override above
# silently did not take — a changed ld path, a distro layout change, or a base
# image that statically links SQLite into CPython would all leave the old
# version in place with no other signal. Asserts exactly the two things that
# were broken: a WAL-safe version, and the fts5 command the health probe runs.
RUN python3 -c "import sqlite3; \
assert sqlite3.sqlite_version_info >= (3, 51, 3), \
    'libsqlite3 override did not take: ' + sqlite3.sqlite_version; \
c = sqlite3.connect(':memory:'); \
c.execute('CREATE VIRTUAL TABLE t USING fts5(body)'); \
c.execute(\"INSERT INTO t(body) VALUES('probe')\"); \
c.execute(\"INSERT INTO t(t) VALUES('flush')\"); \
c.execute(\"INSERT INTO t(t) VALUES('integrity-check')\"); \
print('sqlite', sqlite3.sqlite_version, '- fts5 flush + integrity-check OK')"

# Install hermes-agent (provides the `hermes` CLI) and pre-build its React
# dashboard so `hermes dashboard` has nothing to build at runtime.
#
# [all] in v2026.6.5 no longer pulls in [dev]; messaging platforms, TTS, and
# other heavy backends are lazy-installed by hermes at first use. We pre-install
# the ones this template actually uses so first-message latency is instant.
# `vision` guards image downscaling (without Pillow an oversized image >5 MB /
# >8000px bakes into immutable history and bricks the session on Anthropic's
# non-retryable 400). The extra itself has been EMPTY since v2026.6.19 — Pillow
# moved into core deps — so it resolves to a no-op; kept for back-compat.
# When bumping HERMES_REF, re-check hermes-agent's pyproject.toml [all] and
# the extras below against the new release's pyproject.toml.
#
# The `-e` is LOAD-BEARING since v2026.8.3: upstream's new setup.py raises on
# bdist_wheel/sdist unless HERMES_NIX_BUILD=1. PEP 660 editable installs route
# through build_editable and are exempt — drop `-e` and the image won't build.
#
# v2026.8.3 also added [tool.uv] to pyproject.toml, which uv reads from this
# cwd (upstream builds from a frozen lock; we re-resolve every time):
# override-dependencies fixes discord.py's vulnerable pynacl pin, and
# exclude-newer="14 days" can fail a build on a fresh dep — override with
# `uv pip install --exclude-newer <date>`.
#
# v2026.8.13 made that escape hatch sharper, and v2026.9.11 moved the floor
# again: nemo-relay is now >=0.8.3,<0.9 (0.8.3 published 2026-09-02), which
# only resolves because upstream lists it in exclude-newer-package. A manual
# `--exclude-newer <date>` re-imposes a GLOBAL cutoff, so any date before
# 2026-09-02 leaves nemo-relay>=0.8.3 unsatisfiable and hard-fails the build.
# Same trap for cryptography==50.0.0 and h2 4.4.1. Re-read this floor on every
# bump — it tracks whatever nemo-relay pin the pinned tag carries.
RUN git clone --depth 1 --branch ${HERMES_REF} https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent && \
    cd /opt/hermes-agent && \
    uv pip install --system --no-cache -e ".[all,messaging,tts-premium,honcho,bedrock,anthropic,edge-tts,hindsight,vision]" && \
    cd /opt/hermes-agent/web && \
    npm install --silent && \
    npm run build && \
    cd /opt/hermes-agent/ui-tui && \
    npm install --silent --no-fund --no-audit --progress=false && \
    npm run build && \
    rm -rf /opt/hermes-agent/web /opt/hermes-agent/.git /root/.npm

# Why pre-build ui-tui (and why we don't delete it after):
# - The dashboard's embedded Chat tab spawns `node ui-tui/dist/entry.js`
#   on every WebSocket connect to /api/pty.
# - Without HERMES_TUI_DIR, hermes's _make_tui_argv falls through to the
#   npm install + build path (since git-editable installs don't have the
#   bundled tui_dist/ that PyPI wheels include), adding 30-60s to the
#   first chat-open and blocking the asyncio event loop.
# - Pre-building at image time surfaces build failures here rather than
#   at user request time, and makes first-chat-open instant.
# - We keep ui-tui/ entirely (node_modules + dist + src) so HERMES_TUI_DIR
#   can point at it (see below).

# Stamp the CODE-SCOPED install method next to the running package. hermes'
# detect_install_method() reads <install-tree>/.install_method FIRST (priority 1,
# authoritative) — before the home-scoped $HERMES_HOME/.install_method that
# start.sh writes (priority 2, honored only when is_container() is true). The
# install tree for our editable install is /opt/hermes-agent (parent of
# hermes_cli/, i.e. Path(config.py).parent.parent). Baking the stamp here makes
# the dashboard "Update Hermes" button refuse regardless of runtime container
# detection — exactly what upstream's own published image does (it bakes a
# docker stamp into /opt/hermes). Belt-and-suspenders with start.sh's home stamp:
# if a future hermes release changes or drops is_container()'s Railway marker
# (/run/.containerenv), the home stamp would stop being honored but this one
# still refuses. Re-verify the install-tree path if hermes stops installing
# editable from /opt/hermes-agent.
RUN printf 'docker\n' > /opt/hermes-agent/.install_method

# firecrawl-anydoc (the PDF / legacy-Office reader behind read_file) is a CORE
# dependency as of v2026.8.31 — pyproject.toml pins ==0.2.4 and exempts it from
# [tool.uv] exclude-newer, so the main install above already has it.
#
# Do NOT re-pin it in a later layer. We used to (==0.1.6, when it was lazy-only):
# that layer runs AFTER the editable install and uv DOWNGRADES the core version,
# and v2026.8.31 also bumped the lazy self-heal pin (tools/lazy_deps.py
# "tool.doc_extract") to ==0.2.4. _is_satisfied() compares versions, not
# presence, so the first PDF read tries to heal into HERMES_LAZY_INSTALL_TARGET
# with a --constraint file built from every installed dist — which pins
# firecrawl-anydoc==0.1.6 — and uv hard-fails "No solution found". Result:
# EVERY PDF/.docx/.xlsx/.pptx/.odt/.rtf/.epub read fails, on every deploy,
# retried every 300s (ANYDOC_RETRY_SECONDS) and never succeeding.
#
# Same trap for any other package we might pin separately: on a version bump,
# grep the new pyproject's core dependencies for anything this Dockerfile pins.

COPY requirements.txt /app/requirements.txt
RUN uv pip install --system --no-cache -r /app/requirements.txt

RUN mkdir -p /data/.hermes

COPY server.py /app/server.py
COPY templates/ /app/templates/
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes

# Points hermes at our pre-built TUI bundle. hermes's _make_tui_argv checks
# HERMES_TUI_DIR first: if dist/entry.js exists there, it skips the npm
# install/build entirely. This is the official packager path (Nix uses it too)
# and avoids the 30-60s npm bootstrap that git-editable installs would otherwise
# trigger on first /chat connection.
ENV HERMES_TUI_DIR=/opt/hermes-agent/ui-tui

# tini wraps start.sh so it runs as PID 1's child instead of as PID 1 itself.
# `-g` propagates signals to the whole process group so `docker stop` /
# Railway's SIGTERM cleanly terminates the entire tree, not just start.sh.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/start.sh"]
