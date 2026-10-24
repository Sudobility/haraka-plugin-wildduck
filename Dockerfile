FROM node:lts-alpine AS builder

ARG GH_PACKAGES_TOKEN

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
RUN echo "@sudobility:registry=https://npm.pkg.github.com" > ~/.npmrc && \
    echo "//npm.pkg.github.com/:_authToken=${GH_PACKAGES_TOKEN}" >> ~/.npmrc && \
    npm install --omit=dev && \
    rm -f ~/.npmrc


FROM node:lts-alpine AS app

ENV NODE_ENV=production

RUN apk add --no-cache tini
RUN apk add --no-cache openssl

WORKDIR /app
COPY --from=builder /app /app

ENTRYPOINT ["/sbin/tini", "--", "node", "haraka.js"]
