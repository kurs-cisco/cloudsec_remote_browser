FROM node:22-bookworm-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY app ./app
COPY viewer ./viewer
COPY shared ./shared
COPY deploy ./deploy

ENV NODE_ENV=production
ENV PORT=8080

EXPOSE 8080

CMD ["node", "app/server.js"]
