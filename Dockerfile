# ---- Base image versions ----
FROM node:22-alpine AS base
RUN apk add --no-cache libc6-compat openssl
WORKDIR /app

# ---- Builder (needs dev deps, but skip Cypress binary) ----
FROM base AS builder

ENV CYPRESS_INSTALL_BINARY=0
ENV DATABASE_URL="file:./dummy.db"
COPY package.json package-lock.json ./
# npm ci installs exactly what package-lock.json pins and fails if the lockfile
# and package.json ever drift apart, instead of silently re-resolving them.
RUN npm ci
COPY . .
# Generate Prisma Client at build time
RUN npx prisma generate
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# ---- Prisma CLI (isolated) ----
# docker-entrypoint.sh needs the Prisma CLI to run migrations at container start,
# but nothing else from the build tree. Installing it on its own keeps the build
# toolchain (typescript, eslint, cypress, tailwind, next) out of the final image.
# The version is read from package.json so it stays in lockstep with @prisma/client.
FROM base AS prisma-cli
WORKDIR /cli
COPY package.json ./app-package.json
RUN PRISMA_VERSION="$(node -p "require('/cli/app-package.json').dependencies.prisma")" \
    && rm app-package.json \
    && npm init -y > /dev/null \
    && npm install --no-audit --no-fund "prisma@${PRISMA_VERSION}" \
    && npm cache clean --force

# ---- Runner (slim) ----
FROM base AS runner
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000

# Your DB is bind-mounted here from the host
ENV DATABASE_URL="file:/app/database/dev.db"

# Copy runtime artifacts. The Next.js standalone output already ships the traced
# runtime dependencies (@prisma/client, the generated client, better-sqlite3,
# sharp), so the build stage's node_modules is deliberately not copied.
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
COPY --from=builder /app/prisma ./prisma
# Prisma 7 config file for CLI commands (migrate deploy, db push)
COPY --from=builder /app/prisma.config.mjs ./

# Default label sheet/template definitions shipped with the image.
# The entrypoint seeds these into database/custom/labels/ on first run
# (existing files are never overwritten, so school customisations survive).
COPY --from=builder /app/database/custom/labels /app/defaults/labels

# The isolated Prisma CLI goes to /node_modules, one level above the app. Node
# resolves prisma.config.mjs's imports (prisma/config, dotenv/config) from there,
# while /app/node_modules keeps serving the application's own runtime deps.
COPY --from=prisma-cli /cli/node_modules /node_modules
ENV PATH="/node_modules/.bin:${PATH}"

# Ensure DB directory exists and fix perms
RUN mkdir -p /app/database && chown -R node:node /app

# Add entrypoint that runs Prisma schema sync on first run / on pending migrations
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER node
EXPOSE 3000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "server.js"]
