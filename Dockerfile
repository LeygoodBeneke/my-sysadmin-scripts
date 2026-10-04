# Стадия 1: статическая проверка скрипта — образ не соберётся, если shellcheck найдёт ошибки
FROM ubuntu:22.04 AS lint
RUN apt-get update && apt-get install -y --no-install-recommends shellcheck \
    && rm -rf /var/lib/apt/lists/*
COPY monitor.sh /src/monitor.sh
RUN shellcheck /src/monitor.sh

# Стадия 2: итоговый образ без shellcheck
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /var/www
COPY --from=lint /src/monitor.sh /usr/local/bin/script.sh
RUN chmod +x /usr/local/bin/script.sh
EXPOSE 8080
CMD ["/bin/bash", "-c", "/usr/local/bin/script.sh & exec python3 -m http.server 8080"]
