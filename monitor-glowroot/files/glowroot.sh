#!/bin/sh
SERVICE_NAME=monitor
PATH_TO_JAR=/opt/glowroot-central/glowroot-central.jar
PID_PATH_NAME=/tmp/monitor-pid
case $1 in
    start)
        echo "Starting $SERVICE_NAME ..."
        nohup java -jar $PATH_TO_JAR & echo $! > $PID_PATH_NAME
        echo "$SERVICE_NAME started ..."
    ;;
    stop)
        if [ -f $PID_PATH_NAME ]; then
            PID=$(cat $PID_PATH_NAME);
            echo "$SERVICE_NAME stoping ..."
            kill $PID;
            echo "$SERVICE_NAME stopped ..."
            rm $PID_PATH_NAME
        else
            echo "$SERVICE_NAME is not running ..."
        fi
    ;;
    restart)
        if [ -f $PID_PATH_NAME ]; then
            PID=$(cat $PID_PATH_NAME);
            echo "$SERVICE_NAME stopping ...";
            kill $PID;
            echo "$SERVICE_NAME stopped ...";
            rm $PID_PATH_NAME
            echo "$SERVICE_NAME starting ..."
            nohup java -jar $PATH_TO_JAR & echo $! > $PID_PATH_NAME
            echo "$SERVICE_NAME started ..."
        else
            echo "$SERVICE_NAME is not running ..."
    fi     ;;
esac