FROM node:lts-alpine AS builder

RUN apk add --no-cache git python3 py3-pip make g++

WORKDIR /app

RUN git clone -b v3.1.1 https://github.com/haraka/Haraka.git ./

# COPY haraka-plugin-wildduck /tmp

RUN npm install --omit=dev

# Install plugin

COPY . /app/node_modules/haraka-plugin-wildduck
WORKDIR /app/node_modules/haraka-plugin-wildduck
# @sudobility/* now live on GitHub Packages (not npmjs); everything else stays
# on the default public npm registry. Route the scope and auth with the token.
# Token via BuildKit secret (never a build-arg or an image layer). CI passes it
# via docker/build-push-action `secrets:`; locally:
#   docker build --secret id=gh_packages_token,env=GH_PACKAGES_READ_TOKEN
RUN --mount=type=secret,id=gh_packages_token \
    printf '@sudobility:registry=https://npm.pkg.github.com\n//npm.pkg.github.com/:_authToken=%s\n' \
      "$(cat /run/secrets/gh_packages_token)" > ~/.npmrc && \
    npm install --omit=dev && \
    rm -f ~/.npmrc


FROM node:lts-alpine AS app

ENV NODE_ENV=production

RUN apk add --no-cache tini
RUN apk add --no-cache openssl

WORKDIR /app
COPY --from=builder /app /app

ENTRYPOINT ["/sbin/tini", "--", "node", "haraka.js"]
