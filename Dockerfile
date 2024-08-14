ARG  ARCH="amd64"
ARG  OS="linux"
FROM quay.io/prometheus/golang-builder AS builder

# Get sql_exporter fork
ADD . /go/src/github.com/kubedb/mssqlserver_exporter
WORKDIR /go/src/github.com/kubedb/mssqlserver_exporter

# Do makefile
RUN make

# Make image and copy build sql_exporter
FROM        quay.io/prometheus/busybox-${OS}-${ARCH}:latest
LABEL       maintainer="The Prometheus Authors <prometheus-developers@googlegroups.com>"
COPY        --from=builder /go/src/github.com/kubedb/mssqlserver_exporter/sql_exporter  /bin/sql_exporter

# Add kubedb configuration files to /etc/sql-exporter/
ADD kubedb /etc/sql-exporter/

EXPOSE      9399
USER        nobody
ENTRYPOINT  [ "/bin/sql_exporter" ]
