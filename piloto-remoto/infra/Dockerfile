ARG NODE_IMAGE
FROM ${NODE_IMAGE}
RUN apk add --no-cache openssl
WORKDIR /app
COPY gateway/package.json gateway/relay.js gateway/enrollment.js gateway/server.js gateway/init-state.js gateway/web-viewer.js gateway/viewer-client.js gateway/viewer-open.js gateway/viewer.html gateway/viewer.css ./
USER node
CMD ["node", "server.js"]
