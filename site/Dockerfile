# Two stages: Hugo renders the site, nginx serves the result. The image holds
# nothing but the generated files, so the server needs no Hugo of its own.
FROM alpine:3.22 AS build
ARG HUGO_VERSION=0.155.3
RUN wget -qO- "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_${HUGO_VERSION}_linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin hugo
WORKDIR /src
COPY hugo.toml ./
COPY i18n i18n
COPY layouts layouts
COPY static static
RUN hugo --minify --gc

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/public /usr/share/nginx/html
