# nginx-unprivileged, not the stock nginx image.
#
# The Helm chart runs this pod with runAsNonRoot, runAsUser 101 and
# readOnlyRootFilesystem. Stock `nginx` starts its master process as root and
# writes /var/run/nginx.pid, so it fails both of those. The unprivileged
# variant runs as uid 101 and keeps its pid and temp files under /tmp, which
# the chart mounts as an emptyDir.
#
# It also already listens on 8080 rather than 80, matching containerPort in
# the chart's values.yaml - a non-root process cannot bind a port below 1024.
FROM nginxinc/nginx-unprivileged:1.27-alpine

# Baked-in default config so `docker run` works standalone. In the cluster the
# chart's ConfigMap mounts over /etc/nginx/conf.d and REPLACES this file - see
# apps/resume/templates/configmap.yaml. Keep the two in sync so what you test
# locally resembles what runs on the Pis.
COPY nginx.conf /etc/nginx/conf.d/default.conf

COPY index.html styles.css /usr/share/nginx/html/

EXPOSE 8080
