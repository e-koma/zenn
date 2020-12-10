FROM node:15.3.0-alpine3.12

WORKDIR /app
COPY articles articles
COPY books books

RUN apk add --no-cache --virtual .build-deps git \
    && npm init --yes \
    && npm install zenn-cli \
    && npx zenn init \
    && apk del .build-deps

ENTRYPOINT ["npx", "zenn", "preview"]
