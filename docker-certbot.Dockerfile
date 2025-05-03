# docker-certbot.Dockerfile
FROM certbot/certbot:latest

# Stage 1: grab a matching Docker CLI from the official docker CLI image
FROM docker:24-cli as cli
# Stage 2: copy only the statically-linked client into certbot image
FROM certbot/certbot:latest
COPY --from=cli /usr/local/bin/docker /usr/local/bin/docker

# (Optional) verify client is present
RUN /usr/local/bin/docker --version