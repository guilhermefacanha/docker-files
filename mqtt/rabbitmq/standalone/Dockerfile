FROM rabbitmq:3-management

ENV RABBITMQ_DEFAULT_USER admin
ENV RABBITMQ_DEFAULT_PASS admin

RUN rabbitmq-plugins enable --offline rabbitmq_management
RUN rabbitmq-plugins enable --offline rabbitmq_mqtt
#RUN rabbitmqctl add_user mqtt-test mqtt-test
#RUN rabbitmqctl set_permissions -p / mqtt-test ".*" ".*" ".*"
#RUN rabbitmqctl set_user_tags mqtt-test management

COPY files/rabbitmq-env.conf /etc/rabbitmq/rabbitmq-env.conf
COPY files/rabbitmq.conf /etc/rabbitmq/rabbitmq.conf
RUN chown -R rabbitmq:rabbitmq /var/lib/rabbitmq /etc/rabbitmq
RUN chmod 777 -R /etc/rabbitmq

EXPOSE 15672
EXPOSE 5672
EXPOSE 1883