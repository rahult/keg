# node:22-bookworm-slim (Node 22.23.5, on Debian 12), by digest: DuckDB's
# prebuilt library for Linux is built against glibc.
FROM node:22-bookworm-slim@sha256:e9f565d32859f0cbfb52125eafe8be39390f24dac302dc3cdf566e8ba3ab21ee
WORKDIR /srv
COPY package.json package-lock.json ./
# No package runs a script as it is installed: none needs one, and DuckDB's
# library comes prebuilt, as a package of its own for each platform. npm
# keeps what it fetched, and Node what it compiled, in caches the image
# does not need.
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund && rm -rf /root/.npm /tmp/node-compile-cache
COPY . .
# Run as Node's own user, not root: the node gives it its volume.
USER node
CMD ["node", "index.js"]
