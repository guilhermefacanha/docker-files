FROM centos/systemd

COPY files/cassandra.repo /etc/yum.repos.d/
COPY files/install.sh /opt/
COPY files/glowroot.sh /opt/
COPY files/glowroot-central.properties /opt/
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
&& yum remove -y java-1.8.0-openjdk \
&& yum install -y unzip wget \
&& yum install -y java-11-openjdk java-11-openjdk-headless \
&& yum -y install cassandra

#install glowroot central
RUN wget https://github.com/glowroot/glowroot/releases/download/v0.14.1/glowroot-central-0.14.1-dist.zip -P /opt/ \
&& unzip /opt/glowroot-central-0.14.1-dist.zip -d /opt/ \
&& chmod +x /opt/*.sh

RUN update-alternatives --set java /usr/lib/jvm/java-11-openjdk-11.0.22.0.7-1.el7_9.x86_64/bin/java \
&& cp -rf /opt/glowroot-central.properties /opt/glowroot-central/glowroot-central.properties

RUN sh /opt/install.sh

#RUN java -jar /opt/glowroot-central/glowroot-central.jar setup-admin-user monitorAdmin 1qaz@WSX

#init systemd
CMD ["/usr/sbin/init"]
