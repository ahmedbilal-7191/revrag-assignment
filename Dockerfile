# Use pinned minimal image
FROM node:20.19.0-alpine3.21

WORKDIR /app

# Copy only dependency files first (better caching)
COPY package*.json ./

# Install production dependencies only
RUN npm ci --only=production

# Copy application source
COPY . .

# Run as non-root user
USER node

EXPOSE 3000

CMD ["node", "server.js"]
