FROM centos/systemd

COPY files/cassandra.repo /etc/yum.repos.d/
COPY files/install.sh /opt/
COPY files/glowroot.sh /opt/
COPY files/glowroot.service /etc/systemd/system/


#install ssh capability
RUN yum install -y openssh-server openssh-clients \
  && mkdir /var/run/sshd \
  && echo 'root:root' | chpasswd \
  && sed -i 's/#*PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config \
  && sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd \
  && echo "export VISIBLE=now" >> /etc/profile


#install java and cassandra db
RUN yum update -y \
&& yum install -y unzip wget \
&& yum install -y java-1.8.0-openjdk \ 
&& yum -y install cassandra

#install glowroot central
RUN wget https://github.com/glowroot/glowroot/releases/download/v0.13.6/glowroot-central-0.13.6-dist.zip -P /opt/ \
&& unzip /opt/glowroot-central-0.13.6-dist.zip -d /opt/ \
&& chmod +x /opt/*.sh

#init systemd
CMD ["/usr/sbin/init"]
