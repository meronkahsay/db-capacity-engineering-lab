# Node.js API image for the Regional Health service.
#
# node:22-slim, not 20-slim (package.json only requires >=18, so 22 is
# compatible): checked Docker Hub's API directly rather than assume --
# node:20-slim was last rebuilt 2026-04-22 (stale), node:22-slim 2026-08-05.
# That ~4-month gap in Debian security patches is what produced 36 findings
# (29 HIGH, 7 CRITICAL) in `trivy image`, almost all OS-level CVEs in the
# base layer, not app code -- confirmed via a local `trivy image` run before
# switching, not guessed. Base pinned by digest (C5: "base pinned by
# digest") -- re-pin deliberately on a base image bump, not silently.
FROM node:22-slim@sha256:d649c27dae7ba0137b3cef5dd75baa422c08dc3d9e3fc0c23dfb172dc3cc6436

WORKDIR /usr/src/app

COPY package.json ./
RUN npm install --omit=dev \
    # npm's own bundled tooling (tar/brace-expansion/picomatch/sigstore/etc.)
    # carries its own HIGH/CRITICAL CVEs -- confirmed via `trivy image
    # --ignore-unfixed` that these packages live at
    # /usr/local/lib/node_modules/npm/node_modules/*, part of the base
    # image's npm install, not this app's package-lock.json. The runtime
    # only ever runs `node server.js` (never `npm`/`npx` after build), so
    # remove npm itself once install is done. (Same fix independently
    # confirmed against Rigbe's Dockerfile in the same cohort.)
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack

COPY . .

# No build tools / mysql-client / bash in the final layer (C5: "no build
# tools in the final layer"). The A1 docker-compose seed flow used to run
# `mysql` from inside this same image -- that dependency has moved to the
# host / a separate throwaway container (see data-seed/README or the A1
# seed instructions) rather than being baked into the deployed app image,
# which never needs a mysql CLI at runtime.

# Run as the image's built-in non-root user, not root (C5 / trivy DS-0002:
# "Specify at least 1 USER command ... with non-root user"). Official Node
# images ship a real `node` user (uid 1000) -- confirmed directly against
# node:22-slim (`docker run --rm node:22-slim id node`) rather than assumed.
USER node

EXPOSE 3000

CMD ["node", "server.js"]
