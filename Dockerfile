# Determines source "edge" or binary "release" builds
ARG UBUNTU_CODENAME=focal
# NOTE: never pass as a build-arg / must match .dockerenv -- used in logback.xml
ARG LOGDIR=/opt/puppetlabs/server/data/puppetdb/logs

######################################################
# base
######################################################

FROM ubuntu:20.04 as base

ARG DUMB_INIT_VERSION="1.2.5"
ARG LOGDIR

ENV PUPPERWARE_ANALYTICS_ENABLED=false \
    PUPPETDB_POSTGRES_HOSTNAME="postgres" \
    PUPPETDB_POSTGRES_PORT="5432" \
    PUPPETDB_POSTGRES_DATABASE="puppetdb" \
    CERTNAME=puppetdb \
    DNS_ALT_NAMES="" \
    WAITFORCERT="" \
    PUPPETDB_USER=puppetdb \
    PUPPETDB_PASSWORD=puppetdb \
    PUPPETDB_NODE_TTL=7d \
    PUPPETDB_NODE_PURGE_TTL=14d \
    PUPPETDB_REPORT_TTL=14d \
    # used by entrypoint to determine if puppetserver should be contacted for config
    # set to false when container tests are run
    USE_PUPPETSERVER=true \
# this value may be set by users, keeping in mind that some of these values are mandatory
# -Djavax.net.debug=ssl may be particularly useful to set for debugging SSL
    PUPPETDB_JAVA_ARGS="-Djava.net.preferIPv4Stack=true -Xms256m -Xmx256m -XX:+UseParallelGC -Xloggc:$LOGDIR/puppetdb_gc.log -Djdk.tls.ephemeralDHKeySize=2048"

# puppetdb data and generated certs
VOLUME /opt/puppetlabs/server/data/puppetdb

LABEL org.label-schema.maintainer="Puppet Release Team <release@puppet.com>" \
      org.label-schema.vendor="Puppet" \
      org.label-schema.url="https://github.com/puppetlabs/puppetdb" \
      org.label-schema.license="Apache-2.0" \
      org.label-schema.vcs-url="https://github.com/puppetlabs/puppetdb" \
      org.label-schema.schema-version="1.0" \
      org.label-schema.dockerfile="/Dockerfile"

# NOTE: this is just documentation on defaults
EXPOSE 8080 8081

ENTRYPOINT ["dumb-init", "/docker-entrypoint.sh"]
CMD ["foreground"]

# The start-period is just a wild guess how long it takes PuppetDB to come
# up in the worst case. The other timing parameters are set so that it
# takes at most a minute to realize that PuppetDB has failed.
# Probe failure during --start-period will not be counted towards the maximum number of retries
# NOTE: k8s uses livenessProbe, startupProbe, readinessProbe and ignores HEALTHCHECK
HEALTHCHECK --start-period=5m --interval=10s --timeout=10s --retries=6 CMD ["/healthcheck.sh"]

# hadolint ignore=DL3020
ADD https://raw.githubusercontent.com/puppetlabs/pupperware/1c8d5f7fdcf2a81dfaf34f5ee34435cc50526d35/gem/lib/pupperware/compose-services/pe-postgres-custom/00-ssl.sh /ssl.sh
# hadolint ignore=DL3020
ADD https://raw.githubusercontent.com/puppetlabs/wtfc/6aa5eef89728cc2903490a618430cc3e59216fa8/wtfc.sh \
    https://github.com/Yelp/dumb-init/releases/download/v"$DUMB_INIT_VERSION"/dumb-init_"$DUMB_INIT_VERSION"_amd64.deb \
    puppetdb/docker-entrypoint.sh \
    puppetdb/healthcheck.sh \
    /

COPY puppetdb/docker-entrypoint.d /docker-entrypoint.d

# hadolint ignore=DL3009
RUN apt-get update && \
    apt-get install --no-install-recommends -y ca-certificates curl dnsutils netcat && \
    chmod +x /ssl.sh /wtfc.sh /docker-entrypoint.sh /healthcheck.sh /docker-entrypoint.d/*.sh && \
    dpkg -i dumb-init_"$DUMB_INIT_VERSION"_amd64.deb


######################################################
# release (build from packages)
######################################################

FROM base as release

ARG version
ARG UBUNTU_CODENAME
ARG install_path=puppetdb="$version"-1"$UBUNTU_CODENAME"
ARG deb_uri=https://apt.puppetlabs.com/puppet8-release-$UBUNTU_CODENAME.deb

######################################################
# final image
######################################################

# dynamically selects "edge" or "release" alias based on ARG
# hadolint ignore=DL3006
FROM release as final

ARG vcs_ref
ARG version
ARG build_date
ARG install_path
ARG deb_uri
# used by entrypoint to submit metrics to Google Analytics;
# published images should use "production" for this build_arg
ARG pupperware_analytics_stream="dev"
ARG LOGDIR

# hadolint ignore=DL3020
ADD $deb_uri /puppet.deb

RUN dpkg -i /puppet.deb && \
    rm /puppet.deb && \
    apt-get update && \
    apt-get install --no-install-recommends -y $install_path && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p "$LOGDIR" && \
# We want to use the HOCON database.conf and config.conf files, so get rid
# of the packaged files
    rm -f /etc/puppetlabs/puppetdb/conf.d/database.ini && \
    rm -f /etc/puppetlabs/puppetdb/conf.d/config.ini

COPY puppetdb/logback.xml \
     puppetdb/request-logging.xml \
     /etc/puppetlabs/puppetdb/
COPY puppetdb/conf.d /etc/puppetlabs/puppetdb/conf.d/
COPY puppetdb/puppetdb /etc/default/puppetdb

ENV PUPPERWARE_ANALYTICS_STREAM="$pupperware_analytics_stream" \
    PUPPETDB_VERSION="$version"

LABEL org.label-schema.name="PuppetDB (release)" \
      org.label-schema.vcs-ref="$vcs_ref" \
      org.label-schema.version="$version" \
      org.label-schema.build-date="$build_date"

COPY Dockerfile /