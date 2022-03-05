#!/bin/bash

_operation="some"
_container="mysql"
_image="mysql/mysql-server:latest"
_build_image="mysql:1.0"
_volume=/Users/guilhermefacanha/workspace/docker/postgresql12/data

_port="3306"

echo 'params: '$#
echo "$@"
if (( $# <= 0 )); then
    echo 'you must provide one operation: [log, status, create, start, stop, remove, exec]: type _operation'
    read _operation
else
    _operation=$1
fi

echo ' ==== '
echo 'selected _operation: '$_operation
echo ' ==== '

case "$_operation" in
    'create')
    	echo "=>creating $_container container: "
        # use -v /home/user/project/mysql/data:/var/lib/mysql to add volume
		docker run -p $_port:$_port --name $_container -e MYSQL_ROOT_HOST=% -e MYSQL_ROOT_PASSWORD=1234 -d $_image
		docker cp test_db mysql:/opt/

		echo "MySQL Created"
	    echo "Container: $_container"
	    echo "Host: localhost:$_port"
		echo "Login: root"
		echo "Password: 1234"
        echo ""
        echo "To load the sample database"
        echo "Run commands"
        echo "cd /opt/test_db"
        echo "mysql -u root -p < employees.sql"
        
	    
    ;;
    'remove')
        docker rm -f $_container
    ;;
    'build')
        docker build -t $_build_image .
    ;;
    'clean')
        docker rm -f $_container
        docker rmi -f $_image
        docker image prune -f
    ;;
    'log')
	    docker logs $_container
    ;;
    'status')
        docker ps | grep ldap
    ;;
    'start')  
	    docker start $_container
    ;;
    'stop')  
	    docker stop $_container
    ;;
    'exec')  
        docker exec -it $_container bash
    ;;
    *)
        echo _operation $_operation not recognized
    ;;
esac


echo finished!
