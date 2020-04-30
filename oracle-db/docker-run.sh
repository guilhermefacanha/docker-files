#!/bin/bash

_operation="some"
_container="oracledb"
_backup="_backup"
_image="oracleinanutshell/oracle-xe-11g"
_build_image="db/oracle:1.0"

echo 'params: '$#
echo "$@"
if (( $# <= 0 )); then
    echo "you must provide one operation: [
        log - show log for container $_container, 
        status - show status for container $_container, 
        create - create container $_container for image $_image, 
        start - start container $_container, 
        stop - stop container $_container,
        remove - remove container $_container, 
        exec - enter execution mode for container $_container,
        clean - clean all container $_container files and images,
        backup - create backup commit for container $_container
        ] : type _operation"
    read _operation
else
    _operation=$1
fi

echo "selected _operation: [$_operation]"
echo ' ==== '

case "$_operation" in
    'create')
    	echo "=>creating container $_container: "
	    docker run -d -p 1521:1521 -p 8888:8080 -e ORACLE_ALLOW_REMOTE=true --name $_container --detach $_image

        echo "==================================
        Web Apex:
        # Login http://localhost:8888/apex/apex_admin with following credential:
        username: ADMIN
        password: admin
        By default, the password verification is disable(password never expired)
        Connect database with following setting:
        ==================================
        Database:
        hostname: localhost
        port: 1521
        sid: xe
        username: system
        password: oracle
        
        ==================================
        Password for SYS & SYSTEM
        oracle"
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
        docker ps | grep $_container
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
    'backup')  
        echo "Creating backup for $_container with name $_container$_backup ..."
        docker commit $_container $_container$_backup
        echo "Saving backup for $_container$_backup with name $_container$_backup.tar ..."
        docker save $_container$_backup > $_container$_backup.tar
    ;;
    *)
        echo "Operation [$_operation] not recognized"
    ;;
esac


echo ""
echo finished!
echo ""
echo ""
