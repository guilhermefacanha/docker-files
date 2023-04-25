# Base image
FROM d3fk/nfs-client

# Create mount folder
RUN mkdir -p /opt/fs

# ENV
#ENV FSTYPE nfs
#ENV MOUNT_OPTIONS nfsvers=3
ENV SERVER 172.25.62.116
ENV SHARE /data/nfs
ENV MOUNTPOINT /opt/fs