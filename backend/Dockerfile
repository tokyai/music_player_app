FROM node:22-alpine

WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY public ./public
COPY src ./src

ENV PORT=8787
EXPOSE 8787
USER node
CMD ["node", "src/server.mjs"]
