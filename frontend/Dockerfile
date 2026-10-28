FROM nginx:stable-alpine
 
# Pick up patched OS packages, then add the openssl CLI used to create the
# self-signed certificate when the container starts.
RUN apk upgrade --no-cache && apk add --no-cache openssl
 
# Replace the stock site and config with ours.
RUN rm -rf /usr/share/nginx/html/* /etc/nginx/conf.d/default.conf
COPY templates/ /etc/nginx/templates/
COPY docker-entrypoint.d/ /docker-entrypoint.d/
COPY public/ /usr/share/nginx/html/
RUN chmod +x /docker-entrypoint.d/25-self-signed-cert.sh
 
# Substitute only our own ${HTTPS_*} variables in the config template; nginx's
# own $variables must be left untouched. An empty suffix means the default port 443.
ENV NGINX_ENVSUBST_FILTER="^HTTPS_" \
    HTTPS_REDIRECT_PORT_SUFFIX=""
 
EXPOSE 80 443
