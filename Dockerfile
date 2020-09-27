FROM mlsmrc/ibmcloudcli:latest
COPY cert-refresh.sh .
RUN chmod 400 cert-refresh.sh
ENTRYPOINT /bin/sh
CMD ./cert-refresh.sh
