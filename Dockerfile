# Docker CLI with the compose plugin, adnanh/webhook and jq.
FROM docker:29.9-cli

RUN apk add --no-cache webhook jq

COPY --chmod=755 bin/ /usr/local/bin/

EXPOSE 9000
HEALTHCHECK --interval=30s --timeout=5s \
  CMD wget -qO /dev/null http://127.0.0.1:9000/ || exit 1

ENTRYPOINT ["/usr/local/bin/deploy-hook"]
CMD ["serve"]
