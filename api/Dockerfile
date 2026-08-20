# Node.js API image for the Regional Health service.
#
# Base pinned by digest (C5: "base pinned by digest") -- the tag node:20-slim
# currently resolves to this digest; re-pin deliberately on a base image bump,
# not silently.
FROM node:20-slim@sha256:2cf067cfed83d5ea958367df9f966191a942351a2df77d6f0193e162b5febfc0

WORKDIR /usr/src/app

COPY package.json ./
RUN npm install --omit=dev

COPY . .

# No build tools / mysql-client / bash in the final layer (C5: "no build
# tools in the final layer"). The A1 docker-compose seed flow used to run
# `mysql` from inside this same image -- that dependency has moved to the
# host / a separate throwaway container (see data-seed/README or the A1
# seed instructions) rather than being baked into the deployed app image,
# which never needs a mysql CLI at runtime.

# Run as the image's built-in non-root user, not root (C5 / trivy DS-0002:
# "Specify at least 1 USER command ... with non-root user"). node:20-slim
# ships a real `node` user (uid 1000) -- confirmed directly
# (`docker run --rm node:20-slim id node`) rather than assumed.
USER node

EXPOSE 3000

CMD ["node", "server.js"]
