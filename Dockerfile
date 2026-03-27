FROM nginx:latest
COPY dist/index.html /usr/share/nginx/html/index.html
