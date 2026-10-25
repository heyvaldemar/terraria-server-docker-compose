# TShock's own image, made to run as uid 1000. Nothing else changes.
#
# WHY A BUILD AT ALL. The official image runs as root, and TShock writes into
# its own program directory, /server. As uid 1000 the stock image cannot start
# there. Running it as root would fix that by handing the process that faces
# the internet everything; this gives /server, and the three directories the
# image declares as volumes, to the one user it runs as. A new named volume
# takes its owner from the image, so the volumes start out as 1000:1000 too.
#
# THE BASE COMES FROM THE COMPOSE FILE, never from a default written here. The
# pin, tag and digest, lives once, in the x-images block of
# terraria-server-docker-compose.yml, where the Trivy scan, the daily
# freshness check and the fleet's pin refresh read it. A second copy here
# would be the one that falls behind. `docker compose build` passes it in;
# `docker build` without --build-arg TSHOCK_IMAGE=... fails, on purpose.
ARG TSHOCK_IMAGE
FROM ${TSHOCK_IMAGE}
RUN mkdir -p /tshock /worlds /plugins \
 && chown -R 1000:1000 /server /tshock /worlds /plugins
USER 1000:1000
