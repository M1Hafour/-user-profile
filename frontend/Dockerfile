FROM nginx:stable-alpine

# Pick up patched OS packages (same reason as the backend image).
RUN apk upgrade --no-cache

# Replace the stock site and config with ours.
RUN rm -rf /usr/share/nginx/html/*
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY public/ /usr/share/nginx/html/

EXPOSE 80
