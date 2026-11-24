# nats:2.10-alpine (NATS server 2.10.29) and node:22-alpine, by digest.
FROM nats:2.10-alpine@sha256:b83efabe3e7def1e0a4a31ec6e078999bb17c80363f881df35edc70fcb6bb927 AS nats
FROM node:22-alpine@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a
COPY --from=nats /usr/local/bin/nats-server /usr/local/bin/
WORKDIR /srv
COPY package.json package-lock.json ./
# No package runs a script as it is installed: none needs one. npm keeps
# what it fetched, and Node what it compiled, in caches the image does not
# need.
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund && rm -rf /root/.npm /tmp/node-compile-cache
COPY . .
# Run as Node's own user, not root: the node gives it its volume.
USER node
CMD ["node", "index.js"]
