#!/bin/bash

[ -d ./master/data -a -d ./slave/data ] && { echo "ALREADY INSTALLED :(.."; exit 1; }

if [ ! -f ".env" ]
then
   read -p ".env FILE IS NOT AVAILABLE. DO YOU WANT TO COPY THE DEFAULT ONE (Y|N)? " -n 1 -r
    echo    # (optional) move to a new line
    if [[ ! $REPLY =~ ^[Yy]$ ]]
    then
        [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1
    fi
    cp -i .env.example .env
fi

set -o allexport
source .env
set +o allexport

docker-compose down --remove-orphans -v
rm -rf ./*/data
chmod +x server.sh
docker-compose build
docker-compose up -d

MASTER='master'
SLAVE='slave'

for SERVICE in $MASTER $SLAVE
do until docker-compose exec $SERVICE /bin/bash -c 'export MYSQL_PWD='$ROOT_PASSWORD'; mysql -h localhost -u root -e ";"'
    do
        echo "WAITING FOR $SERVICE SERVER CONNECTION..."
        sleep 4
    done
    echo -e "\n$SERVICE SERVER IS READY :)"
done

CREATE_AND_GRANT_USER='CREATE USER IF NOT EXISTS "'$DB_USER'"@"%" IDENTIFIED BY "'$USER_PASSWORD'"; GRANT REPLICATION SLAVE ON *.* TO "'$DB_USER'"@"%"; FLUSH PRIVILEGES;'
MASTER_STATUS=`docker-compose exec $MASTER /bin/bash -c 'export MYSQL_PWD='$ROOT_PASSWORD'; mysql -u root -e "SHOW MASTER STATUS"'`
CURRENT_LOG=''
CURRENT_POS=''
SLAVE_STATEMENT='CHANGE MASTER TO MASTER_HOST="'$MASTER'",MASTER_USER="'$DB_USER'",MASTER_PASSWORD="'$USER_PASSWORD'",'

for SERVICE in $MASTER $SLAVE; do
    echo "CONFIGURING $SERVICE SERVER ..."
    if [ $SERVICE = $MASTER ]; then
        echo "--- CREATE USER $DB_USER AND GRANT PERMISSION"
        docker-compose exec $SERVICE /bin/bash -c "export MYSQL_PWD='$ROOT_PASSWORD'; mysql -u root -e '$CREATE_AND_GRANT_USER'"
        if [ $? -ne 0 ]; then
            echo "INSTALLATION FAILED ... :("; exit 1;
        fi
        echo "--- SHOW MASTER STATUS"
        docker-compose exec $MASTER /bin/bash -c "export MYSQL_PWD='$ROOT_PASSWORD'; mysql -u root -e 'SHOW MASTER STATUS \G'"
        CURRENT_LOG=`echo $MASTER_STATUS | awk '{print $6}'`
        CURRENT_POS=`echo $MASTER_STATUS | awk '{print $7}'`
        if [ $? -ne 0 ]; then
            echo "INSTALLATION FAILED ... :("; exit 1;
        fi
        echo "--- CURRENT LOG FILE:$CURRENT_LOG LOG POSITION:$CURRENT_POS"
        SLAVE_STATEMENT+='MASTER_LOG_FILE="'$CURRENT_LOG'",MASTER_LOG_POS='$CURRENT_POS'; START SLAVE;'
    else
        echo "--- ATTACHING MASTER SERVER"
        docker-compose exec $SERVICE /bin/bash -c "export MYSQL_PWD='$ROOT_PASSWORD'; mysql -u root -e '$SLAVE_STATEMENT'"
        if [ $? -ne 0 ]; then
            echo "INSTALLATION FAILED ... :("; exit 1;
        fi
        echo "--- SHOW SLAVE STATUS"
        docker-compose exec $SERVICE /bin/bash -c "export MYSQL_PWD='$ROOT_PASSWORD'; mysql -u root -e 'SHOW SLAVE STATUS \G'"
    fi
done

echo "INSTALLATION COMPLETE ... :)"
