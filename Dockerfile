FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./

RUN npm ci --omit=dev

FROM node:20-alpine
WORKDIR /app

# Pick up patched OS packages (e.g. openssl fixes) available in Alpine's repo
RUN apk update && apk upgrade --no-cache

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# The container only ever runs `node server.js`, never `npm` — strip npm's
# own bundled dependency tree (tar, glob, pacote, sigstore, etc.) so its
# known CVEs aren't shipped in the production image at all.
RUN rm -rf /usr/local/lib/node_modules/npm \
    /usr/local/bin/npm \
    /usr/local/bin/npx

USER appuser

ENV PORT=3000
EXPOSE 3000

CMD ["node", "server.js"]
